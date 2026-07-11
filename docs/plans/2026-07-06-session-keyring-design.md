# Persistent, passphrase-protected sign-in (gnome-keyring)

Date: 2026-07-06
Status: designed; de-risk spike pending before implementation

## Problem

Claude Desktop shows "Your sign-in won't be saved on this device" on
every session, and members re-authenticate after each restart.
Electron's `safeStorage.isEncryptionAvailable()` returns `false`
because the box has no persistent, unlocked secret store: a kasmVNC/
xrdp desktop is not a PAM login with a password, so `gnome-keyring`
never creates or unlocks a **login keyring**. It falls back to an
ephemeral *session* collection (`~/.local/share/keyrings/` is empty;
the only D-Bus collection is `.../collection/session`).

## Goal

Persist sign-in **encrypted at rest** under a passphrase the box does
not store on disk — production-grade, not an empty-password or
plaintext store.

## Decisions

- **Unlock UX:** in-session `gcr` prompt. When Claude touches
  `safeStorage`, gnome-keyring prompts *inside* the XFCE session; the
  member types the passphrase. No custom kasmVNC auth shim; the
  passphrase is never stored by us.
- **Passphrase setup:** self-service. First use prompts the member to
  *create* a keyring password; later sessions prompt to *unlock*. No
  admin provisioning step, no secret handled by `cws`.
- **Scope:** primary + member sessions only — they run on the shared
  user D-Bus bus where `gnome-keyring-daemon` already runs, and a
  login keyring is **one file per UNIX user, reused across all that
  user's sessions**. Extra `:50+` device sessions stay on
  `--password-store=basic` (no hang, no persistence). They are always
  the *same person* on a second device, so there is no second
  principal to isolate; adding a keyring daemon to each private bus
  buys zero isolation and re-introduces the private-bus secret-service
  fragility that PR #3 fixed.

## Threat model (what this does and does not protect)

- **Between members** (`cws` vs `bob`): already OS-isolated — separate
  UNIX users, `0700` homes. Unchanged by this work.
- **Within one member's sessions** (same UNIX user): the passphrase
  keyring adds **at-rest** protection (a stolen disk/backup, or a
  reader without the passphrase, cannot decrypt the token). It does
  **not** defend against root or a live/unlocked session — those read
  process memory or the unlocked daemon regardless. Full isolation of
  one member's own devices would require separate UNIX users per
  device session; out of scope (the sessions are the same person).

## Architecture

1. **Prompter wiring (the crux).** `gcr4` and
   `/usr/libexec/gcr-prompter` are installed, but nothing registers/
   activates `org.gnome.keyring.SystemPrompter` in the XFCE session, so
   gnome-keyring cannot show a dialog and silently uses the session
   collection. The fix is a session-level step that makes the prompter
   available on the display (autostart entry or explicit start). The
   exact mechanism is the one uncertain piece — resolved by the spike.
2. **Persistent keyring on first use.** With the prompter present and
   no `login.keyring`, the first `safeStorage` write prompts the member
   to create a password; gnome-keyring writes an encrypted
   `login.keyring`. `isEncryptionAvailable` flips true; the token
   persists encrypted. Later sessions prompt to unlock.
3. **Scope enforcement.** Sessions on the shared user bus get the
   keyring. `cws-launch` keeps `--password-store=basic` for config
   homes under `cws-sessions/<N>` (extra sessions), unchanged.

## Graceful degradation

- Member cancels the prompt → falls back to today's behavior (session
  collection, sign-in not saved, no hang). No regression.
- Forgotten passphrase → delete `~/.local/share/keyrings/login.keyring`;
  the next session re-prompts to create one. No lockout; the only loss
  is the saved sign-in, which is re-established by signing in again.

## Testing

- **Unit (BATS):** package presence in the session stack, and any
  autostart/config file we emit — assert path + content, same pattern
  as the colord polkit rule.
- **Not unit-testable:** the prompt + persist behavior needs a live
  end-to-end check on the box. gnome-keyring/gcr integration cannot be
  driven from BATS.

## De-risk spike (run first)

On the box, determine what makes gnome-keyring prompt in an XFCE/VNC
session, then verify the full loop:

1. Identify why the prompter does not appear today and the minimal
   session-level change that makes it available on `:1`.
2. In a session: trigger a secret write, confirm the **create-password**
   prompt renders on the VNC display.
3. Restart the session; confirm the **unlock** prompt renders.
4. Confirm Claude logs `isEncryptionAvailable=true` (backend
   `gnome_libsecret`) and that sign-in survives a restart.

Only after the spike confirms the wiring do we finalize the
implementation (package + session step + tests) and ship it the same
way as the other fixes (lint + BATS green, PR, deploy).

## Spike findings (2026-07-06)

Grounded on the live box, and they **refine the architecture**:

- `gcr4` + `/usr/libexec/gcr-prompter` are installed, and
  `org.gnome.keyring.SystemPrompter.service` is a valid D-Bus
  activation file (`Exec=/usr/libexec/gcr-prompter`). So the prompter
  is activatable — it is not a missing-package problem.
- `ReadAlias("default")` returns object path `/` — there is **no
  default collection**, and it is **not** aliased to the ephemeral
  session collection. So a store to the default *would* create a login
  keyring and prompt; nothing is silently swallowing it into `session`.
- Therefore the silent fallback is two things: (1) an activated
  `gcr-prompter` has no `DISPLAY`/`XAUTHORITY` in the D-Bus activation
  environment, so its dialog cannot render on the VNC display; and
  (2) **Electron gates on `isEncryptionAvailable` up front** — with no
  default collection that returns `false`, so Claude never performs the
  store that would trigger the create-prompt. Chicken-and-egg: no
  collection → no prompt → no collection.
- `secret-tool` is **not** installed (`libsecret-tools`); it is the
  natural way to trigger a keyring create/unlock from a session hook.

### Revised architecture

1. **Export the prompter's environment.** At session start, run
   `dbus-update-activation-environment DISPLAY XAUTHORITY` (XFCE does
   not do this for us) so an activated `gcr-prompter` renders on the
   VNC display.
2. **Create/unlock the login keyring proactively at session start**,
   before Claude checks — do not rely on Claude to trigger it. A
   session hook stores a marker secret to the default collection (e.g.
   via `secret-tool store`, which requires adding `libsecret-tools` to
   the session stack); with no login keyring present, gnome-keyring
   prompts the member to *create* a password (later sessions: *unlock*).
   Once the keyring exists and is unlocked, Claude's
   `isEncryptionAvailable` returns true and sign-in persists.
3. Scope and degradation unchanged from above.

### Spike result — the uncertain piece is resolved

Verified live on the box: with `libsecret-tools` installed, after
`dbus-update-activation-environment DISPLAY XAUTHORITY`, a
`secret-tool store` triggered gnome-keyring's **"Choose password for
new keyring"** dialog, which **rendered on the primary session's XFCE
desktop** (confirmed by screenshot). That was the one uncertain piece —
whether the gcr prompt can render in an XFCE/VNC session. It can. The
dialog was cancelled, so no keyring/credential was created; the
member's real passphrase stays theirs to set.

Everything downstream (keyring written → `isEncryptionAvailable=true` →
sign-in persists) is standard Electron/gnome-keyring behaviour, so the
design is de-risked.

### Implementation

Put the step in `cws-launch` (already fronts every Claude launch, runs
in-session with `DISPLAY`, and already branches on `claude_config`):

- Only for primary/member config homes (skip `cws-sessions/<N>`, which
  stay on `--password-store=basic`).
- Export `DISPLAY`/`XAUTHORITY` to the D-Bus activation environment.
- `secret-tool store` a fixed marker → creates the login keyring the
  first time (member sets the passphrase) or unlocks it thereafter,
  **before** exec'ing Claude, so `isEncryptionAvailable` is already
  true when Claude checks. Member cancels → fall through to today's
  behaviour (no persistence, no hang).
- Add `libsecret-tools` to the session stack.

Unit-test the scoping/invocation (mock `secret-tool` /
`dbus-update-activation-environment`); the passphrase-set and
persist-across-restart is inherently the member's self-service step,
completed on their next real login.

## Reality check (2026-07-11): Electron does not use the keyring here

Live end-to-end testing on the box (Claude Desktop **1.18286.0**, XFCE
over kasmVNC) found the feature's core premise does **not** hold on this
build: Electron `safeStorage.isEncryptionAvailable()` is **never** true,
so the login keyring is never actually used.

Everything the design assumed is verified-correct, and it still fails:

- The login keyring exists, is the **default** collection
  (`ReadAlias("default")` → `Default_Keyring`), and is **unlocked**
  (`Locked=false`) — checked over D-Bus.
- `libsecret-1.so.0` is installed and loadable; `secret-tool`
  reads/writes the keyring fine.
- Forcing `--password-store=gnome-libsecret` still logs
  `isEncryptionAvailable=false … backend=basic_text`.
- Across every launch since the keyring was created,
  `isEncryptionAvailable=true` has occurred **0 times**, and no
  Electron/Chrome key is ever written to the keyring.

So Claude's Electron falls back to the plaintext `basic_text` store
regardless of keyring state. Consequences on this build:

1. **Sign-in does not persist encrypted** — the feature's headline goal
   is inert; it behaves like the pre-keyring plaintext fallback.
2. **Cowork's device bridge is blocked.** The device registry needs the
   encrypted enclave key from `safeStorage`; with encryption
   unavailable it logs `enclave key unavailable — refusing to resolve
   row-PK`, and **no device tools** (`device_bash`, `device_stage_files`,
   or the `client-screen` screenshot tools) reach the model. That is
   why the Bridge screen-share round-trip cannot complete
   (see `docs/browser-validation.md` check 6).

This is a **Claude Desktop / Electron limitation**, not a Coworkstation
defect — every OS-side prerequisite is correct. The only part of the
keyring work that has present-day value is the graceful fallback in
`cws-launch` (no hang when the keyring is not usable). The rest is
correct and ready for a Claude Desktop build whose `safeStorage` uses
the OS keyring.

**Decision (2026-07-11): simplified.** Since the keyring yields nothing
on the current build and its prompt was pure friction, `cws-launch` now
always passes `--password-store=basic` (no `prepare_keyring`, no prompt,
and — as a bonus — no secret-service probe on any session, so no keyring
hang is possible anywhere). The full keyring path (`prepare_keyring`,
`libsecret-tools`, the activation-env export) lives in git history and
this design; restore it if a Claude Desktop build's `safeStorage` starts
using libsecret. Tracked upstream at JongoDB/coworkstation#12.

## Out of scope

- Empty-password / plaintext keyrings (rejected: not production-grade).
- Unifying the passphrase with the kasmVNC Basic-auth password
  (rejected: needs a custom auth shim, large surface).
- Separate UNIX users per device session (a larger architectural change
  than the keyring; revisit only if extra sessions ever become
  different principals).

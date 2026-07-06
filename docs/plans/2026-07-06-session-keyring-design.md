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

## Out of scope

- Empty-password / plaintext keyrings (rejected: not production-grade).
- Unifying the passphrase with the kasmVNC Basic-auth password
  (rejected: needs a custom auth shim, large surface).
- Separate UNIX users per device session (a larger architectural change
  than the keyring; revisit only if extra sessions ever become
  different principals).

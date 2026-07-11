# Changelog

All notable changes to Coworkstation are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- **`cws reconfigure`** re-applies the idempotent config a fresh `setup`
  writes but a code-only `cws update` cannot reach — system polkit
  rules and each user's generated session config (`xstartup`/yaml) +
  autostart, for the primary user and every member. Closes the gap
  where a shipped config fix (e.g. the colord rule) needed a full
  re-provision to land on a running box. `cws update` now points at it.
  Idempotent; effective on the next session start.

- **Persistent, passphrase-protected sign-in.** Claude's "sign-in won't
  be saved" came from having no usable secret store: a VNC/RDP desktop
  is not a PAM login, so gnome-keyring never created a login keyring,
  and XFCE never put `DISPLAY`/`XAUTHORITY` in the D-Bus activation
  environment, so its `gcr` unlock prompt could not render. `cws-launch`
  now (for primary/member sessions) exports that environment and asks
  gnome-keyring to create-or-unlock the login keyring before Claude
  starts; the member sets and enters their own passphrase in-session
  (self-service), and sign-in then persists encrypted at rest. Extra
  `cws-sessions/<N>` device sessions are unchanged (`--password-store=
  basic`; they are the same person on a second device, so there is no
  principal to isolate). If the member does not set up the keyring
  (cancels the prompt, it times out, or `secret-tool` is absent), the
  launch falls back to the plaintext store so Claude never blocks on a
  keyring prompt it cannot complete — the pre-keyring behaviour, minus
  the hang. Design + threat model:
  `docs/plans/2026-07-06-session-keyring-design.md`.

### Fixed

- **colord PolicyKit prompt on every session start** — a kasmVNC/xrdp
  desktop is not a logind "local"/"active" seat, so colord's
  device/profile actions fell through to the admin-auth rule and popped
  "Authentication is required to create a color managed device". Setup
  now installs a polkit rule (`/etc/polkit-1/rules.d/40-cws-colord.rules`)
  granting the `org.freedesktop.color-manager.*` action group — a
  headless appliance does no colour management. Found in live validation.

- **Extra-session Claude hung blank on the secret service** — an extra
  session runs on its own private D-Bus (the `dbus-run-session` that
  fixes the `:50+` black screen), whose `xdg-desktop-portal` exposes a
  secret-service proxy with no working backend. Electron's default
  `gnome_libsecret` probe blocks against it at startup, so the window
  never paints — distinct from the singleton hang, and only reproducible
  under the session bus (a bare bus fails the probe fast and loads).
  `cws-launch` now passes `--password-store=basic` for extra sessions so
  Electron skips the secret service entirely; these sessions already
  can't persist an encrypted sign-in, so nothing is lost but the hang.
  The primary session (responsive keyring on the shared user bus) keeps
  the default. Found in live client-side validation.
- **Claude Desktop hung as a blank window after an unclean shutdown** —
  Electron records the running instance in `SingletonLock` (a host-pid
  symlink) with a `SingletonSocket` under `/tmp`. A crash leaves them
  behind; on reboot `/tmp` is wiped and the recorded pid is often
  reused by another process (frequently the primary session's Claude),
  so Electron thinks the profile is already owned, tries to hand off to
  the vanished socket, and hangs before painting. `cws-launch` now
  clears the stale singleton trio when its socket target is dangling
  (a live owner's socket exists, so this never races a real instance).
  The guardian also now honors `XDG_CONFIG_HOME`, so it guards and
  heals each extra session's own config home rather than always the
  primary's. Found in live client-side validation.
- **Extra per-device sessions (`:50+`) rendered a black screen** — the
  X server came up but no desktop. All of one member's sessions
  inherit the systemd user D-Bus bus (`/run/user/<uid>/bus`), and
  `xfce4-session`'s `org.xfce.SessionManager` is a per-bus singleton,
  so the second desktop found the name already owned by the primary
  and exited immediately. The per-session `XDG_CONFIG_HOME` fixes
  Claude's config-dir lock but not xfce's D-Bus lock. The xstartup
  now launches `:50+` under `dbus-run-session` so each extra session
  gets its own private bus. Found in live client-side validation.
- **Member/extra-session hostnames flatten to one label below the
  zone** (`bob-cws.zone` instead of `bob.cws.zone`): Cloudflare's
  free Universal SSL only covers one subdomain level, so the dotted
  scheme failed TLS at the edge — found on a live from-zero install.
  Manual mode (no recorded zone) keeps the dotted form.
- `cws audit` no longer renders an empty table when the Access-log
  fetch fails; the capture-before-jq fix also repairs the log
  rendering itself (cf_call already unwraps `.result`) and the
  missing-permission hint now actually prints.
- `cws sessions` lists extra per-device sessions from the registry
  (`user:sN` rows) instead of silently omitting them.
- Doctor no longer prints duplicate Access-coverage lines for a
  hostname with both a path rule and a plain rule.
- Setup's next steps say `cws doctor` / `cws credentials` (not raw
  script paths) and state the Cowork/KVM situation explicitly.
- `cws devices` explains an empty registry; restic installs with
  `--no-install-recommends` (was pulling ~38 MB of doc fonts).

### Added

- **Concurrent per-device sessions (MDM phase 3c, ADR-010).**
  `cws session add USER [--allow EMAIL]` provisions an extra desktop
  on the :50+ display range with its own unit, port, hostname
  (`USER-sN.<base>`), DNS + Access policy, and — via an xstartup
  branch — its own `XDG_CONFIG_HOME`, so a second Claude Desktop runs
  beside the first with its own sign-in (the singleton lock is per
  config dir). `cws session remove` reverses it (config home kept);
  `cws session list` shows the registry.

- **Reclaim policy + scheduling (3b tail).** Per-member idle windows
  (`idle_hours.NAME=N` overrides the global), a DORMANT state in
  `cws sessions` for stopped sessions idle past `dormant_days`
  (deletion stays manual), and setup now installs an hourly
  `cws-reclaim.timer` that is a no-op until `reclaim.conf` opts in.

- **Encrypted backup (ADR-009).** `cws backup setup|run|list` wraps
  restic: client-side encrypted snapshots of every session home
  (cache excludes, `coworkstation` tag) to any restic target
  including rclone remotes; 0600 key in `/etc/coworkstation`, loud
  copy-the-key warning, runs recorded in the ops log, raw
  passthrough via `cws backup restic ...`. Live hosting price check
  (`docs/research/2026-07-05-hosting-prices.md`): OVH SYS-1 verified
  at $33.20/mo (~$6-8/member), GCP nested-virt machine-series
  restrictions verified (no E2, Intel-only).

- **Idle reclaim (MDM phase 3b, opt-in).** `cws reclaim [--dry-run]`
  stops sessions that are cold on BOTH signals — no established
  client connections and no bridge activity within `idle_hours`
  (`/etc/coworkstation/reclaim.conf`, default off) — the
  Coder-plus-WorkSpaces heuristic from the pass-3 research. Homes
  persist; every reclaim lands in the ops log.

- **Device inventory (MDM phase 3a, ADR-008).** The bridge mints a
  per-device cookie and records the Cloudflare Access identity, user
  agent, and first/last-seen per request (0600 registry, capped,
  best-effort); `cws devices` lists devices fleet-wide. Third
  research report (`2026-07-05-moat-research-3.md`): verified
  session-lifecycle blueprints (Kasm keepalive/expiry, Coder
  states + idle bump, WorkSpaces reclaim pitfall) and the proof that
  browser-only cryptographic device identity is impossible on
  Cloudflare (WARP + MDM file only).

- **Fleet management (MDM phase 2, ADR-008).** `cws audit [DAYS]` —
  Access login history (Cloudflare API, api mode), kasmVNC session
  unit events (journald), and a 0600 operator ops log. `cws sessions
  stop|start|restart USER` — remote session actions, every action
  recorded. `cws member add --allow EMAIL[,..]` — per-member Access
  policy (forced per-member auth). Fixes member client-bridge routes:
  the member hostname is now computed before bridge setup, so
  `/bridge` path rules land on member hostnames too.

- **Fleet reporting (MDM phase 1, ADR-008).** `cws sessions` — every
  session account, desktop state, attached clients, up-since. `cws
  usage [USER...]` — per-member Claude token usage summed from Claude
  Code's local JSONL logs (request-id dedup; local-only, no API
  calls; chat/Cowork excluded and labeled as such). New
  `lib/fleet.sh` + `tests/fleet.bats`.

- **Decision records + moat research.** `docs/decisions.md` (ADR format:
  engine posture, kasmVNC vs Selkies, client-bridge direction, why no
  bwrap Cowork backend, zero-trust roadmap, MCP-moat caveat) and
  `docs/research/2026-07-05-moat-research.md` — the full
  adversarially-verified deep-research report the ADRs cite, including
  refuted claims and coverage gaps. A second pass
  (`2026-07-05-moat-research-2.md`) covers Kasm Workspaces licensing,
  Guacamole, Anthropic's account-sharing/OAuth terms, and the
  private-MCP connector question; it resolves ADR-006 (stdio on the
  box is the only reliable zero-exposure MCP path today) and adds
  ADR-007 (integrate Claude Code Usage Monitor for per-member token
  observability).

- **Client bridge — the box now feels native to whatever device
  connects.** `cws-launch` guardian wraps the launcher and rotates
  config backups (config-wipe recovery; idea credit
  claude-desktop-debian, from-scratch launcher-only impl). A **browser
  bridge** at `https://<hostname>/bridge/` (path-routed behind the same
  Access gate) shares the device's **screen** (loud per-session
  consent → Claude's `client_screenshot` MCP tool) and **folders**
  (desktop Chrome/Edge → `~/ClientBridge/`). A **laptop live-mount**
  helper (`client/cws-client`) reverse-mounts a local folder into the
  box over SSH-target mode. All provisioned per user, non-fatal,
  re-runnable; live node harness + BATS cover them.
- **Bridge PWA + clipboard bridge.** The bridge page is installable
  (manifest, icon, network-first service worker; the link token is
  remembered per device) and gains a token-gated clipboard bridge
  (`/bridge/clipboard`) shuttling text between the device and the box
  session's X clipboard (xclip on the session display, file
  fallback) — closes the iPad/WebKit clipboard gap kasmVNC leaves
  (seamless clipboard is Chromium-only). See ADR-003.
- **ClientSync — device↔box file sync is now the default, out of the
  box.** Every user gets a Syncthing instance and `~/ClientSync` at
  setup (and per member at `member.sh add`); `cws client
  add-device <ID>` pairs a phone/tablet/laptop (Möbius Sync on iOS,
  Syncthing elsewhere), with explicit consent on both ends and only
  the picked folder syncing. The synced folder is a plain directory,
  so Cowork mounts and the Code tab consume it directly. Cloud-drive
  mounts remain as the optional `cws storage add`. Interactive pairing
  lives in the `cws` menu ("pair a device").

- **`cws` — the Coworkstation CLI.** One command in front of the tools:
  run bare on a terminal for an interactive menu (doctor, credentials,
  add a cloud drive, add/list members, SSH-target config, re-run setup,
  update), or dispatch directly (`cws member add`, `cws storage add`,
  `cws doctor`, `cws credentials`, `cws update`, `cws version`).
  Installed onto PATH by both install paths; the underlying scripts
  remain the tested plumbing.
- README "What it unlocks": an architecture diagram (Mermaid) and a
  without/with table stating the value proposition — the local-compute
  jobs (persistent sessions, 24/7 MCP, real-filesystem Code work,
  Cowork VM on own hardware) that neither claude.ai in a browser nor a
  carried laptop provides.

### Changed

- **Aligned with claude-desktop-debian v3.0.0** (released upstream on
  2026-07-04): the community build now repackages Anthropic's official
  Linux `.deb` with the app bytes unmodified, renamed
  `claude-desktop-unofficial`, and its bwrap Cowork backend is parked —
  so the `repo` engine installs the new package name (with a
  transitional fallback), `COWORK_VM_BACKEND=bwrap` is no longer
  written (both engines are KVM-or-nothing for the Cowork VM,
  `backend=kvm|none`), the doctor accepts either launcher binary, the
  autostart entry targets whichever launcher is installed, and every
  "bwrap Cowork" claim in the docs is corrected. The repo engine's
  terms posture softens accordingly (packaging wrapper, not a patched
  app) and its remaining value is the hardened launcher, doctor, and
  rpm/AppImage/Nix formats.
- Post-install next-steps, README, and runbook speak `cws` first;
  README Status explicitly marks arm64 as untested (code path only).

## [0.2.1] - 2026-07-05

Fixes found while validating the whole product end-to-end on live boxes
(desktop session, member add, storage, reboot persistence, multi-distro).

### Fixed

- **Two Coworkstation boxes in one Cloudflare account no longer collide.**
  The tunnel name is derived from the hostname
  (`coworkstation-<hostname>`); a fixed name meant a second box adopted
  the first's tunnel and merged ingress, so hostnames routed to the
  wrong connector.
- **kasmVNC installs on Debian 13 (and future codenames).** The host
  codename maps to the nearest kasmVNC-shipped build (trixie -> bookworm,
  newer Ubuntu -> noble) instead of 404-ing on a missing per-codename
  `.deb`; a genuinely missing asset now fails with an actionable message.
  (Live-confirmed: Debian 13 went from install-fail to kasmVNC listening.)
- **cloud-init no longer stalls on first-boot apt-lock contention.**
  `images/cloud-init.yaml` stops the distro's apt-daily / unattended
  timers in `bootcmd` before the package phase (this hung provisioning
  for many minutes on fresh droplets).
- `gen-sshconfigs.sh` labels the environment-picker entry "Coworkstation"
  (was the stale "Cowork appliance").
- `install.sh` checks its target dir before the root gate (most
  dangerous misconfiguration fails first) and gains BATS coverage.

## [0.2.0] - 2026-07-05

First published release. 0.1.0 existed only as repository history; the
0.2.0 entries below therefore include the initial feature set plus the
fixes and hardening from the from-zero audit and two live validations.

### Added

- `install.sh` — network installer (`curl … | sudo bash`) for prod,
  plus `setup.sh` for clone-and-run; refuses dangerous
  `COWORKSTATION_DIR` values, never silently falls back to the default
  branch when a ref was pinned, and supports `COWORKSTATION_SHA` to
  verify the checkout before executing anything.
- `setup.sh` — one-command provisioning: engine install, XFCE +
  kasmVNC session (per-user cert, non-interactive control user, random
  credentials in `~/.vnc/kasm-credentials`), Cloudflare tunnel (manual
  or zero-touch API mode), XDG autostart, unattended-upgrades, and an
  interactive wizard on a TTY. Creates a default `cowork` account when
  run as root with no `--user` (the fresh-VPS case).
- Zero-touch Cloudflare edge via a scoped API token: remotely-managed
  tunnel, ingress, proxied DNS, and Access application + allow policy,
  non-interactively. The account id is derived from the zone, so the
  documented resource-scoped token is sufficient.
- **Doctor** (`./setup.sh doctor`): engine/backend record, live
  loopback-listener check, public-bind scan across the full member
  port range, tunnel checks, keyring state, and an **Access-coverage
  check** — in api mode every tunnel ingress hostname without an
  Access app is a FAIL (an ungated proxied hostname is a public
  desktop).
- `member.sh` — multi-user lifecycle (advanced): per-member account
  (0700 home), systemd slice quotas, own kasmVNC display/port and
  hostname, per-user-accounts terms warning, exclusive locking, and a
  confirmation gate before home-deleting removals.
- `storage.sh` — remote-backed storage (Google Drive / OneDrive /
  Dropbox) with a bounded rclone VFS cache; OAuth token written
  directly to the member's `0600` rclone.conf.
- `gen-sshconfigs.sh` — managed-settings `sshConfigs` generator for
  SSH-target mode.
- `testbench/` — experimental computer-use-substitute MCP servers.
- `images/` — cloud-init bootstrap and Raspberry Pi notes.
- CI: shellcheck, node --check, cloud-init YAML validation, and the
  BATS suite with a live Xvfb end-to-end; a **Release workflow**
  (workflow_dispatch) that gates on the test suite, then creates the
  annotated tag and GitHub Release from CI.
- Reconcile-on-rerun: an ingress rule whose port moved is updated in
  place, and a changed `--access-allow` list updates the existing
  Access policy.
- Hardware-validated on DigitalOcean Ubuntu 24.04 VPSes on BOTH
  engines: the default official engine (Anthropic apt package,
  `/dev/kvm` present, `backend=kvm`) and the opt-in repo engine
  (bwrap). Each run: bare box → documented install → kasmVNC behind
  Cloudflare Access, doctor clean including the Access-coverage check.
  Raspberry Pi remains specified but not hardware-verified.

### Changed

- **BREAKING: engine auto-selection always picks the official
  Anthropic build on Debian-family hosts.** A KVM-less host previously
  got the community `claude-desktop-debian` repackaging silently; now
  the unmodified first-party binary is never traded away automatically
  — without `/dev/kvm` the Cowork VM feature is reported unavailable
  (`backend=none`, doctor WARN) and the repo build requires an
  explicit `--engine repo` opt-in with a terms warning (it remains the
  automatic fallback only on non-Debian distros).
- **BREAKING: user-visible naming unified on Coworkstation** — config
  root `/etc/coworkstation` (was `/etc/claude-appliance`), tunnel name
  `coworkstation` (was `claude-appliance`), log prefix
  `[coworkstation]`, unit descriptions and slice/env drop-in
  filenames. Internal `APPLIANCE_*` test seams are unchanged and
  documented as historic.
- README repositioned around single-user personal infrastructure and
  the local-compute jobs the web can't do; SSH-target mode leads;
  multi-user is an "Advanced" section with the terms posture spelled
  out; prerequisites, the Cloudflare token recipe, honest Alpha
  status, and a License & terms section.
- `docs/design.md` gains a "Positioning & risk" section (the product
  bet, multi-user posture, engine legal posture, and the triggers that
  should force a scope rethink).

### Fixed

- Zero-touch provisioning aborted for the documented resource-scoped
  token (`GET /accounts` returns an empty list for such tokens).
- Fresh-VPS root install died with "cannot determine target user";
  the default-account creation itself then leaked its log line into
  the captured username (caught by the live install) — logging now
  goes to stderr, with a regression test.
- `jq`/`openssl`/`gnupg` are installed before the paths that need
  them (the first Cloudflare call previously failed as a misleading
  "token failed verification").
- `member.sh add` provisions the kasmVNC cert and control user, so an
  added member's session actually starts.
- A forgotten flag value no longer hangs any argument parser
  (`require_value` guard everywhere).
- `member.sh`, `storage.sh`, `gen-sshconfigs.sh`, `testbench/setup.sh`
  are committed executable (the cloud-init clone path invokes them
  directly).
- Every `cf_call | jq` pipeline captures the response first, so a
  transient API failure can no longer masquerade as "not found" —
  worst case previously created a second tunnel of the same name.
- An `--engine` switch on re-run retargets the apt source (the list
  file is force-written); the doctor reports "cannot verify" instead
  of a spurious FAIL when `ss` is unavailable; `--cache-max` is
  validated; the ingress idempotency guard no longer treats hostname
  dots as regex wildcards.

### Security

- The Cloudflare API token travels to `curl` via stdin config, and the
  rclone OAuth token is written directly into the member's `0600`
  rclone.conf — neither ever appears on argv (`/proc/*/cmdline` is
  world-readable on a multi-user box).
- The cloudflared connector-token unit file is locked to `0600`;
  member homes are `chmod 700`; hostnames are validated as FQDNs; the
  kasmVNC key is generated under `umask 077`.
- `--access-allow` is validated before any provisioning: at least one
  well-formed email/domain is required, and a bare PUBLIC mail-provider
  domain (gmail.com, outlook.com, …) is a hard error — it would admit
  every account at that provider.
- Doctor: session ports are scanned across the full member range and a
  wildcard bind is never reported as a healthy listener.

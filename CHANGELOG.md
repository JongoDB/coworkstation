# Changelog

All notable changes to Coworkstation are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

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

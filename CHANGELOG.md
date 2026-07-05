# Changelog

All notable changes to Coworkstation are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

- **BREAKING: engine auto-selection always picks the official Anthropic
  build on Debian-family hosts.** Previously a KVM-less host silently
  got the community `claude-desktop-debian` repackaging; now the
  unmodified first-party binary is never traded away automatically —
  without `/dev/kvm` the Cowork VM feature is reported unavailable
  (`backend=none`, a doctor WARN) and the repo build requires an
  explicit `--engine repo` opt-in with a terms warning.
- README repositioned around single-user personal infrastructure and
  the local-compute jobs the web can't do (Code tab on a real
  filesystem, own MCP servers, persistent sessions). SSH-target mode
  leads; multi-user is an "Advanced" section with the per-account terms
  posture spelled out; `testbench/` is marked experimental.
- `docs/design.md` gains a "Positioning & risk" section stating the
  product bet, the multi-user posture, the engine legal posture, and
  the triggers (web Cowork, mobile Code, first-party Linux computer
  use) that should force a scope rethink.

### Added

- **Doctor: Access-coverage check.** In api mode the doctor enumerates
  the tunnel's ingress hostnames and FAILs on any without a Cloudflare
  Access application (a proxied hostname with no Access app is a public
  desktop that looked healthy in every other check). Manual mode warns
  that coverage can't be verified.
- `member.sh add` prints a per-user-accounts terms warning; api mode
  confirms the Access app was provisioned.
- Reconcile-on-rerun: `ingress_json_add` updates a rule whose port
  moved instead of keeping it stale, and `cf_access_ensure_app` updates
  an existing allow policy when `--access-allow` changed.

### Fixed

- **Zero-touch install no longer fails on a correctly-scoped token.** The
  Cloudflare account id is now discovered from the zone (a
  resource-scoped token cannot list `/accounts`; Cloudflare returns an
  empty array, which previously aborted provisioning).
- **Fresh-VPS install works as root.** With no `--user`/`$SUDO_USER`,
  `setup.sh` provisions a default `cowork` account instead of dying with
  "cannot determine target user."
- **`jq`/`openssl`/`gnupg` are installed** before the paths that need
  them, so the zero-touch flow no longer fails at the first API call with
  a misleading "token failed verification."
- **`member.sh add` provisions the kasmVNC cert and control user**, so an
  added member's session actually starts (previously it exited 1 on a
  missing cert or looped forever on the control-user prompt).
- **A forgotten flag value no longer hangs the parser** — `require_value`
  aborts instead of spinning the argument loop forever.
- `member.sh`, `storage.sh`, `gen-sshconfigs.sh`, `testbench/setup.sh`
  are committed executable (the cloud-init clone path invoked them
  directly).
- `cf_tunnel_ensure` captures the API response before parsing, so a
  transient error can no longer create a second tunnel of the same name.

### Security

- The Cloudflare API token is passed to `curl` via stdin config, not
  argv (`/proc/*/cmdline` is world-readable on a multi-user box).
- The rclone OAuth token is written straight into the member's `0600`
  `rclone.conf` instead of appearing on `rclone config create`'s argv.
- The cloudflared connector-token unit file is locked to `0600`.
- Each member's home is `chmod 700`; hostnames are validated; member
  removal confirms before wiping a home; the kasmVNC key is generated
  under `umask 077`; the doctor's port scan scales past ~7 members and
  no longer treats a wildcard bind as a healthy listener.

### Changed

- README rewritten: prerequisites, a fully-flagged primary install
  command, the Cloudflare token recipe, an honest Alpha status, and a
  License & terms section (per-user accounts; official-vs-repo engine).
- Docs re-pathed from the old `appliance/` subtree to the repo root.

### Added

- Initial release, migrated from the `appliance/` layer of
  `aaddrick/claude-desktop-debian` (fork), as a standalone project.
- `install.sh` — network installer (`curl … | sudo bash`) for prod, plus `setup.sh` for clone-and-run.
- `setup.sh` — one-command provisioning with engine auto-selection
  (official Anthropic apt build with KVM; claude-desktop-debian build
  with the bwrap Cowork backend otherwise), XFCE + kasmVNC session,
  Cloudflare tunnel (manual or zero-touch API mode), XDG autostart, and
  a doctor that fails loudly on any session port bound beyond loopback.
- Zero-touch Cloudflare edge via a scoped API token: tunnel, ingress,
  proxied DNS, and Access application + allow policy, non-interactively.
- `member.sh` — multi-user lifecycle: per-member account, systemd slice
  quotas, kasmVNC display/port, ingress hostname, autostart.
- `storage.sh` — remote-backed storage (Google Drive / OneDrive /
  Dropbox) mounted with a bounded rclone VFS cache.
- `testbench/` — computer-use-substitute MCP servers: disposable
  nested-display GUI control and an experimental QEMU-guest driver.
- `gen-sshconfigs.sh` — managed-settings `sshConfigs` generator for
  SSH-target mode.
- `images/` — cloud-init bootstrap and Raspberry Pi notes.
- BATS suite; a CI workflow running shellcheck, node --check,
  cloud-init YAML validation, and the suite with a live Xvfb
  end-to-end.
- Hardware-validated on DigitalOcean Ubuntu 24.04 VPSes on BOTH
  engines: the default official engine (Anthropic apt package,
  /dev/kvm present, backend=kvm) and the opt-in repo engine (bwrap).
  Each run: bare box → documented install → kasmVNC behind Cloudflare
  Access, doctor clean including the Access-coverage check. Five
  headless-startup bugs found and fixed during the first validation
  (user-manager bus, kasmVNC control-user prompt, per-user TLS cert,
  doctor listener check, nested-subdomain TLS warning). Raspberry Pi
  remains specified but not hardware-verified.

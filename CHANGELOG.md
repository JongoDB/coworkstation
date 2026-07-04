# Changelog

All notable changes to Coworkstation are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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
- One happy path hardware-validated on a DigitalOcean Ubuntu 24.04 VPS
  (repo engine + bwrap): the install brings up kasmVNC behind Cloudflare
  Access with Claude Desktop, doctor clean. Five headless-startup bugs
  found and fixed during that validation (user-manager bus, kasmVNC
  control-user prompt, per-user TLS cert, doctor listener check,
  nested-subdomain TLS warning). The official-engine + KVM and
  Raspberry Pi paths are specified but not yet hardware-verified.

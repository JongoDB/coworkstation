# Changelog

All notable changes to Coworkstation are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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
- 134 BATS tests; a CI workflow running shellcheck, node --check,
  cloud-init YAML validation, and the suite with a live Xvfb
  end-to-end.
- Hardware-validated on a DigitalOcean Ubuntu 24.04 VPS: the documented
  one-shot install brings up kasmVNC behind Cloudflare Access with
  Claude Desktop, doctor clean. Five headless-startup bugs found and
  fixed during that validation (user-manager bus, kasmVNC control-user
  prompt, per-user TLS cert, doctor listener check, nested-subdomain
  TLS warning).

# Coworkstation

Turn a bare Linux box into a **self-hosted, team-accessible Claude Desktop / Cowork workstation** — reachable from any browser (iPad, Android, laptop) behind Cloudflare Access, with one command.

## Install

Coworkstation is an **installer/orchestrator**, not a binary app — there's no `.deb` to download because the actual Claude Desktop binary is installed *by* Coworkstation from its upstream source (see [Engine](#how-it-works) below). Two entry points:

```bash
# Prod — download and run (no clone needed):
curl -fsSL https://raw.githubusercontent.com/JongoDB/coworkstation/main/install.sh | sudo bash

# Dev — clone and run. Either way an interactive wizard prompts for anything missing:
git clone https://github.com/JongoDB/coworkstation
sudo coworkstation/setup.sh
```

Both accept the same flags (pipe form: `... | sudo bash -s -- --hostname …`). See [Quick start](#quick-start-zero-touch) for the non-interactive form.

## How it works

Coworkstation **composes upstream-maintained parts** — it consumes Claude Desktop engines rather than forking them, so it grows with the real thing:

- **Engine**: Anthropic's official Claude Desktop for Linux where KVM is available; the [`claude-desktop-debian`](https://github.com/aaddrick/claude-desktop-debian) build (bwrap Cowork backend) everywhere else. Auto-selected.
- **Access**: browser-only — per-user kasmVNC sessions behind a **Cloudflare Zero Trust** tunnel + Access (SSO/MFA). No client install, no open inbound ports.
- **Storage**: project folders live in the member's Google Drive / OneDrive / Dropbox via rclone with a bounded local cache, so the box stays small.

Validated end-to-end on a real VPS: bare Ubuntu 24.04 → `setup.sh` → kasmVNC serving behind Cloudflare Access, Claude Desktop installed, `--doctor` clean.

## What you get

| | |
|---|---|
| **One-command install** | `setup.sh` with an interactive wizard, or fully non-interactive flags for cloud-init |
| **Zero-touch edge** | `--cf-api-token-file` provisions the Cloudflare tunnel, DNS, and Access policy via API — no `cloudflared tunnel login` |
| **Multi-user** | `member.sh add/remove/list` — per-member Linux account, systemd slice quotas, own session + hostname |
| **Remote storage** | `storage.sh` mounts cloud drives with a bounded cache |
| **Test bench** | MCP servers for GUI app-testing on disposable displays and QEMU guests (a computer-use substitute) |
| **SSH-target mode** | `gen-sshconfigs.sh` makes the box appear in members' own desktop apps for Code-tab work |
| **Doctor** | `setup.sh doctor` — fails loudly on any session port bound beyond loopback; verifies a live listener |

## Quick start (zero-touch)

Create a scoped Cloudflare API token (Account › Cloudflare Tunnel:Edit, Account › Access: Apps and Policies:Edit, Zone › DNS:Edit), then:

```bash
printf '%s' 'YOUR-CF-API-TOKEN' > /root/cf-token && chmod 600 /root/cf-token
sudo coworkstation/setup.sh --hostname cws.example.com \
    --cf-api-token-file /root/cf-token --access-allow you@example.com
```

That provisions the engine, kasmVNC, the Cloudflare tunnel + DNS + Access policy, and the connector. Full walkthrough: [`docs/runbook.md`](docs/runbook.md).

## Signing in

Two gates protect the session:

1. **Cloudflare Access** (outer door) — your identity provider (Google/Entra/GitHub/OIDC) via the `--access-allow` list. This is the real security boundary; it's SSO, no separate password.
2. **kasmVNC** (the desktop, behind Access) — a per-user login. `setup.sh` creates the control user (the Linux username, e.g. `jongodb`) with a random password written to `~/.vnc/kasm-credentials` on the box (mode `0600`). Read it once and hand it to the member:
   ```bash
   sudo cat /home/<user>/.vnc/kasm-credentials
   ```

Open `https://<hostname>`, pass the Access login, enter the kasmVNC credentials, then sign into Claude Desktop inside the session. The member's Claude sign-in populates the keyring on first use.

## Docs

- [`docs/design.md`](docs/design.md) — architecture, feature-parity matrix, access model, multi-tenancy
- [`docs/phases.md`](docs/phases.md) — component specs, acceptance criteria, test environments, sizing
- [`docs/runbook.md`](docs/runbook.md) — provision, members, edge, storage, backup, troubleshooting

## Layout

```
install.sh                                         # network installer (curl | sudo bash)
setup.sh member.sh storage.sh gen-sshconfigs.sh   # entry points
lib/            # common, engine selection, doctor, tunnel API, session profiles
testbench/      # computer-use-substitute MCP servers
images/         # cloud-init + Pi notes
tests/          # BATS suites (run: bats tests/*.bats)
```

## Testing

```bash
bats tests/*.bats            # 134 tests: pure-logic, mocked infra, live Xvfb e2e
shellcheck -x install.sh setup.sh member.sh storage.sh gen-sshconfigs.sh lib/*.sh lib/profiles/*.sh
```

## Status

Beta. Tier 1 (x86 VPS, bwrap engine) is hardware-validated. Tier 2 (mini-PC + KVM) and Tier 3 (Raspberry Pi 5) are specified in [`docs/phases.md`](docs/phases.md#test-environments) and pending hardware verification. Computer use on Linux is not available upstream; the test bench is the substitute for the app-testing use case.

## License

MIT (see [LICENSE](LICENSE)). The Claude Desktop application itself is subject to [Anthropic's Consumer Terms](https://www.anthropic.com/legal/consumer-terms). Coworkstation orchestrates installation and access; it does not modify or redistribute the Claude Desktop application.

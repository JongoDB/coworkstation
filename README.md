# Coworkstation

Turn a bare Linux box into a **self-hosted Claude Desktop / Cowork workstation** you reach from any browser (iPad, Android, laptop) behind Cloudflare Access.

> **Not affiliated with Anthropic.** Coworkstation installs and wires up the Claude Desktop app; it does not modify or redistribute it. You are responsible for complying with [Anthropic's terms](https://www.anthropic.com/legal/consumer-terms) and your plan tier — in particular, each person must sign in with their **own** Claude account. See [License & terms](#license--terms).

## Before you start

Coworkstation provisions the box; it does not create these for you:

- A **domain on Cloudflare** — the zone's nameservers must already be delegated to Cloudflare (an active zone, not just a registration).
- A **Cloudflare Zero Trust organization** with at least one login method (the default one-time-PIN works; Google/Entra/GitHub/OIDC if you've configured them). Access uses this to authenticate users.
- A **fresh VPS/mini-PC**: Ubuntu 24.04 or Debian 12+, **≥ 4 GB RAM** and **≥ 25 GB disk** per active session (an Electron app + XFCE + kasmVNC is not tiny). x86-64 or arm64.
- A **Claude subscription** for each member. The tunnel runs on this same box (outbound-only) — no second machine.

## Install

Coworkstation is an **installer/orchestrator**, not a binary app — there's no `.deb` to download, because the actual Claude Desktop binary is installed *by* Coworkstation from its upstream source (see [How it works](#how-it-works)). Run the zero-touch form with your hostname, a scoped Cloudflare token, and an allow-list:

```bash
# 1. Put a scoped Cloudflare API token in a file (see "Cloudflare token" below):
printf '%s' 'YOUR-CF-API-TOKEN' > /root/cf-token && chmod 600 /root/cf-token

# 2a. Prod — download and run (no clone). Runs as root on a fresh VPS; a
#     default 'cowork' session account is created if you don't pass --user:
curl -fsSL https://raw.githubusercontent.com/jongodb/coworkstation/main/install.sh \
    | sudo bash -s -- --hostname cws.example.com \
        --cf-api-token-file /root/cf-token --access-allow you@example.com

# 2b. Dev — clone and run. Run without flags in a terminal to get an
#     interactive wizard that prompts for the hostname, token, and allow-list:
git clone https://github.com/jongodb/coworkstation
sudo coworkstation/setup.sh
```

The piped `curl | sudo bash` form is **non-interactive** (its stdin is the pipe) — pass the flags. Only the clone-and-run form in a terminal starts the wizard.

That single command provisions the engine, a per-user kasmVNC session, the Cloudflare tunnel + DNS + Access policy, and the connector. Full walkthrough: [`docs/runbook.md`](docs/runbook.md).

### Cloudflare token

In the Cloudflare dashboard: **My Profile → API Tokens → Create Token → Create Custom Token**, then add three permissions and scope them to your account and zone:

| Type | Permission | Resource |
|---|---|---|
| Account | Cloudflare Tunnel : Edit | Include → your account |
| Account | Access: Apps and Policies : Edit | Include → your account |
| Zone | DNS : Edit | Include → your zone |

Coworkstation discovers your account id **from the zone**, so the token does not need account-list permission — but it *does* need the Zone and Account resources set to *Include* the right ones, or the API calls fail.

## How it works

Coworkstation **composes upstream-maintained parts** — it consumes Claude Desktop engines rather than forking them, so it grows with the real thing:

- **Engine**: Anthropic's official Claude Desktop for Linux where KVM is available; the [`claude-desktop-debian`](https://github.com/aaddrick/claude-desktop-debian) build (bwrap Cowork backend) everywhere else. Auto-selected. On a typical VPS without `/dev/kvm` this is the repo build — see [License & terms](#license--terms) for what that means.
- **Access**: browser-only — per-user kasmVNC sessions behind a **Cloudflare Zero Trust** tunnel + Access (SSO/MFA). No client install, no open inbound ports.
- **Storage**: project folders can live in the member's Google Drive / OneDrive / Dropbox via rclone with a bounded local cache, so the box stays small.

## What you get

| | |
|---|---|
| **Guided install** | `setup.sh` with an interactive wizard, or fully non-interactive flags for cloud-init |
| **Zero-touch edge** | `--cf-api-token-file` provisions the Cloudflare tunnel, DNS, and Access policy via API — no `cloudflared tunnel login` |
| **Multi-user** | `member.sh add/remove/list` — per-member Linux account, systemd slice quotas, own session + hostname |
| **Remote storage** | `storage.sh` mounts cloud drives with a bounded cache |
| **Test bench** | MCP servers for GUI app-testing on disposable displays and QEMU guests (a computer-use substitute) |
| **SSH-target mode** | `gen-sshconfigs.sh` makes the box appear in members' own desktop apps for Code-tab work |
| **Doctor** | `./setup.sh doctor` — fails loudly on any session port bound beyond loopback; verifies a live listener |

## Signing in

Two gates protect the session:

1. **Cloudflare Access** (outer door) — your identity provider via the `--access-allow` list. This is the real security boundary; SSO, no separate password.
2. **kasmVNC** (the desktop, behind Access) — a per-user login. `setup.sh` creates the control user (the Linux username, e.g. `cowork`) with a random password written to `~/.vnc/kasm-credentials` on the box (mode `0600`). The final "Next steps" output tells you the exact command to read it:
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
bats tests/*.bats            # pure-logic, mocked infra, live Xvfb e2e
shellcheck -x install.sh setup.sh member.sh storage.sh gen-sshconfigs.sh lib/*.sh lib/profiles/*.sh
```

## Status

**Alpha.** One happy path is hardware-validated end-to-end: an x86 VPS on the **repo engine + bwrap** backend (no `/dev/kvm`), serving kasmVNC behind Cloudflare Access with `./setup.sh doctor` clean. The **official-engine + KVM** path (Tier 2, mini-PC) and the Raspberry Pi path (Tier 3) are specified in [`docs/phases.md`](docs/phases.md#test-environments) but **not yet hardware-verified**. The BATS suite validates script logic and dry-run plans, not that Claude Desktop works over Access at scale. Computer use on Linux is not available upstream; the test bench is the substitute for the app-testing use case.

## License & terms

Coworkstation's own scripts are **MIT** (see [LICENSE](LICENSE)). That covers this orchestrator only — **not** the Claude Desktop application it installs, which is Anthropic's proprietary software under [Anthropic's Consumer Terms](https://www.anthropic.com/legal/consumer-terms).

Two things to understand before running this for more than yourself:

- **Per-user accounts.** Coworkstation gives every member their own Linux account and their own Claude sign-in. Do not share a single Claude login across people — that violates Anthropic's terms and trips account-security defenses (datacenter IP + shared session is exactly what anti-abuse systems flag).
- **The default engine on a typical VPS is the repo build.** Without `/dev/kvm`, Coworkstation installs [`claude-desktop-debian`](https://github.com/aaddrick/claude-desktop-debian), a community repackaging of the app. If you want to stay strictly on Anthropic's official binary, use a host with KVM and pass `--engine official`.

This project is not affiliated with, endorsed by, or supported by Anthropic. Running a shared, headless, multi-user deployment carries account-standing risk that is yours to accept.

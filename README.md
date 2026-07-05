# Coworkstation

Your own **always-on Claude Desktop box** — a personal Linux workstation running Anthropic's official Claude Desktop, reachable from any browser (iPad, Android, laptop) behind Cloudflare Access. The job it does that the web can't: **persistent, local-compute Claude** — Code-tab work on a real filesystem, your own MCP servers, long-running sessions that survive you closing the lid — without carrying a laptop.

> **Not affiliated with Anthropic.** Coworkstation installs Anthropic's official Claude Desktop package and wires up access to it; by default it does not modify or redistribute the app. You are responsible for complying with [Anthropic's terms](https://www.anthropic.com/legal/consumer-terms) and your plan tier. See [License & terms](#license--terms).

## Before you start

Coworkstation provisions the box; it does not create these for you:

- A **domain on Cloudflare** — the zone's nameservers must already be delegated to Cloudflare (an active zone, not just a registration).
- A **Cloudflare Zero Trust organization** with at least one login method (the default one-time-PIN works; Google/Entra/GitHub/OIDC if configured). Access uses this to authenticate you.
- A **fresh VPS/mini-PC**: Ubuntu 24.04 or Debian 12+, **≥ 4 GB RAM** and **≥ 25 GB disk** per active session (an Electron app + XFCE + kasmVNC is not tiny). x86-64 or arm64.
- A **Claude subscription**. The tunnel runs on this same box (outbound-only) — no second machine.

**KVM note:** Cowork's VM feature needs `/dev/kvm`, which most cheap VPSes don't expose. Without it, everything else (chat, Code tab, MCP, projects) works on the official app — setup tells you plainly. A mini-PC or KVM-capable host gets you the full feature set.

## Install

Coworkstation is an **installer/orchestrator**, not a binary app — there's no `.deb` to download, because the actual Claude Desktop binary is installed *by* Coworkstation from Anthropic's apt repository (see [Engines](#engines)). Run the zero-touch form with your hostname, a scoped Cloudflare token, and your email:

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

That single command provisions the engine, a kasmVNC session, the Cloudflare tunnel + DNS + Access policy, and the connector. Full walkthrough: [`docs/runbook.md`](docs/runbook.md).

### Cloudflare token

In the Cloudflare dashboard: **My Profile → API Tokens → Create Token → Create Custom Token**, then add three permissions and scope them to your account and zone:

| Type | Permission | Resource |
|---|---|---|
| Account | Cloudflare Tunnel : Edit | Include → your account |
| Account | Access: Apps and Policies : Edit | Include → your account |
| Zone | DNS : Edit | Include → your zone |

Coworkstation discovers your account id **from the zone**, so the token does not need account-list permission — but it *does* need the Zone and Account resources set to *Include* the right ones, or the API calls fail.

## Engines

- **`official` (the default, always).** Anthropic's own apt build, unmodified — the only engine squarely within the app's terms, and the one the project stands behind. Without `/dev/kvm` the Cowork VM feature is unavailable and setup + doctor say so; nothing else is affected.
- **`repo` (explicit opt-in only, `--engine repo`).** The community [`claude-desktop-debian`](https://github.com/aaddrick/claude-desktop-debian) repackaging, which patches the app to back Cowork with bwrap on KVM-less hosts. `auto` never selects it on a Debian-family host — choosing a modified binary is a terms posture you must pick knowingly. It is also the automatic fallback on non-Debian distros, where no official build exists.

## What you get

| | |
|---|---|
| **Guided install** | `setup.sh` with an interactive wizard, or fully non-interactive flags for cloud-init |
| **Zero-touch edge** | `--cf-api-token-file` provisions the Cloudflare tunnel, DNS, and Access policy via API — no `cloudflared tunnel login` |
| **SSH-target mode** | `gen-sshconfigs.sh` makes the box appear in your own desktop app's environment picker for Code-tab work — often the best experience, no VNC needed |
| **Browser desktop** | a kasmVNC session behind Access when you need the full GUI (Cowork, the desktop app itself) |
| **Remote storage** | `storage.sh` mounts Google Drive / OneDrive / Dropbox with a bounded cache, so the box stays small |
| **Doctor** | `./setup.sh doctor` — verifies a live loopback listener, flags any session port bound beyond loopback, and **checks every tunnel hostname has an Access policy** |

## Signing in

Two gates protect the session:

1. **Cloudflare Access** (outer door) — your identity provider via the `--access-allow` list. This is the real security boundary; SSO, no separate password.
2. **kasmVNC** (the desktop, behind Access) — a per-user login. `setup.sh` creates the control user (the Linux username, e.g. `cowork`) with a random password written to `~/.vnc/kasm-credentials` on the box (mode `0600`). The final "Next steps" output tells you the exact command to read it:
   ```bash
   sudo cat /home/<user>/.vnc/kasm-credentials
   ```

Open `https://<hostname>`, pass the Access login, enter the kasmVNC credentials, then sign into Claude Desktop inside the session. Your Claude sign-in populates the keyring on first use.

## Advanced: more than one person (read this first)

`member.sh add/remove/list` can host additional people — per-member Linux account (0700 home), systemd slice quotas, own session/port/hostname, own Access gate. **Before you use it, understand the posture:**

- **Each member signs in with their own Claude account.** Sharing one Claude login across people violates Anthropic's terms, and a shared session from a datacenter IP is exactly what account-security systems flag.
- A multi-user datacenter box fanning people into Claude is a **materially riskier arrangement** than personal use — account standing is your risk to accept, and generic multi-user VDI (Kasm Workspaces, Guacamole) may serve a team better.
- In manual tunnel mode a new member hostname is **public until you add its Access policy** — `member.sh` warns loudly and `./setup.sh doctor` fails on any ungated hostname in api mode.

## Extras (experimental)

`testbench/` ships MCP servers for GUI app-testing on disposable displays and QEMU guests — a computer-use substitute for testing desktop apps Claude builds. It is **experimental, unvalidated on real hardware, and may be split out or removed**; don't build a workflow on it yet.

## Docs

- [`docs/design.md`](docs/design.md) — architecture, positioning & risk, access model, multi-tenancy
- [`docs/phases.md`](docs/phases.md) — component specs, acceptance criteria, test environments, sizing
- [`docs/runbook.md`](docs/runbook.md) — provision, members, edge, storage, backup, troubleshooting

## Layout

```
install.sh                                         # network installer (curl | sudo bash)
setup.sh member.sh storage.sh gen-sshconfigs.sh   # entry points
lib/            # common, engine selection, doctor, tunnel API, session profiles
testbench/      # experimental computer-use-substitute MCP servers
images/         # cloud-init + Pi notes
tests/          # BATS suites (run: bats tests/*.bats)
```

## Testing

```bash
bats tests/*.bats            # pure-logic, mocked infra, live Xvfb e2e
shellcheck -x install.sh setup.sh member.sh storage.sh gen-sshconfigs.sh lib/*.sh lib/profiles/*.sh
```

## Status

**Alpha.** Hardware-validated end-to-end on **x86-64** VPSes, both engines: bare Ubuntu 24.04 → the documented install → kasmVNC behind Cloudflare Access, doctor clean (including the Access-coverage check) — once on the **default official engine with `/dev/kvm`** (Anthropic's apt package, `backend=kvm`), and once on the opt-in **repo engine + bwrap**. A full smoke test also validated `member.sh`, `storage.sh`, reboot persistence, and re-run idempotency live, plus a from-zero install on **Debian 13**.

**Not yet verified:**

- **arm64 (Raspberry Pi and other ARM hosts) — untested.** The code path (arch detection → arm64 `.deb`) exists and unit tests cover it, but no arm64 hardware has run the install. Treat arm64 as unvalidated until someone confirms it on a Pi 5 / Hetzner CAX.
- The Cowork **VM feature exercised inside a session** (install-level validation only — no one has driven an actual Cowork VM in the browser yet).
- A **live cloud-drive mount** (the `storage.sh` config + unit are validated; mounting a real Drive needs a real OAuth token).

The BATS suite validates script logic and dry-run plans, not Claude Desktop itself at scale.

## License & terms

Coworkstation's own scripts are **MIT** (see [LICENSE](LICENSE)). That covers this orchestrator only — **not** the Claude Desktop application it installs, which is Anthropic's proprietary software under [Anthropic's Consumer Terms](https://www.anthropic.com/legal/consumer-terms).

- The **default engine is Anthropic's official, unmodified package.** The community `repo` engine (a repackaging that patches the app) is available only by explicit `--engine repo` opt-in, and choosing it is your call to make against Anthropic's terms.
- **Per-user accounts, always.** One person per Claude sign-in. This project is not affiliated with, endorsed by, or supported by Anthropic; running headless/multi-user deployments carries account-standing risk that is yours to accept.

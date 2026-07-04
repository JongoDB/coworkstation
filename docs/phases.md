[< Back to README](../README.md)

# Cowork appliance — phase specifications

Executable specifications for the six implementation phases of the [Cowork appliance design](design.md): scope, file layout, interfaces, acceptance criteria, and test plan per phase.

- Every shell deliverable follows the [bash style guide](styleguides/bash_styleguide.md) and is shellcheck-clean
- Every phase ships BATS coverage using the repo's existing conventions (sourced libs, stubbed commands, `mktemp` sandboxes)
- Validation happens at two levels: **CI-testable** (mocked, runs anywhere) and **hardware-verify** (needs a real box; tracked as a checklist per phase)

## Repository layout (all phases)

```
appliance/
├── setup.sh                 # Phase 1 — provisioning orchestrator
├── member.sh                # Phase 2 — member lifecycle
├── gen-sshconfigs.sh        # Phase 4 — managed-settings generator
├── lib/
│   ├── common.sh            # logging, os/pkg detection, run/dry-run gate
│   ├── engine.sh            # engine selection rules (official vs repo build)
│   ├── doctor.sh            # appliance-doctor check functions
│   └── profiles/
│       ├── kasmvnc.sh       # default session layer
│       ├── xrdp.sh          # protocol-native alternative
│       └── overlay.sh       # tailscale break-glass profile
├── testbench/
│   ├── setup.sh             # Phase 3 — test bench provisioning
│   ├── desktop-control-mcp.js  # Tier-2 MCP server (nested display control)
│   └── vm-bench-mcp.js      # Tier-3 MCP server (QEMU targets)
└── images/
    ├── cloud-init.yaml      # Phase 5 — VPS/mini-PC bootstrap
    └── README.md            # pi-gen recipe notes

tests/
├── appliance-common.bats
├── appliance-engine.bats
├── appliance-doctor.bats
├── appliance-member.bats
├── appliance-sshconfigs.bats
└── appliance-mcp.bats       # protocol tests for both MCP servers

.github/workflows/appliance-tests.yml
```

## Cross-phase conventions

- **Idempotency**: every provisioning entry point can be re-run; existing
  state is detected and skipped, never clobbered. Config files the user may
  have edited are only written if absent (or with `--force`).
- **`--dry-run` everywhere**: all mutating commands route through
  `run_cmd()` in `lib/common.sh`, which echoes instead of executing under
  `--dry-run`. This is also the primary BATS seam.
- **Root model**: `setup.sh` and `member.sh` require root (they install
  packages and create accounts) and refuse to run as a plain user with a
  clear message. Per-user state is written via `runuser -u` so ownership is
  correct without a fakeroot dance — the repo already learned what `0700`
  build-uid artifacts do to Cowork ([cowork-vm-daemon.md](https://github.com/aaddrick/claude-desktop-debian/blob/main/docs/learnings/cowork-vm-daemon.md)).
- **No secrets in the repo or in argv**: tunnel tokens and IdP settings are
  read from files or env, never flags (flags leak via `ps`).

## Test environments

Three tiers, brought up **in this order**. Each tier is a bare-OS →
one-command provisioning test first, and a feature-validation target
second; re-provisioning from scratch (snapshot revert or reimage) is
part of every test pass.

| Tier | Hardware | OS | Engine exercised | Validates |
|---|---|---|---|---|
| 1 | x86 VPS (Hetzner CPX11/CX22, DO droplet; hourly billing) | Ubuntu Server 24.04 | repo build + **bwrap** (no `/dev/kvm` on cheap VPSes) | cloud-init one-shot, zero-touch tunnel from a real datacenter, Access SSO, kasmVNC in iPad Safari over cellular, doctor, member add/remove |
| 2 | Intel N100/N150 mini PC, 32 GB RAM | Ubuntu Server 24.04 | **official apt build + KVM** (only tier with `/dev/kvm`) | official-engine Cowork, multi-member concurrency under slice quotas, vm-bench with a licensed Windows guest; graduates to production |
| 3 | Raspberry Pi 5 16 GB, NVMe/USB3 SSD | Raspberry Pi OS **Lite** (Bookworm, arm64) | repo build arm64 + bwrap | arm64 deb path, XFCE-install-on-bare-Lite, kasmVNC without a hardware encoder, pi-gen recipe |

### Sizing (bwrap engine; budget per *concurrently active* member)

Rule of thumb per active member: Electron ~1–1.5 GB + XFCE/kasmVNC
~1 GB + a Cowork bwrap session ~0.5–1.5 GB ≈ **2.5–3.5 GB RAM and
~1.5 vCPU**, plus ~1 GB for the OS. Idle signed-in members
(close-to-tray) cost a fraction of that. KVM-engine Cowork adds a
guest VM: budget ~4 GB per active member instead.

| Concurrent members | Tier 1 VPS (DO Basic / Hetzner) | Notes |
|---|---|---|
| 1 | 2 vCPU / 4 GB (DO $24; Hetzner CPX21) | comfortable solo |
| 2 | 4 vCPU / 8 GB (DO $48; Hetzner CPX31) | resize up when the second seat becomes real — CPU/RAM resizes are reversible |
| 3–4 | 8 vCPU / 16 GB | consider the Tier 2 mini PC instead at this point |

Always: ≥50 GB disk, a 2 GB swapfile as OOM insurance, and slice
quotas (`member.sh --quota-mem/--quota-cpu`) sized so members
degrade individually instead of taking the box down. Tier 2: 16 GB
minimum, 32 GB recommended once vm-bench Windows guests enter the
picture. Tier 3: the 16 GB Pi 5 for anything beyond a single member.

Deliberately skipped: local VMs on Apple Silicon (no x86 guests,
nested-virt quirks make results unrepresentative — the hourly VPS is
the cheaper, truer lab) and Fedora/other distros until the
Debian-family path is solid.

Per-tier recipe: provision bare OS → run `appliance/setup.sh` (or
feed `appliance/images/cloud-init.yaml`) → `appliance/setup.sh
doctor` to zero FAILs → work the phase's hardware-verify checklist →
destroy and re-provision to prove repeatability.

---

## Phase 1 — single-user headless appliance

**Goal**: one command takes a fresh Debian 12/Ubuntu 24.04 box (x86_64 or
arm64) to a working single-user appliance: engine installed, desktop
session serving over kasmVNC, cloudflared tunnel configured, doctor green.

### Interface

```bash
sudo appliance/setup.sh \
	[--engine auto|official|repo]   # default auto
	[--profile kasmvnc|xrdp|overlay] # default kasmvnc
	[--user NAME]                    # default: invoking sudo user
	[--hostname claude.example.com]  # tunnel public hostname (kasmvnc profile)
	[--dry-run] [--force]

appliance/setup.sh doctor        # alias for the doctor entry point
```

### Behavior

1. **Preflight**: root check, distro/arch check, network reachability.
2. **Engine selection** (`lib/engine.sh`): rule order —
   official apt build if Debian-family and `/dev/kvm` exists and arch is
   amd64/arm64; else repo build (deb via this repo's apt repo) with
   `COWORK_VM_BACKEND=bwrap` exported in the session environment.
   `--engine` overrides. The chosen rule and reason are logged and stored
   in `/etc/claude-appliance/engine.conf` for doctor to report.
3. **Session stack**: XFCE (`xfce4 xfce4-goodies` minimal set), per the
   selected profile:
   - **kasmvnc**: install kasmvncserver deb, configure
     `~/.vnc/kasmvnc.yaml` (localhost bind, TLS off — TLS terminates at the
     tunnel), systemd user service, `cloudflared` install + config skeleton
     at `/etc/cloudflared/config.yml` mapping `--hostname` to the local
     kasmVNC port. Tunnel *authentication* (`cloudflared tunnel login`) is
     interactive and left to the operator; setup prints the exact next
     commands.
   - **xrdp**: install xrdp + xorgxrdp, apply the repo's session-type
     fixes, enable service bound to localhost (tunnel or overlay carries
     it).
   - **overlay**: install tailscale, print `tailscale up` next-steps.
4. **Autostart**: XDG autostart entry launching `claude-desktop` in the
   session, close-to-tray relied on for persistence.
5. **Doctor** (`lib/doctor.sh`): checks per the design doc, mirroring the
   output style of `scripts/doctor.sh` (PASS/WARN/FAIL, distro hints, no
   false-green on unreadable probes).

### Acceptance criteria

- `setup.sh --dry-run` on a clean container prints the full plan and
  touches nothing (asserted by BATS).
- Re-running a completed setup makes zero changes (idempotency asserted
  via `run_cmd` call log in dry-run over a simulated done-state).
- `appliance-doctor` exits non-zero when any FAIL is present; publicly
  bound VNC/RDP ports are a FAIL, not a WARN.
- shellcheck-clean; all functions covered by BATS with stubbed commands.

### Hardware-verify checklist (not CI-testable)

- [ ] Real kasmVNC session reachable through a real cloudflared tunnel
- [ ] Claude Desktop signs in and Cowork starts under the chosen engine
- [ ] xrdp profile renders (GPU-compositing fix path)

---

## Phase 1.5 — zero-touch tunnel (implemented)

**Goal**: bare OS to working, Access-protected URL in one command —
no interactive `cloudflared tunnel login`.

### Interface

```bash
sudo appliance/setup.sh --hostname claude.example.com \
	--cf-api-token-file /root/cf-token \
	--access-allow 'alice@example.com,example.com'
```

The token is a scoped Cloudflare API token (Account > Cloudflare
Tunnel:Edit, Account > Access: Apps and Policies:Edit, Zone >
DNS:Edit), read from a file, never argv. `--access-allow` (emails
and/or email domains) is **required** in this mode: a proxied tunnel
hostname without an Access application is public.

### Behavior (`lib/tunnel-api.sh`)

1. Verify the token; discover the account and the registered zone by
   walking the hostname's labels.
2. Create-or-adopt a remotely-managed tunnel named
   `claude-appliance` (`config_src: cloudflare` — ingress lives in
   Cloudflare's config, not a local YAML).
3. PUT the ingress (hostname → local kasmVNC port, 404 catch-all),
   idempotently.
4. Ensure the proxied CNAME to `<tunnel>.cfargotunnel.com`.
5. Ensure the Access application + allow policy for the hostname.
6. Record the shape in `$APPLIANCE_ETC/tunnel.conf` (`mode=api`,
   tunnel/account/zone ids, token file path, allow list) and install
   the connector via `cloudflared service install <tunnel token>`.

`member.sh` reads `tunnel.conf`: in api mode, member add/remove
updates the remote ingress, the member's CNAME, and a per-member
Access app through the API instead of editing
`/etc/cloudflared/config.yml`. The doctor recognizes api mode and
checks the recorded tunnel id instead of the local YAML.

### Acceptance criteria (all BATS-covered)

- Pure JSON transforms (`ingress_json_add/remove`,
  `access_include_json`) are idempotent and surgical.
- `cf_tunnel_ensure` adopts an existing tunnel without a POST.
- Full provisioning happy path against a stubbed API writes a
  complete `tunnel.conf` and installs the connector with the tunnel
  token.
- api-mode without `--access-allow` or `--hostname` is refused.
- member add in api mode routes to the API, not the local file.

### Hardware-verify checklist

- [ ] Real token → `setup.sh` one-shot → hostname reachable, Access
      login page presented, kasmVNC session behind it (Tier 1 VPS)
- [ ] `member.sh add` in api mode creates working member hostname

---

## Phase 2 — multi-user member management

**Goal**: add/remove team members with real isolation and quotas.

### Interface

```bash
sudo appliance/member.sh add NAME [--quota-mem 6G] [--quota-cpu 200%] \
	[--port auto] [--dry-run]
sudo appliance/member.sh remove NAME [--keep-home] [--dry-run]
appliance/member.sh list
```

### Behavior

- `add`: create Unix account (no sudo), install systemd user-slice
  override (`/etc/systemd/system/user-<uid>.slice.d/50-appliance.conf`
  with `MemoryMax`, `CPUQuota`, `TasksMax`), allocate next free kasmVNC
  port from a registry file (`/etc/claude-appliance/members.tsv`), write
  per-user kasmVNC service + XDG autostart, append a hostname→port entry
  to the cloudflared config ingress (one hostname per member,
  `NAME.claude.example.com`), print the Access-policy reminder (policy
  creation lives in Cloudflare's dashboard/API, out of scope here).
- `remove`: stop services, drop ingress entry, delete slice override,
  optionally archive home.
- `list`: render the registry with port, quota, and doctor state per
  member.
- PAM keyring: ensure `pam_gnome_keyring.so` lines exist for the login
  stack used by the session layer, so `safeStorage` works headlessly.

### Acceptance criteria

- Port allocation is collision-free and stable across add/remove cycles
  (BATS over the registry file).
- `remove` never `rm -rf`s outside the member's home; `--keep-home` is
  honored (BATS with a fake root tree).
- Ingress edits are surgical and idempotent (BATS golden-file diff).

### Hardware-verify checklist

- [ ] Two concurrent members in real kasmVNC sessions, each signed into
      their own Claude account, quotas visible in `systemd-cgtop`
- [ ] Keyring unlock at session start (no safeStorage degradation)

---

## Phase 2.5 — remote-backed storage (implemented)

**Goal**: project data lives in the member's cloud storage, not on
the appliance disk — the macOS pattern (Cowork folders that *are*
Google Drive folders) with a bounded local cache instead of a full
sync, so a small VPS disk serves large accounts.

### Interface

```bash
sudo appliance/storage.sh add --user alice --provider gdrive \
	--name drive [--token-file FILE] [--cache-max 10G]
sudo appliance/storage.sh remove --user alice --name drive
appliance/storage.sh list --user alice
```

Providers: `gdrive`, `onedrive`, `dropbox` (anything else via raw
rclone). OAuth is a one-time paste: the member runs
`rclone authorize "<backend>"` on any machine with a browser and
pastes the token JSON at the wizard prompt (or via `--token-file`).
The token lands in the member's own `~/.config/rclone/rclone.conf`,
passed through env, never argv.

### Behavior

- `rclone mount` per remote as a systemd **user** unit
  (`rclone-<name>.service`), mounted at `~/CloudDrives/<name>` with
  `--vfs-cache-mode full`, `--vfs-cache-max-size` (default 10G),
  24 h cache age, `--umask 077`. Near-local read/write semantics;
  disk usage capped at the cache bound.
- Members point Cowork/Code project folders inside the mount. The
  Cowork daemon's bind of paths under `$HOME` carries the FUSE
  mount into the bwrap sandbox unchanged.
- `remove` detaches the mount and deletes the remote config; the
  provider-side data is untouched.

### Acceptance criteria (BATS, stubbed rclone/systemd)

- Provider mapping validates; unknown providers are refused.
- The unit file wires the bounded cache, umask, and lazy unmount.
- Token intake works from file and interactive paste, and fails
  cleanly with neither.
- Dry-run plans everything and writes nothing.

### Hardware-verify checklist

- [ ] Google Drive mount on the Tier 1 VPS; a Cowork session driving
      a project folder inside it end-to-end (bwrap bind over FUSE)
- [ ] Cache stays under `--cache-max` during a large-repo session
- [ ] OneDrive variant

---

## Phase 3 — test bench (computer-use substitutes)

**Goal**: the MCP toolset from the design doc's
[test bench section](design.md#computer-use-substitutes--the-multi-os-test-bench),
installable per member, usable from Cowork/Code sessions.

### Deliverables

1. **`testbench/setup.sh`**: installs Xvfb, xdotool, imagemagick,
   at-spi2-core, Playwright MCP config snippet; registers both MCP
   servers into the member's `claude_desktop_config.json` (merge, not
   overwrite — jq).
2. **`desktop-control-mcp.js`** (no npm dependencies, CommonJS, stdio
   newline-delimited JSON-RPC per MCP spec):
   - `display_start {width,height}` → boots a dedicated Xvfb display,
     returns `{display}`; refuses to target a display it did not create
     (the member's real `:0`/`:10` session is never controllable)
   - `display_stop`, `screenshot {}` → PNG (base64 image content),
   - `click {x,y,button}`, `type {text}`, `key {keys}` (xdotool),
   - `launch {command,args}` → app on the nested display,
   - `ax_tree {}` → AT-SPI dump when available (graceful degrade).
3. **`vm-bench-mcp.js`** (skeleton, same protocol): `vm_start
   {image,snapshot}`, `vm_screenshot`, `vm_input {events}`, `vm_revert`,
   `vm_stop` over QMP. Ships with an explicit `status: experimental`
   banner in `tools/list` descriptions; QMP wire code unit-tested against
   a mock QMP socket, not a real guest.

### Acceptance criteria

- Both servers complete the MCP handshake (`initialize` →
  `tools/list` → `tools/call`) driven by a scripted stdio client under
  BATS + node.
- `desktop-control` end-to-end **in this repo's CI container**: start
  Xvfb display, launch `xterm` (or `xlogo`), screenshot returns a
  non-empty PNG, click/type produce no protocol errors, stop cleans up
  (no orphan Xvfb — asserted via pgrep).
- Safety: tools refuse to act when the target display is not one the
  server created; `launch` rejects shell metacharacters (argv array
  spawn only, no shell).

### Hardware-verify checklist

- [ ] Playwright MCP + `_electron` against a real member-built app
- [ ] vm-bench against a licensed Windows guest with snapshots
- [ ] AT-SPI tree over a real GTK app

---

## Phase 4 — team distribution

**Goal**: make the appliance appear in every member's own desktop app.

### Deliverables

- **`gen-sshconfigs.sh`**: reads `members.tsv` + appliance hostname,
  emits the managed-settings `sshConfigs` JSON block (and optional
  `sshHostAllowlist`) to stdout; `--merge FILE` merges into an existing
  managed settings file via jq without disturbing other keys.
- **`docs/runbook.md`**: admin runbook — initial
  provision, member add/remove, tunnel/Access setup walkthrough,
  Guacamole gateway option, break-glass overlay procedure, backup
  (what to back up: `/etc/claude-appliance`, member homes, NOT vm
  bundles), restore drill.

### Acceptance criteria

- Generator output is `jq`-valid, matches the upstream `sshConfigs`
  schema (id/name/sshHost required), and is stable/deterministic (BATS
  golden files); `--merge` preserves unrelated keys byte-for-byte.

---

## Phase 5 — images + CI

**Goal**: flash-and-go paths and CI protection for everything above.

### Deliverables

- **`images/cloud-init.yaml`**: user-data that clones the repo at a tag,
  runs `setup.sh --engine auto --profile kasmvnc` non-interactively, and
  drops a first-boot README on the console with the next-step commands
  (tunnel login, sign-in).
- **`images/README.md`**: pi-gen stage recipe for a Pi 5 image (arm64
  deb engine, notes on 16 GB RAM guidance and no-HW-encoder caveat).
- **`.github/workflows/appliance-tests.yml`**: on PR/push touching
  `appliance/**` or `tests/appliance-*`: shellcheck on `appliance/**/
  *.sh`, `node --check` on the MCP servers, full appliance BATS suite,
  plus the Xvfb end-to-end MCP test (ubuntu-latest has xvfb).
- CHANGELOG `[Unreleased]` entries per Keep a Changelog.

### Acceptance criteria

- Workflow is actionlint-clean and passes on this PR.
- cloud-init YAML validates (`cloud-init schema` if available, else
  yamllint-level check in CI).

---

## Spin-out — the `coworkstation` repo (decided, gated on Tier 1)

Once the Tier 1 VPS hardware-verify passes, the appliance layer
moves to a new repository named **coworkstation** under the owner's
account, with fresh history. What carries over: `appliance/`, the
three appliance docs (design, phases, runbook), `tests/appliance-*`
+ `tests/helpers/`, and `appliance-tests.yml`. What does not: the
patch suite, packaging, and launcher — the new repo **consumes
engines instead of forking them** (Anthropic's apt build where KVM
exists; `claude-desktop-debian` releases for the bwrap path).

Bootstrap contract for the new repo: dev = clone + `sudo
./setup.sh` (wizard); prod = a versioned setup script (later a
binary) downloadable from a release URL. This fork then reverts to
tracking upstream `aaddrick/claude-desktop-debian` only.

## Phase 6 — deferred R&D (tracking only)

Native Linux computer use in the app; Sunshine profile tuning; Android
AVF on-device experiments; Mac-node automation for the macOS/iOS test
leg. Each gets an issue when the phase above it ships; none block 1–5.

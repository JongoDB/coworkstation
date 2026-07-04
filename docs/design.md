[< Back to README](../README.md)

# Cowork appliance — design

A headless, internet-connected, team-accessible Claude Desktop server ("the appliance") built by composing upstream-maintained parts, so it inherits every Claude Desktop feature and fix without forking functionality.

- **Base**: one always-on Linux box (x86_64 mini PC or arm64 SBC) running Claude Desktop
- **Engine**: official Anthropic apt build, always, on Debian-family hosts (no KVM just means no Cowork VM feature); the community repo build only by explicit `--engine repo` opt-in, or as the fallback on non-Debian distros
- **Access**: clientless, browser-only — per-user kasmVNC/Guacamole sessions behind Cloudflare Zero Trust (Tunnel + Access); SSH-target mode for Code-tab sessions from members' own desktop apps; Dispatch from phones
- **Trust boundary**: identity-aware edge (Access + IdP SSO/MFA) + per-member Linux accounts and systemd slices + bwrap/KVM Cowork isolation + AppArmor
- **Testing**: a multi-OS test bench (MCP tools over disposable displays and VMs) substitutes for the upstream computer-use gate

## Goals and non-goals

**Goals**

1. Deliver the full Claude Desktop feature surface (Chat, Cowork, Code, connectors, MCP, skills, plugins, Dispatch) to devices that cannot run it natively — iPad, Android tablets, any browser.
2. Track upstream automatically. Every layer updates through its own upstream channel (Anthropic apt repo, distro packages, Tailscale). The appliance layer itself is composition + configuration, not a fork.
3. Support multiple team members with real isolation between them.
4. Borrow this repo's hardening: `--doctor`-style readiness checks, bwrap sandbox configuration, AppArmor userns profiles, keyring detection, XRDP fixes.

**Non-goals**

- Reimplementing any part of the Claude Desktop app. Features gated off by Anthropic (computer use on Linux, dictation) stay gated until upstream ships them; the appliance documents the gap and the closest workaround instead of patching one in.
- iPadOS/Android *native* execution. Apple and Google platform rules make that permanently impossible for an Electron + VM stack; the appliance treats tablets as clients.

## Feature parity matrix

What each feature needs from the appliance, and its status. "Official Linux" is Anthropic's [Linux beta](https://code.claude.com/docs/en/desktop-linux); "repo build" is this project's repackaged Windows app.

| Feature | Official Linux | Repo build | Via appliance remote session | Notes |
|---|---|---|---|---|
| Chat tab | yes | yes | yes | |
| Cowork tab | yes (beta) | yes (KVM/bwrap/host) | yes | Isolation backend choice below |
| Code tab | yes (beta) | yes (patched) | yes | Also reachable via SSH-target mode |
| Parallel sessions, diff review, terminal, editor, app preview | yes | yes | yes | Preview ports are local to the appliance; reachable over Tailscale |
| Remote connectors (Drive, Slack, …) | yes | yes | yes | Account-level; OAuth flows complete in the remote session's browser |
| Local MCP servers | yes | yes | yes | Run on the appliance; per-user `~/.config/Claude/claude_desktop_config.json` |
| Desktop extensions (`.mcpb`) | yes | yes | yes | |
| Skills and plugins | yes | yes | yes | |
| Cloud sessions | yes | yes | yes | Continue even when the appliance session closes |
| SSH sessions (Desktop as client) | yes | yes | yes | The appliance is more useful as the *target*; see below |
| Dispatch (phone → desktop handoff) | yes | yes | yes | Requires the desktop app running and signed in — exactly what the appliance guarantees, per member |
| Quick Entry global hotkey | X11 yes; native Wayland needs GlobalShortcuts portal | same | yes | xrdp sessions are Xorg, so the X11 path applies |
| System tray | yes | yes (repo has extra fixes) | yes | Needs a tray-capable DE/panel in the remote session |
| Computer use (app/screen control) | **no — macOS/Windows research preview only** | no | substitutable | Also Pro/Max-only; **not available on Team/Enterprise plans at all**. The appliance ships a stronger substitute for the app-testing use case — see [the multi-OS test bench](#computer-use-substitutes--the-multi-os-test-bench) |
| Dictation | **no on Linux desktop** | no | practical workaround | Client-side OS dictation (iPad/Android keyboard mic) types into the remote session; CLI voice dictation exists separately |
| Fedora/RHEL packages | no | yes (rpm) | n/a | Repo build is the only option there today |

Two upstream gates worth internalizing before promising "ALL features" to a team:

1. **Computer use cannot be delivered by any Linux appliance today.** It is a research preview on macOS and Windows, requires Pro or Max, and is explicitly excluded from Team and Enterprise plans. A team-accessible server and computer use are currently mutually exclusive at the *plan* level, not just the OS level. The honest design is: track upstream, and meanwhile note that Cowork's priority order (connectors → Bash → browser → screen control) means most computer-use tasks on a server reduce to Bash and connectors anyway.
2. **Dictation** is absent from the Linux app, but the tablet-as-client architecture mostly dissolves this: iPadOS and Android system dictation input works in any remote-desktop client's keyboard path.

## Engine selection

The appliance supports two interchangeable engines behind one provisioning interface:

| | Official apt build | This repo's build |
|---|---|---|
| Update channel | Anthropic's apt repo (`downloads.claude.ai/claude-desktop/apt`) | This repo's apt/dnf repo, AUR, Nix |
| Cowork isolation | Anthropic's VM stack (KVM/QEMU; needs `/dev/kvm`) | `kvm`, `bwrap`, or `host` via `COWORK_VM_BACKEND` |
| Distros | Ubuntu 22.04+/Debian 12+ | deb, rpm, AppImage, Nix, AUR |
| Arch | x86_64, arm64 | x86_64, arm64 |
| Breakage risk | lowest (first-party) | patch suite chases upstream minification |

Selection rule, encoded in the provisioning script:

1. Debian-family → **official build, always** (with or without `/dev/kvm`). Without KVM the Cowork VM feature is unavailable and both setup and the doctor say so plainly; nothing else is affected. `auto` never trades the unmodified first-party binary for a feature.
2. `--engine repo` (explicit opt-in only) → **repo build with `COWORK_VM_BACKEND=bwrap`** on KVM-less hosts. Bubblewrap is the portability play: namespace isolation with zero virtualization requirements, plus the `coworkBwrapMounts` config surface. The repo build patches Anthropic's minified app — a different terms posture the operator must choose knowingly, which is why `auto` won't.
3. Fedora/RHEL/Nix host → **repo build** as the automatic fallback (official is Debian-only today), with a warning.

The doctor check (below) reports which rule fired and why, and records the resulting Cowork backend (`kvm`, `bwrap`, or `none`).

## Access layer

Three complementary paths, not one:

### 1. Remote desktop (full app: Chat + Cowork + Code)

**kasmVNC is the default session layer.** It serves each member's desktop as an ordinary HTTPS web app — the natural fit for the clientless edge below — with per-user instances under each member's Linux account, reached through per-member hostnames behind Cloudflare Access. **Apache Guacamole** is the alternative gateway when a team wants one HTML5 portal multiplexing many session types (VNC/RDP/SSH) with its own connection-level permissions, session recording, and no per-seat cost.

**xrdp stays as the protocol-native option** — for members who prefer a real RDP client, or behind Cloudflare's browser-rendered RDP. Each member RDPs into their own Xorg session; this repo already carries the two fixes that make Claude Desktop behave there:

- the XRDP GPU-compositing blank-window fix (launcher detects the session type and adjusts GPU flags; #davidamacey),
- GPU-crash auto-recovery relaunch with safe flags.

**Sunshine/Moonlight for the latency-sensitive single seat**: best-in-class feel on iPad, but single-session, client install required, and needs a hardware encoder (Intel iGPU/QuickSync; note the Pi 5 has no H.264 encoder, so software encoding costs CPU there). Offered as an opt-in profile, not the team default.

Session shell: a lightweight tray-capable DE (XFCE or LXQt) so the tray, Quick Entry (X11 path), and window management all behave. Claude Desktop autostarts per user via XDG Autostart — the same mechanism the repo already uses for "Run on startup" persistence.

### 2. SSH-target mode (Code tab from members' own devices)

Members who have Claude Desktop on their own Mac/Windows machine don't need remote desktop for coding work: the desktop app's **SSH sessions** run Claude Code on a remote machine over SSH, with connectors, plugins, MCP, and permission modes supported. The appliance provisions itself as that target:

- per-member Unix accounts with SSH keys (Tailscale SSH is the low-friction option),
- an admin-distributable managed-settings snippet (`sshConfigs`) so the appliance appears automatically in every member's environment dropdown, marked as managed,
- optional `sshHostAllowlist` guidance for orgs that want Desktop's SSH constrained to the appliance.

This path costs no display server, no encoder, and no session state — it's the cheapest team feature the appliance offers, and it's pure upstream functionality.

### 3. Dispatch (phones and quick handoffs)

Each member's appliance session is a signed-in, always-on desktop — which is precisely the prerequisite Dispatch needs. Members message Claude from the mobile app; the work executes in their appliance session with their files and connectors; results come back to the same conversation. No appliance-side code needed beyond "keep the app running," which close-to-tray (already a repo feature) provides.

### Networking — clientless by default

The default edge is **Cloudflare Zero Trust**, not a VPN:

- **`cloudflared` Tunnel** from the appliance — outbound-only, zero open
  inbound ports, fronted by Cloudflare's CDN/WAF/DDoS layer.
- **Cloudflare Access** in front of every hostname — SSO via the team's
  IdP (Google Workspace, Entra, GitHub, generic OIDC), MFA, per-user and
  per-group policies, full access audit logs. This is where edge-level
  RBAC lives: which member may reach which session hostname is an Access
  policy, enforced before a packet reaches the appliance.
- **Clientless sessions in the browser**: Cloudflare renders
  [RDP, VNC, and SSH in-browser](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/non-http/browser-rendering/)
  behind Access, and kasmVNC/Guacamole sessions are ordinary HTTPS web
  apps that need no rendering help at all. Any device with a browser —
  iPad Safari, Android, a locked-down loaner laptop — is a full client
  with nothing installed.

Trade-offs, stated plainly:

- Every session round-trips through Cloudflare's nearest PoP. For
  productivity work this is imperceptible; it is not game-stream
  latency. The Sunshine/Moonlight profile remains the opt-in answer for
  a latency-critical single seat.
- The appliance trusts Cloudflare as an identity-aware proxy. Teams
  that can't accept that get the **overlay profile** (Tailscale/
  headscale) as a supported alternative — same appliance, different
  edge — and it doubles as the break-glass path if the tunnel or IdP is
  down.
- Raw xrdp/VNC ports are never bound to public interfaces under either
  profile; `appliance-doctor` fails loudly if it finds one.

## Computer-use substitutes — the multi-OS test bench

Upstream computer use points Claude at *your live desktop*. For the appliance's headline use case — members having Claude test the desktop apps they're building, across OSes — that's the wrong shape anyway: test targets should be disposable, snapshotable, and isolated from the member's real session. The appliance therefore ships GUI control as a set of MCP tools available inside every Cowork/Code session, layered from most deterministic to most general:

**Tier 1 — deterministic drivers (prefer these).** For web apps, the Playwright MCP server. For Electron apps, Playwright's `_electron.launch()` — the exact harness this repo already uses for its own integration tests ([testing/automation.md](testing/automation.md)); Tauri apps via their WebDriver. Deterministic drivers beat screenshot-clicking on speed, cost, and flake rate, mirroring upstream Cowork's own priority order (connectors → Bash → browser → screen control).

**Tier 2 — Linux GUI control.** For native GTK/Qt apps or whole-desktop flows: a nested, disposable display per test (Xvfb, Xephyr, or headless wlroots — never the member's own session), driven two ways:

- **accessibility-tree-first**: AT-SPI2 (dogtail-style queries) for locating and activating controls — the same philosophy as this repo's AX-tree test walker, and far more robust than pixel matching;
- **screenshot + input fallback**: `xdotool`/`ydotool` plus screen capture, exposed as an MCP tool. Anthropic's own computer-use **API** reference environment (the `computer-use-demo` container: Ubuntu + Xvfb + noVNC) runs on Linux unmodified — the *model capability* is fully available here even though the Desktop-app feature is gated; only the packaging differs.

**Tier 3 — cross-OS targets.** The appliance's KVM stack does double duty as a test-target hypervisor:

- **Windows**: a Windows VM (licensed) with snapshot-per-test; input via QEMU QMP `input-send-event` or FreeRDP automation, screenshots via QMP; or WinAppDriver inside the guest for deterministic driving. Claude orchestrates via a `vm-bench` MCP server (boot-from-snapshot, screenshot, input, collect-artifacts, restore).
- **Android**: emulator + `adb`/`maestro` on the appliance directly.
- **macOS and iOS**: **only legal on Apple hardware** — macOS VMs on non-Apple machines violate Apple's license, so the appliance never offers them. The supported pattern is a Mac node (Mac mini on the same network, or MacStadium/EC2 Mac) joined as an SSH-session target and runner; iOS simulators come with it.

Result: for app-testing, the appliance is *stronger* than upstream computer use — disposable, snapshot-restorable, multi-OS targets with audit artifacts — while the "control my real desktop" remainder stays tracked as an upstream gap.

## Client architecture — browser-first, control plane server-side

**No custom native client.** The browser is the thin client; that's what the clientless edge buys. A native app would reintroduce exactly what the appliance exists to escape: per-platform builds (iPadOS, Android, three desktops), app-store review latency, and a second codebase chasing upstream. Members who want an "app" get a **PWA install** of the session page — icon, full-screen, nothing to maintain.

The concerns behind the question are real but they are **control-plane** concerns, and they live server-side:

| Concern | Where it lives |
|---|---|
| Identity / RBAC | Team IdP → Cloudflare Access policies (edge), mapped to Guacamole/Kasm roles and Unix accounts (session) |
| Per-user isolation | Linux accounts + per-user Cowork sandboxes (v1) → per-member incus containers/VMs (v2) for hard multi-tenancy |
| Resource sharing / quotas | systemd user slices (`MemoryMax`, `CPUQuota`, `TasksMax` per member) — declarative, no daemon to build |
| Concurrency limits | session broker: Guacamole connection limits or Kasm's built-in per-user/per-group session caps |
| Audit | Access logs (edge) + session recording (Guacamole/Kasm) + Cowork/Code session history (upstream) |

**Buy before build**: [Kasm Workspaces](https://kasmweb.com) is effectively this entire control plane off the shelf — per-user containerized desktops, web-native streaming, RBAC, session caps, resource profiles (Community Edition is capped at 5 concurrent sessions; paid beyond). The trade-off is that Claude Desktop inside Kasm's Docker containers complicates Cowork isolation (bwrap-in-Docker needs userns configuration; KVM needs `/dev/kvm` passthrough), whereas plain Linux accounts + slices keep Cowork's backends exactly as this repo already exercises them. So: **v1 composes accounts + slices + kasmVNC/Guacamole + Access**; Kasm is the documented alternative for teams that want a vendor-shaped control plane and accept the container nesting work.

The only custom UI the appliance ever grows is a small **web console** (Phase 3+): member management, session launch links, `appliance-doctor` status, test-bench VM inventory. A web page behind Access — not an installed client.

## Multi-tenancy and security model

**One Linux account per member. No shared sign-ins.**

- Each member signs into their own Claude account (Team plan) inside their own session. Config, MCP servers, connector OAuth grants, and Cowork state live under their own `~/.config/Claude/`.
- **Keyring**: Electron `safeStorage` needs a functioning secret service or session persistence silently degrades. xrdp's PAM integration unlocks gnome-keyring at login; the launcher's `--password-store` D-Bus probing (#611) papers over the rest. The doctor check verifies a non-empty password store per user — the repo already learned that an *empty* store reads as falsely healthy (#692).
- **Cowork isolation is per user**: the daemon socket lives in each user's `$XDG_RUNTIME_DIR`, sandboxes/VMs are per-session. bwrap's read-write binds are constrained to the owning user's `$HOME` by the existing mount-config validation, which composes correctly with the one-account-per-member model.
- **AppArmor**: reuse the repo's scoped userns profiles (Electron binary + `/usr/bin/bwrap`) on Ubuntu 24.04+, so `apparmor_restrict_unprivileged_userns=1` neither breaks launch nor silently downgrades Cowork to host-direct (#687, #694).
- **Backend vs tenancy trade-off**: KVM gives the strongest inter-tenant isolation but costs VM-sized RAM per concurrent user; bwrap is namespace-level but light enough for several concurrent members on modest hardware. Sizing guidance: ~4 GB per active Cowork user on KVM, ~1–2 GB on bwrap, plus the Electron sessions themselves. A 32 GB N100/N305 box comfortably serves a small team; a 16 GB Pi 5 serves one or two.

## Update strategy

| Layer | Channel | Mechanism |
|---|---|---|
| Claude Desktop (official) | Anthropic apt repo | `unattended-upgrades` |
| Claude Desktop (repo build) | this repo's apt/dnf repo | `unattended-upgrades` |
| OS, xrdp, DE, bwrap, qemu | distro | `unattended-upgrades` |
| Tailscale | tailscale apt repo | `unattended-upgrades` |
| Appliance layer | this repo | it's config + scripts; updated like any package |

The repo's in-place upgrade detection (watching `app.asar` replacement and offering click-to-restart, #564) matters more on an appliance than anywhere else — sessions are long-lived by design, so a v(N) main process serving v(N+1) renderer assets is the steady state without it.

## Readiness check

`appliance-doctor` extends the `claude-desktop --doctor` philosophy to the appliance surface. Checks, grouped:

- **Engine**: which engine/backend rule fired; `/dev/kvm` + vsock + qemu + virtiofsd, or bwrap functional test; AppArmor userns status
- **Display**: xrdp service health, per-user session capability, GPU/encoder availability, session DE tray support
- **Identity**: per-user keyring/password-store non-empty check, signed-in state
- **Network**: `cloudflared` tunnel health, Access policy presence per session hostname, no publicly bound xrdp/VNC ports (fail loudly if found); overlay-profile equivalent checks (tailnet reachability, ACL tag) when that profile is active
- **Update**: unattended-upgrades enabled for every channel in the table above

Same conventions as the existing doctor: symptom-keyed output, distro-specific install hints, and no false-green PASSes on empty/unreadable probes (#692).

## Known upstream gaps to track

| Gap | Upstream state | Appliance stance |
|---|---|---|
| Computer use on Linux | macOS/Windows research preview; Pro/Max only, excluded from Team/Enterprise | Do not patch the app. Ship the [multi-OS test bench](#computer-use-substitutes--the-multi-os-test-bench) MCP tools instead, which cover the app-testing use case better; revisit the native feature when Linux ships and/or Team plans gain access |
| Dictation on Linux | absent | Client-side OS dictation via remote session; CLI voice dictation |
| Quick Entry on native Wayland | blocked on Electron app-id handshake ([electron#51875](https://github.com/electron/electron/issues/51875)) | Appliance sessions are Xorg (xrdp), so unaffected in practice |
| Fedora/RHEL official packages | "coming in the future" | Repo build covers it |
| Official build isolation fallback | KVM-only (no bwrap equivalent) | Repo build with `COWORK_VM_BACKEND=bwrap` where KVM is unavailable |

## Implementation phases

1. **Single-user headless appliance** — `./setup.sh` (bash-styleguide-conformant): engine selection + install, XFCE session, kasmVNC, `cloudflared` tunnel + Access application, XDG autostart, `appliance-doctor`. xrdp and the Tailscale overlay as alternative profiles. Target: Debian 12/Ubuntu 24.04, x86_64 + arm64.
2. **Multi-user** — member add/remove flow (account, keyring PAM, systemd slice quotas, per-user kasmVNC instance, Access policy entry), sizing docs.
3. **Test bench** — Tier 1/2 MCP tools (Playwright, `_electron`, AT-SPI + nested-display screenshot/input), then the `vm-bench` MCP server for Windows/Android targets; web console v0 (session links + doctor status).
4. **Team distribution** — managed-settings `sshConfigs` generator for SSH-target mode; Guacamole gateway option; admin runbook.
5. **Images** — pi-gen image for Pi 5, cloud-init for VPS/mini-PC, CI smoke tests reusing the repo's BATS + headless-launch harness patterns.
6. **R&D (explicitly deferred)** — native Linux computer use in the app, Sunshine profile tuning, Android AVF on-device experiments (repo build + bwrap; no nested KVM inside AVF), Mac-node automation for the macOS/iOS test leg.

## Positioning & risk

The product bet, stated so it can be falsified.

**What this is.** Personal infrastructure: one developer's persistent,
local-compute Claude Desktop, reachable from a tablet. The jobs the web
app cannot do — Code-tab work on a real filesystem, user-supplied MCP
servers, sessions that outlive the client device — are the whole value.
Chat alone is better served by claude.ai in a browser; do not pitch this
as a chat mirror.

**Lead with SSH-target mode.** For Code-tab work, the box appearing in
the member's own desktop app (`gen-sshconfigs.sh`) beats a VNC desktop
on latency, battery, and fidelity. The browser desktop is the fallback
for GUI-only needs (Cowork, the app itself), not the headline.

**Multi-user is advanced, not core.** Per-member accounts are built
correctly (own Linux account, own Claude sign-in, own Access gate), but
a datacenter box fanning a team into Claude is the most terms-exposed
and least-differentiated configuration — generic VDI (Kasm, Guacamole)
does multi-user better, and Anthropic's anti-abuse systems see a shared
datacenter IP. Keep `member.sh` working; never make it the pitch.

**Engine posture is a legal posture.** The official build is the
default because it is Anthropic's unmodified binary. The repo build
(patched app, bwrap Cowork) is an operator's explicit choice. If
Anthropic ships first-party bwrap-or-equivalent Cowork for KVM-less
hosts, delete the repo engine the same week.

**The existential risk is Anthropic closing the gap.** The day Cowork
(or an equivalent agentic session) ships on web/mobile, the remote
desktop loses its reason to exist. The durable niche is the
local-compute one: your filesystem, your MCP servers, your hardware.
Watch for: web Cowork, mobile Code tab, first-party Linux computer use.
Any of these should trigger a scope rethink, not a feature race.

**Watch the account-standing canary.** Datacenter-IP sign-ins,
long-lived headless sessions, and multiple accounts per host are
anti-abuse signals. If sign-in friction or session drops start
appearing on a deployment, treat it as policy feedback — do not engineer
around it.

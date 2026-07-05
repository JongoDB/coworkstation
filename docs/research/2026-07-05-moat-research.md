# Moat research — 2026-07-05

Deep-research run on competition, session tech, Anthropic trajectory,
and moat extensions: 104 agents, 22 sources fetched, 108 claims
extracted, 25 adversarially verified (3-vote refutation panels),
21 confirmed, 4 killed, 8 surviving findings after synthesis.
Decisions derived from this report live in
[`decisions.md`](../decisions.md).

## Question

> Coworkstation (github.com/jongodb/coworkstation) turns a Linux box (VPS or mini-PC) into a personal, browser-reachable Claude Desktop workstation: official Anthropic engine, per-user kasmVNC session behind a Cloudflare Zero Trust tunnel + Access (zero inbound ports), SSH-target mode for the Code tab, per-member Linux isolation with systemd slice quotas, rclone-backed cloud-drive mounts with bounded cache, and a `doctor` that fails on any exposure (public binds, ungated tunnel hostnames). Value prop: persistent local-compute Claude — 24/7 local MCP servers, real-filesystem Code work, sessions that survive disconnects/reboots, Cowork VM on own hardware — reachable from a tablet. Research four questions and deliver prioritized, implementable recommendations with sources: (1) COMPETITION: how do Kasm Workspaces, Apache Guacamole, Coder/code-server, DevPod/Gitpod/Devcontainers, Sunshine/Moonlight, Selkies-GStreamer, cloud VDI (AWS WorkSpaces, Windows 365), and Tailscale-based setups serve the specific job "persistent AI desktop workstation reachable from a tablet" — what do they do better that we should adopt, and what gaps do they leave that we should press? (2) SESSION TECH: is kasmVNC still the best web-native session layer in 2026 for this use (latency, mobile touch UX, clipboard/file transfer, WebRTC options like Selkies), and what would a migration or hybrid look like? (3) ANTHROPIC TRAJECTORY: current state of Claude Desktop Linux, web/mobile Cowork, Claude Code cloud sessions, remote MCP/hosted connectors — which parts of Coworkstation's value are at risk of being absorbed upstream vs durable (own hardware, own MCP, own filesystem, privacy)? (4) MOAT EXTENSIONS: concrete features self-hosters expect that we lack — encrypted backup/restore, fleet management of multiple boxes, observability/alerting (session health, token spend), GPU passthrough for local models, wake-on-LAN/idle-shutdown cost savings on VPSes, mobile-PWA touch frontend, per-app Access policies, audit logging — which are highest-leverage for a solo maintainer to build next? Prioritize the final recommendations by (impact on differentiation) / (effort for one maintainer), and flag anything that changes our terms-of-service risk posture.

## Synthesis

Coworkstation's original premise ("get official Claude Desktop running on Linux") was absorbed upstream on June 30, 2026 when Anthropic shipped an official Linux beta with Chat, Cowork, and Code tabs — the durable value now lies in the remote-access, multi-tenant, and zero-trust orchestration layer, not the repackaging. Prioritized recommendations (impact/effort for a solo maintainer): (1) rebase onto the official apt-distributed app and reposition as "the secure remote workstation layer" — this also materially improves ToS risk posture by eliminating binary repackaging and minified-JS patching; (2) build a mobile-PWA touch frontend and an Access-compatible clipboard bridge, since kasmVNC's Chromium-only seamless clipboard and Safari direct-connect limits are the biggest tablet (iPad/WebKit) pain points, and competitor 247 proves PWA polish is table stakes; (3) do NOT migrate to Selkies yet — the ecosystem is clearly moving there (LinuxServer.io declared X11/VNC "on life support" and rebased Webtop from KasmVNC to Selkies), but the current implementation is explicitly LAN-optimized and worse over the high-latency WAN paths a Cloudflare tunnel implies, and upstream Selkies has maintainer-continuity risk; instead enable kasmVNC's existing WebRTC UDP transit and prototype a Selkies flavor behind a flag; (4) press the security moat competitors leave open — docker-webtop ships only optional basic auth and warns against internet exposure, so per-app Access policies, audit logging, and the doctor's exposure checks are genuine differentiation. Remote MCP connectors now reach every Claude surface including mobile on all plan tiers, so "MCP from a tablet" alone is no longer a moat — but whether local stdio/own-filesystem MCP remains desktop-bound could not be verified (claims both ways were refuted), so the privacy/own-hardware framing should be validated before being marketed.

## Confirmed findings

### F0 — ANTHROPIC TRAJECTORY

**Confidence:** high · **verifier vote:** 3-0

ANTHROPIC TRAJECTORY — absorbed: Anthropic now officially ships Claude Desktop for Linux (beta, launched ~June 30, 2026) with the full Chat, Cowork, and Claude Code tabs, distributed via a signed official apt repository for Ubuntu 22.04+/Debian 12+ (x86_64/arm64). The core 'official Anthropic engine on a Linux box' premise no longer requires community repackaging on supported distros. Coworkstation should rebase onto the official package and reposition its value as remote access, per-user isolation, and zero-trust exposure — which also reduces ToS exposure from repackaging and patching minified upstream code.

**Evidence:** Official Anthropic docs: "Linux support for the Claude desktop app is in beta. The Chat, Cowork, and Code tabs are all available... the same Chat, Cowork, and Claude Code experience as macOS and Windows: parallel sessions, visual diff review, an integrated terminal and editor, and live app preview." Verifier confirmed signed apt repo (downloads.claude.ai/claude-desktop/apt/stable) and June 30, 2026 launch via multiple outlets. Qualifications: Debian-family only (no Fedora/RHEL), no Computer Use, Wayland Quick Entry caveat, requires claude.ai subscription sign-in.

**Sources:**
- <https://code.claude.com/docs/en/desktop-linux>

### F1 — ANTHROPIC TRAJECTORY

**Confidence:** high · **verifier vote:** 3-0 (availability); moat-boundary claims refuted 0-3 both directions

ANTHROPIC TRAJECTORY — partially absorbed: custom connectors via remote MCP are available across Claude web, Cowork, Claude Desktop, and mobile on all plan tiers including Free (Free limited to one connector). Cloud-reachable MCP tooling from a tablet no longer requires a self-hosted desktop. However, the boundary of the durable moat is uncertain: claims that remote connectors require publicly exposed servers AND the opposite claim that local stdio MCP remains desktop-only were both refuted in verification, so 'own MCP against the real filesystem' as un-absorbed value needs direct empirical validation before being marketed as the moat.

**Evidence:** Anthropic support docs verbatim: "Custom connectors using remote MCP are available on Claude, Cowork, and Claude Desktop for users on Free, Pro, Max, Team, and Enterprise plans" and "Free users are limited to one custom connector." Mobile usage corroborated (connectors added on web sync to iOS/Android; mobile configuration in beta). The two refuted claims about MCP locality mean neither 'tunneled self-hosted MCP cannot be a connector' nor 'stdio MCP is desktop-only' survived adversarial verification.

**Sources:**
- <https://support.claude.com/en/articles/11175166-get-started-with-custom-connectors-using-remote-mcp>

### F2 — COMPETITION

**Confidence:** high · **verifier vote:** 3-0 (x3 merged claims)

COMPETITION — 247 (QuivrHQ/247-claude-code-remote) is the closest adjacent competitor: remote access to Claude Code terminal sessions (not a full desktop) via an xterm.js web terminal, Cloudflare Tunnel with zero inbound ports (same posture as Coworkstation), tmux-backed persistence across client disconnects, and a genuinely shipped mobile-first PWA (manifest, service worker, touch scroll, virtual keyboard). Adopt: its PWA/touch polish validates the mobile-frontend gap as the highest-signal moat extension. Press: 247 is terminal-only (no desktop/Cowork/GUI MCP), its persistence dies on host reboot (tmux, not a desktop session), and its web frontend is Vercel-hosted rather than fully self-hosted — Coworkstation wins on full desktop, reboot-surviving sessions, and complete self-hosting.

**Evidence:** Merged claims [0][1][2]. README verbatim: "Cloudflare Tunnel integration, no port forwarding needed"; "Leave and come back - your sessions stay alive via tmux"; "Fully responsive web terminal with touch scroll support"; "PWA ready: Install as an app on your phone." Verifiers confirmed real PWA artifacts in code (Next.js manifest.ts with standalone display + maskable icons, Serwist/Workbox service worker), active maintenance (v2.44.2, Jan 31 2026, 127 releases), and the Vercel-hosted-frontend caveat.

**Sources:**
- <https://github.com/QuivrHQ/247-claude-code-remote>
- <https://raw.githubusercontent.com/QuivrHQ/247-claude-code-remote/main/README.md>

### F3 — SESSION TECH

**Confidence:** high · **verifier vote:** 3-0 (x3 merged claims)

SESSION TECH — ecosystem shift away from kasmVNC: LinuxServer.io, the largest downstream packager of KasmVNC-based web desktops, rebased its entire Webtop catalog from KasmVNC to Selkies-based base images (June 17, 2025, docker-baseimage-selkies; no new builds on the legacy stack) and by April 2026 publicly declared "our X11 stack is on life support." Selkies is positioned as a ground-up web-native replacement for legacy VNC/RFB stacks. kasmVNC itself remains actively maintained by Kasm Technologies, but the VNC-derived family is losing its most influential open-source packager — Coworkstation should treat kasmVNC as a 12-24 month horizon, not a permanent foundation.

**Evidence:** Merged claims [3][6][9]. docker-webtop README: "This container is based on Docker Baseimage Selkies"; changelog shows 23.03.23 KasmVNC rebase then 17.06.25 Selkies rebase. Blog (Apr 28, 2026): "I can confidently say now that our X11 stack is on life support. It offers no stability or feature benefits over the Wayland stack" and "Selkies is a ground-up, web-native, remote desktop protocol meant to replace legacy VNC stacks." Verifiers confirmed the transition is completed, not merely announced, and noted kasmVNC remains actively developed (the 'losing ecosystem support' framing is a signal, not an obituary).

**Sources:**
- <https://github.com/linuxserver/docker-webtop>
- <https://www.linuxserver.io/blog/webtop-4-1-x11-is-dead-and-what-is-selkies-anyway>
- <https://www.linuxserver.io/blog/spring-cleaning-new-images-and-rebasing>
- <https://info.linuxserver.io/issues/2025-06-18-webtop/>

### F4 — SESSION TECH

**Confidence:** high · **verifier vote:** 3-0 on five claims; 2-1 on the X11-only clause (verifier high)

SESSION TECH — Selkies technical profile (two distinct variants): upstream selkies-project is a WebRTC/GStreamer HTML5 platform, X11-only (native Wayland capture planned but unimplemented), self-claiming Moonlight/Stadia-class "at least 60 fps at Full HD." LinuxServer's baseimage-selkies fork is architecturally different: Wayland-default (Rust/Smithay compositor) with WebSocket pixel delivery (not constant WebRTC video), zero-copy GPU encoding (GBM/DMABUF buffers passed directly to NVENC/VAAPI without touching system RAM), a paint-over technique (low-CRF keyframe + high-quality delta burst when motion stops), automatic X11 fallback on CPUs lacking AVX2, GPU support via /dev/dri (Intel/AMD) and Nvidia proprietary drivers 580+ with nvidia-drm.modeset=1, and a vendor-claimed 60fps on low-end CPUs without GPU. All performance figures are unbenchmarked vendor claims.

**Evidence:** Merged claims [4][7][8][10][12][13][14]. Upstream README: "WebRTC HTML5 remote desktop streaming platform... Moonlight, Google Stadia, or GeForce NOW in noVNC form factor for Linux X11... at least 60 frames per second on Full HD"; official docs confirm Wayland capture "planned, but not yet fully implemented" (issue #46 open). LinuxServer blog: "We use WebSockets in a custom stack... [WebRTC] is not the case"; "Frames remain on GPU via GBM buffers, passed directly to hardware encoders (NVENC/VAAPI) without touching system RAM"; "true 60fps... achievable even on low-end x86 or ARM CPUs without requiring specialized GPU hardware." docker-webtop README confirms AVX2 gate with automatic X11 fallback and Nvidia 580+/modeset requirements; FullColor 4:4:4 zero-copy is Nvidia-only.

**Sources:**
- <https://github.com/selkies-project/selkies>
- <https://github.com/linuxserver/docker-webtop>
- <https://www.linuxserver.io/blog/webtop-4-1-x11-is-dead-and-what-is-selkies-anyway>
- <https://www.linuxserver.io/blog/spring-cleaning-new-images-and-rebasing>
- <https://selkies-project.github.io/selkies/faq/>

### F5 — SESSION TECH

**Confidence:** high · **verifier vote:** 3-0 (x2 merged claims)

SESSION TECH — migration verdict: do not migrate to Selkies now; adopt a hybrid/watch posture. LinuxServer's own disclosure says the initial Selkies implementation "is optimized for low-latency LAN environments" and may perform perceptibly worse than older JPEG-based solutions on high-latency WAN — the exact network profile of a Cloudflare-Zero-Trust-tunneled Coworkstation box — with WAN congestion-control work still on the roadmap as of late 2025. Upstream Selkies simultaneously carries maintainer-continuity risk (README solicits maintainers; head maintainer on hiatus since Aug 2024, last release v1.6.2 Aug 2024). Recommended concrete steps: stay on kasmVNC, ship an optional Selkies-flavored session behind a flag for GPU/LAN users, and gate any default switch on demonstrated WAN improvements.

**Evidence:** Merged claims [11][15]. Vendor admission against interest: "Our initial implementation is optimized for low-latency LAN environments... performance for users on high-latency or very low-bandwidth WAN connections may be perceptibly different compared to older solutions." Verifier confirmed no WAN fixes announced through the Nov 2025 SealSkin post and that congestion-control reimplementation remains WIP. Selkies README as of 2026-07-05: "We are in need of maintainers and community contributors. Please consider stepping up."

**Sources:**
- <https://www.linuxserver.io/blog/spring-cleaning-new-images-and-rebasing>
- <https://github.com/selkies-project/selkies>
- <https://docs.linuxserver.io/images/docker-baseimage-selkies/>
- <https://www.linuxserver.io/blog/webtop-3-0-part-3-putting-it-all-together-with-sealskin>

### F6 — SESSION TECH

**Confidence:** high · **verifier vote:** 3-0 (x3 merged claims)

SESSION TECH — kasmVNC remains serviceable with two exploitable strengths and one tablet-critical weakness: (a) a WebRTC UDP transit mode already exists in the web client for high-latency connections (shipped in 1.0.0, regressed in 1.2.0, fixed in 1.3.0) — enable/expose it before considering any migration; (b) mobile input affordances ship out of the box (modifier-keys panel, virtual keyboard toggle); but (c) seamless clipboard works only on Chromium browsers — Firefox needs a manual clipboard textbox, and Safari is unsupported for direct connections (websocket Basic Auth) — which on iPad (where every browser is WebKit) means no seamless clipboard path at all. Coworkstation's Cloudflare Access fronting already supplies the "alternative authentication" that makes Safari connections work, so a clipboard bridge in a PWA wrapper is the remaining gap to close.

**Evidence:** Merged claims [16][17][18]. Official docs verbatim: "KasmVNC supports UDP transit via WebRTC for better performance over high latency"; "Firefox and non-Chromium based browsers do not support seamless clipboard transfer... users must use the clipboard control panel"; "Safari is not supported when connecting directly to KasmVNC, due to the lack of Safari's support for Basic Auth on web socket connections" — with the explicit exception when "alternative authentication is integrated." Keys panel ("Control, Alt, Esc, and the Windows key... for users on mobile devices without a full keyboard") and virtual keyboard button confirmed; verifiers noted open mobile-input bugs (#236 Alt key, #222 Android Chrome tracking), consistent with 'partial' touch UX.

**Sources:**
- <https://kasmweb.com/kasmvnc/docs/master/clientside.html>
- <https://kasmweb.com/kasmvnc/docs/latest/release_notes/1.3.0.html>

### F7 — COMPETITION/MOAT

**Confidence:** high · **verifier vote:** 3-0

COMPETITION/MOAT — zero-trust security is a durable differentiator competitors explicitly punt on: docker-webtop (the dominant self-hosted web-desktop image) ships only optional HTTP Basic auth, gives the GUI terminal passwordless sudo, and warns "Do not expose it to the Internet unless you have secured it properly," delegating internet-facing security to an external reverse proxy the user must assemble. Coworkstation's integrated Access-gated tunnel + doctor-fails-on-exposure is exactly the packaged solution this ecosystem leaves as an exercise. Highest-leverage extensions of this moat: per-app/per-member Access policies, audit logging of session and tunnel events, and marketing the doctor as a compliance surface.

**Evidence:** Claim [5]. README verbatim: "This container provides privileged access to the host system. Do not expose it to the Internet unless you have secured it properly"; auth via CUSTOM_USER/PASSWORD is "suitable only for securing the container on a trusted local network" with "no auth... when unset"; internet exposure is delegated to "a reverse proxy, such as SWAG, with a robust authentication mechanism." No built-in OIDC/SSO/zero-trust mechanism documented.

**Sources:**
- <https://github.com/linuxserver/docker-webtop>

## Coverage gaps — what the research did NOT reach

The verify pass was strict: only claims about 247, LinuxServer/Selkies,
kasmVNC, docker-webtop, and Anthropic survived. Everything below was in
the original question but produced no surviving evidence. Treat these as
UNRESEARCHED, not unimportant — they are the input to the follow-up run.

### Competitors not covered

| Competitor | Job it serves | Status |
|---|---|---|
| Kasm Workspaces (kasmVNC's commercial parent) | multi-user web desktop fleet | no surviving claims |
| Apache Guacamole | clientless RDP/VNC/SSH gateway | no surviving claims |
| Coder / code-server | browser IDE on own hardware | no surviving claims |
| DevPod / Gitpod / Devcontainers | reproducible dev environments | no surviving claims |
| Sunshine / Moonlight | low-latency game-stream desktop | no surviving claims |
| Cloud VDI (AWS WorkSpaces, Windows 365) | managed persistent desktop | no surviving claims |
| Tailscale-based setups (+ RDP/VNC/ssh) | zero-config private network | no surviving claims |

### Moat-extension feature list (from the original question)

| Feature | Users expect it because | Research status |
|---|---|---|
| Mobile-PWA touch frontend | 247 ships one; tablets are the primary client | RESEARCHED — highest-signal gap (F2, F6) |
| Per-app / per-member Access policies | zero-trust is our differentiator (F7) | RESEARCHED — press this |
| Audit logging (session + tunnel events) | compliance surface for teams (F7) | RESEARCHED — press this |
| Encrypted backup/restore | self-hosters expect disaster recovery | NOT COVERED |
| Fleet management (multiple boxes) | teams accrete boxes | NOT COVERED |
| Observability/alerting (session health, token spend) | 24/7 agents burn quota silently | NOT COVERED |
| GPU passthrough for local models | own-hardware story extends to inference | NOT COVERED |
| Wake-on-LAN / idle-shutdown | VPS cost savings for personal boxes | NOT COVERED |

## Refuted claims (killed in adversarial verification)

These claims FAILED verification. Do not build on them — but note
that a refuted claim is not proof of its opposite; two below were
opposite claims about the same question, and both died.

- **0-3** — As of November 2023, touch input in Selkies was functionally limited to emulating a single mouse click — multi-touch gestures were not supported, which bears directly on whether Selkies beats kasmVNC for tablet/mobile touch UX.
  - source under test: <https://github.com/selkies-project/selkies/issues/112>
- **0-3** — Advanced input support — stylus (Wacom), multi-touch gestures, and pressure sensitivity — was filed as an unimplemented enhancement request in Selkies, not an existing capability.
  - source under test: <https://github.com/selkies-project/selkies/issues/112>
- **0-3** — Remote MCP connectors are dialed from Anthropic's cloud infrastructure, not the user's device, so the MCP server must be publicly internet-accessible — a self-hosted server behind a zero-inbound-port setup (like Coworkstation's Cloudflare-tunneled box) cannot serve as a remote connector without opening public exposure.
  - source under test: <https://support.claude.com/en/articles/11175166-get-started-with-custom-connectors-using-remote-mcp>
- **0-3** — Local stdio MCP servers configured in claude_desktop_config.json remain a Claude Desktop-only capability and do not work in Cowork or claude.ai — leaving 'private local MCP against the real filesystem' as durable, un-absorbed value for a persistent hosted-desktop product.
  - source under test: <https://support.claude.com/en/articles/11175166-get-started-with-custom-connectors-using-remote-mcp>

## Caveats (verbatim from the synthesis)

Time-sensitivity is acute: the official Claude Desktop Linux beta was 5 days old at research time (2026-07-05), is Debian-family-only, and its terms around multi-user/VNC-exposed operation were not examined — the ToS-risk improvement from dropping repackaging is directional, not confirmed. All Selkies and LinuxServer performance figures (60fps, zero-copy latency) are vendor self-claims with no independent benchmarks, and no head-to-head kasmVNC-vs-Selkies WAN/tunnel latency measurement exists in the evidence. Four claims were refuted in adversarial verification, and two of them cut in opposite directions on the same question (whether self-hosted/local MCP remains outside Anthropic's cloud reach), so the 'own filesystem, own MCP' moat framing rests on unverified ground — the two refuted Selkies touch-input claims likewise mean Selkies' actual multi-touch/tablet capability is unknown, not known-bad. Coverage gaps: the original research question named Kasm Workspaces, Guacamole, Coder/code-server, DevPod/Gitpod, Sunshine/Moonlight, cloud VDI, and Tailscale setups, plus most moat-extension features (backup, fleet management, observability, GPU passthrough for local models, wake-on-LAN) — no surviving claims address these, so the competitive picture and the moat-extension priority list here are built only from the 247/LinuxServer/Selkies/kasmVNC/Anthropic evidence that survived.

## Open questions

- Does the official Claude Desktop Linux beta's license/ToS permit multi-user, remotely-exposed (VNC/tunnel) operation, and does its claude.ai SSO login flow actually complete inside a kasmVNC session behind Cloudflare Access?
- Can a self-hosted MCP server behind a Cloudflare-tunneled, Access-gated hostname (e.g., via service tokens) be registered as an Anthropic remote connector — i.e., is 'private MCP without public exposure' achievable through Anthropic's cloud, or only via the local desktop? (Both directions were refuted in verification.)
- What is the measured end-to-end latency and touch/multi-touch UX of LinuxServer's Selkies stack versus kasmVNC (with WebRTC UDP transit enabled) through a Cloudflare tunnel from an iPad on a real WAN?
- How do the unexamined competitors from the original question — Kasm Workspaces (kasmVNC's own commercial parent), Coder, Guacamole, and Tailscale-based setups — serve the 'persistent AI desktop from a tablet' job, and which moat-extension features (encrypted backup, fleet management, token-spend observability) do their users actually demand?

## Sources fetched

- <https://www.pistack.xyz/posts/2026-04-26-kasm-vs-webtop-vs-x2go-self-hosted-browser-desktop-guide-2026/>
- <https://github.com/QuivrHQ/247-claude-code-remote>
- <https://github.com/linuxserver/docker-webtop>
- <https://www.infoq.com/news/2026/05/coder-agents-self-hosted-ai/>
- <https://github.com/anthropics/claude-code/issues/25746>
- <https://www.linuxserver.io/blog/webtop-4-1-x11-is-dead-and-what-is-selkies-anyway>
- <https://www.linuxserver.io/blog/spring-cleaning-new-images-and-rebasing>
- <https://github.com/selkies-project/selkies>
- <https://kasmweb.com/kasmvnc/docs/master/clientside.html>
- <https://github.com/selkies-project/selkies/issues/112>
- <https://www.cendio.com/blog/kasm-vnc-alternatives/>
- <https://code.claude.com/docs/en/desktop-linux>
- <https://claudefa.st/blog/guide/development/remote-control-guide>
- <https://releasebot.io/updates/anthropic/claude>
- <https://support.claude.com/en/articles/11175166-get-started-with-custom-connectors-using-remote-mcp>
- <https://readthemanual.co.uk/homelab-essential-services-2025-build-your-full-stack/>
- <https://metasora.com/blog/homelab-monitoring-stack-2026/>
- <https://geniustechlab.com/posts/2026-04-28-homelab-ai-stack-2026>
- <https://www.theregister.com/software/2026/02/20/anthropic-clarifies-ban-on-third-party-tool-access-to-claude/5014546>
- <https://www.daimonlegal.com/blog/anthropic-banned-my-account-for-using-openclaw-heres-what-to-do-if-it-happens-to-you>
- <https://autonomee.ai/blog/claude-code-terms-of-service-explained/>
- <https://www.cloudflare.com/service-specific-terms-zero-trust-services/>

## Run stats

```json
{
  "angles": 5,
  "sourcesFetched": 22,
  "claimsExtracted": 108,
  "claimsVerified": 25,
  "confirmed": 21,
  "killed": 4,
  "unverified": 0,
  "afterSynthesis": 8,
  "urlDupes": 1,
  "budgetDropped": 7,
  "agentCalls": 104
}
```

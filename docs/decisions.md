# Decisions

Architecture decision records for Coworkstation, newest first. Each
records the context, the decision, and what would make us revisit it.
Evidence citations reference
[`research/2026-07-05-moat-research.md`](research/2026-07-05-moat-research.md)
(findings F0–F7).

## ADR-006: Do not market "own MCP from a tablet" as the moat until validated

- **Status:** accepted, 2026-07-05
- **Context:** Remote MCP connectors now reach Claude web, Cowork,
  Desktop, and mobile on every plan tier (F1) — tablet reach alone is
  no longer differentiating. Verification killed claims in BOTH
  directions on whether private/local-filesystem MCP stays outside
  Anthropic's cloud reach (see refuted claims in the research doc).
- **Decision:** Frame the MCP story as "your MCP servers run 24/7 on
  your hardware against your real filesystem" and empirically test
  whether an Access-gated tunneled MCP can register as a remote
  connector before making privacy-boundary claims in the README.
- **Revisit when:** the connector-registration experiment (open
  question 2 in the research doc) has an answer either way.

## ADR-005: Press the zero-trust moat — per-member Access policies and audit logging

- **Status:** accepted (direction), 2026-07-05
- **Context:** docker-webtop, the dominant self-hosted web desktop,
  ships optional Basic auth, a passwordless-sudo GUI terminal, and a
  README warning against internet exposure (F7). The ecosystem
  delegates internet-facing security to an external proxy the user
  must assemble. Our integrated Access-gated tunnel + `doctor` that
  fails on exposure is exactly that missing package.
- **Decision:** Extend rather than dilute: per-app/per-member Access
  policies, audit logging of session and tunnel events, and document
  the `doctor` as a compliance surface.
- **Revisit when:** never in direction; individual features are
  prioritized against the follow-up research.

## ADR-004: No bwrap Cowork backend on boxes without KVM

- **Status:** accepted, 2026-07-05
- **Context:** Cowork's engine runs the agent in a KVM microVM; boxes
  without `/dev/kvm` (most cheap VPSes lack nested virtualization) get
  `backend=none` and no Cowork. The claude-desktop-debian project
  prototyped a bubblewrap (bwrap) substitute backend by patching the
  app's minified JS, and parked it in their v3.0.0 rewrite when they
  moved to repackaging Anthropic's official .deb unmodified.
- **Decision:** Do not ship a bwrap backend. Three reasons:
  1. **Isolation regression.** Cowork's safety story for an
     autonomous agent is a hardware VM boundary. bwrap is kernel
     namespaces — same kernel, no hardware boundary. On our
     multi-tenant box (per-member Linux users, slice quotas), swapping
     the VM for namespaces quietly downgrades the strongest isolation
     layer precisely where the agent is least supervised. Our own
     `doctor`/zero-trust positioning (ADR-005) would be undermined by
     shipping a weaker sandbox as a convenience default.
  2. **It requires patching the official app's bytes.** The whole
     v3-alignment win (F0) — and the ToS-risk improvement the research
     flags — comes from running Anthropic's app unmodified. A bwrap
     backend only exists as a minified-JS patch, which breaks on every
     upstream re-minification, and official apt packages auto-update.
     Upstream parked it for the same reason; there is no maintained
     patch base to borrow.
  3. **Solo-maintainer treadmill.** Re-anchoring regex patches against
     weekly upstream releases is the highest-recurring-cost work item
     in this problem space (claude-desktop-debian's history shows it).
- **Instead:** document KVM-capable providers in the runbook, keep the
  `doctor` loud about `backend=none` (WARN with the reason), and rely
  on the Code tab + SSH-target mode, which work everywhere.
- **Revisit when:** (a) Anthropic ships an official non-KVM Cowork
  fallback (their call to make); (b) upstream un-parks a maintained
  bwrap patch we could gate behind an explicit
  `--cowork-compat=bwrap` opt-in flag with a loud isolation warning;
  or (c) user demand makes the opt-in flag worth the treadmill.

## ADR-003: The client bridge is the product direction; PWA + clipboard bridge next

- **Status:** accepted, 2026-07-05
- **Context:** The durable value after Anthropic's Linux launch (F0)
  is the remote-access layer. kasmVNC's seamless clipboard is
  Chromium-only; Safari is unsupported for direct connections, and on
  iPad every browser is WebKit — so tablets have no seamless clipboard
  path at all (F6). Our Cloudflare Access fronting already supplies
  the alternative auth that makes Safari sessions work; the clipboard
  is the remaining gap. Competitor 247 ships a genuine mobile-first
  PWA, proving polish there is table stakes (F2), while leaving full
  desktop, reboot-surviving sessions, and complete self-hosting to us.
- **Decision:** Keep building the client tier (ClientSync, browser
  bridge, laptop live-mount — all shipped) and add a PWA wrapper with
  a WebKit-safe clipboard bridge on the existing `/bridge/*` route.
- **Revisit when:** Anthropic ships a first-party remote/mobile
  desktop experience that covers persistent own-hardware sessions.

## ADR-002: Stay on kasmVNC; enable WebRTC UDP transit; Selkies behind a flag

- **Status:** accepted, 2026-07-05
- **Context:** LinuxServer.io rebased its Webtop catalog from KasmVNC
  to Selkies and calls its X11/VNC stack "on life support" (F3) — the
  VNC-derived family is losing its most influential packager. But
  LinuxServer's own disclosure says the initial Selkies implementation
  is LAN-optimized and may be perceptibly worse on high-latency WAN —
  exactly our Cloudflare-tunnel profile — and upstream Selkies has
  maintainer-continuity risk (F4, F5). kasmVNC already ships a WebRTC
  UDP transit mode for high-latency links (shipped 1.0, regressed 1.2,
  fixed 1.3) plus mobile input affordances (F6). All Selkies
  performance figures are unbenchmarked vendor claims.
- **Decision:** kasmVNC stays the default session layer. Enable/expose
  its WebRTC UDP transit. Treat kasmVNC as a 12–24 month horizon:
  prototype an optional Selkies-flavored session behind a flag for
  GPU/LAN users, and gate any default switch on measured WAN/tunnel
  latency beating kasmVNC-with-WebRTC from a real tablet.
- **Revisit when:** Selkies lands WAN congestion-control work, or a
  head-to-head tunnel benchmark (open question 3) favors it.

## ADR-001: Prefer the official Anthropic engine; never modify its bytes

- **Status:** accepted, 2026-07-05 (formalizes the v3 alignment)
- **Context:** Anthropic launched official Claude Desktop for Linux
  (beta) on 2026-06-30 with Chat, Cowork, and Code tabs via a signed
  apt repo for Debian 12+/Ubuntu 22.04+ (F0). claude-desktop-debian
  v3.0.0 now repackages that official .deb byte-for-byte as
  `claude-desktop-unofficial`.
- **Decision:** The official package is the default engine wherever it
  installs; the community repackage is a fallback (`--engine repo`),
  useful mainly off Debian-family. We never patch the app's code —
  everything Coworkstation adds is launcher-side (`cws-launch`),
  config-side, or runs beside the app (bridge, MCP servers). This is
  both the ToS posture and the maintenance posture.
- **Caveat:** the official beta's terms around multi-user/VNC-exposed
  operation are unexamined (open question 1); the ToS improvement is
  directional, not confirmed.
- **Revisit when:** open question 1 gets an answer, or the official
  package's platform support changes.

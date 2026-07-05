# Moat research, pass 3 — 2026-07-05

Third pass, reframed by the MDM/multi-tenant product direction
(ADR-008): session-lifecycle patterns from Kasm paid tiers, Coder,
and AWS WorkSpaces; what Cloudflare Access can assert about identity
and devices; plus another attempt at the still-uncovered competitors,
moat features, and hosting economics. 106 agents, 24 sources, 117
claims extracted, 25 verified (23 confirmed, 2 killed), 10 findings.

## Question

> Research pass 3 for Coworkstation (github.com/jongodb/coworkstation — Linux box → personal browser-reachable Claude Desktop workstation; per-user kasmVNC behind Cloudflare Tunnel + Access, zero inbound ports, per-member Linux isolation, client bridge, exposure-failing doctor). Two prior verified passes (2026-07-05) covered: 247/claude-code-remote, LinuxServer/Selkies, kasmVNC, docker-webtop, Anthropic's official Claude Desktop Linux beta, Kasm Workspaces CE licensing, Guacamole, Anthropic consumer-terms account-sharing/OAuth clauses, and private-MCP connector mechanics. This pass covers ONLY what is still missing, now reframed by the maintainer's stated product direction: a multi-tenant, multi-client "MDM/MAM-style" management layer — per-user token analytics, fleet/session management across boxes, forced per-user authentication (each member has their OWN Claude subscription; login stored per session), and device-bound sessions (new client device = new session, identified e.g. by Cloudflare Access JWT identity, device posture, or user agent). Question groups, each needing primary-source evidence: (1) SESSION-MANAGEMENT PATTERNS: how does Kasm Workspaces (paid tiers) do dynamic per-user/per-device session provisioning, session lifecycle (create/pause/resume/destroy), and admin dashboards — what's the concrete model a solo maintainer should imitate with systemd + kasmVNC primitives? How do Coder (coder/coder) workspaces and cloud VDI (AWS WorkSpaces, Windows 365) handle per-device session binding, idle timeout/reclaim, and per-user usage metering? What does Cloudflare Access expose per request/session that can bind a desktop session to a device (JWT claims, device posture checks, WARP device UUID, user-agent) without managing devices ourselves? (2) STILL-UNCOVERED COMPETITORS (verified claims survived for none of these in two passes — try different search angles, e.g. docs sites directly): Coder/code-server (multi-user model, licensing), DevPod/Gitpod, Sunshine/Moonlight, Tailscale-based remote desktop (tsnet, Tailscale SSH session recording). (3) REMAINING MOAT FEATURES, state of the art + solo-maintainer effort: encrypted whole-workstation backup/restore (restic/borg patterns for /home + configs, systemd timers, cloud targets), multi-box fleet management from one CLI (Ansible-lite patterns, mesh approaches, existing FOSS fleet CLIs), GPU passthrough for local models alongside a kasmVNC desktop (vfio vs shared /dev/dri; Ollama on the same box), wake-on-LAN + VPS idle-shutdown cost automation. (4) HOSTING: for the specific requirement "full Claude Desktop parity including the Cowork KVM microVM, multi-tenant, always-on, budget-conscious" — compare concrete 2026 options with prices: Hetzner dedicated/server auction, OVH/Kimsufi/So-you-Start dedicated, low-cost bare-metal providers, colocation-lite, used mini-PC at home (N100/N305/Ryzen minis) behind Cloudflare Tunnel, GCP with nested virt for burst testing. Which gives best always-on $/member for 2-10 members needing /dev/kvm? Deliver prioritized recommendations by (impact on the MDM/multi-tenant product direction)/(effort for one maintainer); flag ToS-risk changes; separate verified findings from vendor claims.

## Synthesis

For the MDM/multi-tenant direction, the state of the art gives Coworkstation a clear, imitable blueprint: Kasm's paid Developer API models sessions as create(user_id)/status/keepalive/destroy with lifetime policy in group config, and Coder models workspaces as Running/Stopped/Deleted with session-connection-based autostop plus a paid two-step dormant-then-delete reclaim — all replicable by one maintainer with per-user systemd units, persistent /home, a keepalive heartbeat from the client bridge, and timers. For identity, Cloudflare Access already injects a verified per-request JWT (Cf-Access-Jwt-Assertion) whose sub/email are a stable per-member key, so per-user forced auth and token analytics can be keyed off Access without Coworkstation running its own auth. However, true device-bound sessions are the hard part: device_id, posture, and session lists are NOT in the JWT (they require a server-side /cdn-cgi/access/get-identity exchange), and device UUID/posture checks require the WARP client — with UUIDs only assignable via an MDM deployment file — so a pure browser-only flow cannot get cryptographic device identity from Cloudflare and must fall back to get-identity session data, its own device cookies, or clientless mTLS/Entra checks. Question groups 2 (Coder licensing details aside, DevPod/Gitpod/Sunshine/Tailscale), 3 (backup, fleet CLI, GPU, WoL/idle-shutdown), and 4 (2026 hosting prices for KVM-capable boxes) produced no surviving verified claims this pass and remain open.

## Confirmed findings

### P3-F0

**Confidence:** high · **verifier vote:** 3-0 and 3-0 (claims 0+1 merged)

Session-lifecycle blueprint #1 (Kasm paid tier): Kasm Workspaces exposes programmatic session lifecycle via a Developer API — POST /api/public/request_kasm (create + bind to a user via an optional user_id parameter; omitting it auto-creates an anonymous user), /api/public/get_kasm_status, /api/public/keepalive, and /api/public/destroy_kasm. This is the concrete create/status/keepalive/destroy + user-binding model a solo maintainer should imitate with systemd units + kasmVNC primitives. Note: the developer_api is listed under Kasm's Enterprise SKU, so it is a design pattern to copy, not a free primitive to reuse from Kasm CE.

**Evidence:** Docs verbatim: "Requesting a Kasm will create and start the container and assign a user to that Kasm." and "If no User ID is sent an anonymous user will be created and used for the Kasm." All four endpoints confirmed stable from v1.10 through current v1.17; licensing section lists developer_api under the Enterprise SKU.

**Sources:**
- <https://docs.kasm.com/docs/develop/reference/developer-api>
- <https://kasm.com/docs/latest/developers/developer_api.html>

### P3-F1

**Confidence:** high · **verifier vote:** 3-0 and 3-0 (claims 2+10 merged)

Kasm puts session-lifetime policy in configuration, not in the session: idle reclaim is a keepalive heartbeat whose extension window is the per-group keepalive_expiration setting (default 1h; expiry action delete/pause/stop set by keepalive_expiration_action), and absolute expiry is a per-workspace Session Time Limit in seconds with a user-facing countdown timer. For Coworkstation: policy lives in a per-member/group config file; enforcement is a systemd timer + heartbeat from the client bridge + desktop notification for the countdown.

**Evidence:** "Issue a keepalive to reset the expiration time of a Kasm session. The new expiration time will be updated to reflect the keepalive_expiration Group Setting assigned to the Kasm's associated user." and "Session Time Limit: The amount of time (in seconds) before a session will automatically expire. A countdown timer will be displayed to the user." Caveat: if session_time_limit is set it supersedes keepalive_expiration; connected clients send keepalives automatically.

**Sources:**
- <https://docs.kasm.com/docs/develop/reference/developer-api>
- <https://kasmweb.com/docs/develop/guide/groups/group_settings.html>
- <https://kasm.com/docs/latest/guide/workspaces.html>

### P3-F2

**Confidence:** high · **verifier vote:** 3-0 (claim 11)

Kasm's provisioning taxonomy is four workspace types — Container (docker-provisioned, streamed over KasmVNC), Server (a single physical/virtual machine reached via KasmVNC/RDP/VNC/SSH), Server Pool ("Groups of Servers that are to be treated equally", i.e. interchangeable fleet members), and Link. This maps directly onto Coworkstation's design axis: 'Server' = per-user session on one box today; 'Server Pool' = the fleet-of-boxes model the MDM direction implies, where a broker assigns a member to any interchangeable box.

**Evidence:** Verbatim: "Container: Linux docker images ... provision by docker as containers"; "Server Pool: Groups of Servers that are to be treated equally by Kasm Workspaces ... treat each server in a Server Pool as interchangeable."

**Sources:**
- <https://kasm.com/docs/latest/guide/workspaces.html>

### P3-F3

**Confidence:** high · **verifier vote:** 3-0, 3-0, 3-0 (claims 3+4+6 merged)

Session-lifecycle blueprint #2 (Coder OSS): Coder models workspace lifecycle as three primary states — Running, Stopped ("Ephemeral resources destroyed, persistent resources idle"), Deleted (terraform destroy of everything) — and the OSS tier includes automatic idle reclaim: template-level autostop stops a workspace after N hours without user activity, gated on live inactivity checks. For Coworkstation: Running = kasmVNC unit up; Stopped = unit down, /home persists; Deleted = member offboarded — implementable as systemd unit state + a persistent home volume.

**Evidence:** Lifecycle page fetched live 2026-07-05: Stopped = "Ephemeral resources destroyed, persistent resources idle"; "Workspaces may be automatically stopped due to template updates or inactivity by scheduling configuration"; scheduling docs: "Autostop won't stop a workspace if you're still using it. It will wait for the user to become inactive before checking connections again (1 hour by default)." Basic autostop is not premium-gated.

**Sources:**
- <https://coder.com/docs/user-guides/workspace-lifecycle>
- <https://coder.com/docs/admin/templates/managing-templates/schedule>
- <https://coder.com/docs/user-guides/workspace-scheduling>

### P3-F4

**Confidence:** high · **verifier vote:** 3-0 (claim 7)

Coder's idle heuristic is session-connection-based, not device polling: a workspace is inactive when no live client sessions (VSCode, JetBrains, Terminal, SSH) are detected, and any detected activity 'bumps' the stop deadline by a default of 1 hour. Dashboard viewing and settings edits do NOT count as activity. Coworkstation equivalent: treat an open kasmVNC websocket / client-bridge connection as the activity signal and bump a per-session deadline on traffic.

**Evidence:** "The workspace will be considered inactive when no sessions are detected (VSCode, JetBrains, Terminal, or SSH)"; activity bump = "The duration by which to extend a workspace's deadline when activity is detected (default: 1 hour)." Minor: newer docs also count AI-agent 'working' status (Coder Tasks) as activity.

**Sources:**
- <https://coder.com/docs/admin/templates/managing-templates/schedule>
- <https://coder.com/docs/user-guides/workspace-scheduling>

### P3-F5

**Confidence:** high · **verifier vote:** 3-0 and 3-0 (claims 5+8 merged)

Coder gates the multi-stage reclaim lifecycle behind its paid (Premium, formerly Enterprise) tier: autostop requirement (forced restarts independent of activity), dormancy threshold, dormancy auto-deletion, failure cleanup, and user quiet hours all require a license. The paid pattern is a two-step reclaim — inactive → dormant (recoverable, requires manual user reactivation) → queued for deletion — which is the state-of-the-art cost-conscious model Coworkstation can ship for free as its differentiator (stop unit → archive /home after N days → delete after M days).

**Evidence:** "workspaces will become dormant after a specified duration of inactivity. Then, if left dormant, the workspaces will be queued for deletion" (prefaced "When enabled on enterprise deployments"). Schedule page states verbatim: "Autostop requirement is a Premium feature.", "Dormancy threshold is a Premium feature.", "Dormancy Auto-Deletion is a Premium feature.", "Failure cleanup is a Premium feature.", "User quiet hours are a Premium feature."

**Sources:**
- <https://coder.com/docs/user-guides/workspace-lifecycle>
- <https://coder.com/docs/admin/templates/managing-templates/schedule>

### P3-F6

**Confidence:** high · **verifier vote:** 3-0 (claim 9)

AWS WorkSpaces' AutoStop reclaim is disconnect-triggered, not activity-triggered: default AutoStop time is 1 hour after disconnection, and a session counts as disconnected only on manual disconnect/client quit, client-device shutdown, or >20 minutes with no client-to-workspace connection. A locked/sleeping device with the client running may never trigger it. Lesson for Coworkstation: pure connection-presence heuristics under-reclaim; combine connection state (WorkSpaces-style) with in-session activity (Coder-style) for the doctor/reclaim logic.

**Evidence:** AWS admin guide verbatim: "AutoStop WorkSpaces stop automatically only if the WorkSpaces are disconnected" with exactly the three listed disconnection circumstances; caveat that a backgrounded client "might not be disconnected, and therefore the WorkSpace might not automatically stop." Note: a companion claim that WorkSpaces has exactly two billing modes (AlwaysOn/AutoStop) was REFUTED 0-3 — do not reuse that billing framing.

**Sources:**
- <https://docs.aws.amazon.com/workspaces/latest/adminguide/running-mode.html>

### P3-F7

**Confidence:** high · **verifier vote:** 3-0 ×4 (claims 12+14+15+16 merged)

Per-user identity without running auth: Cloudflare Access acts as an authentication proxy and includes the application JWT with ALL authenticated requests to the origin as the Cf-Access-Jwt-Assertion header (validate the header, not the CF_Authorization cookie, which is not guaranteed to be passed). The JWT payload carries sub ("unique to an email address per account"), IdP-verified email, country, iss (team domain), and aud (per-application scope) — sufficient to key per-member session provisioning and per-user token analytics. Caveats: sub changes if a user is removed and re-added to the account; sub is empty for service tokens; the origin must cryptographically validate signature + aud against the team certs.

**Evidence:** Verbatim across three live Cloudflare docs pages (2026-07-05): "sub: The ID of the user. This value is unique to an email address per account"; "email: The email address of the authenticated user, verified by the identity provider"; "We recommend validating the Cf-Access-Jwt-Assertion header instead of the CF_Authorization cookie, since the cookie is not guaranteed to be passed"; "The aud claim in the token payload specifies which application the JWT is valid for"; Access "is an authentication proxy in charge of validating a user's identity before they connect to your application."

**Sources:**
- <https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/authorization-cookie/application-token/>
- <https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/authorization-cookie/validating-json/>
- <https://developers.cloudflare.com/cloudflare-one/tutorials/extend-sso-with-workers/>

### P3-F8

**Confidence:** high · **verifier vote:** 3-0 ×3 (claims 13+17+18 merged)

Device-binding signals require an extra server-side lookup, not JWT parsing: device_id, devicePosture, WARP status (is_warp), and device_sessions are NOT claims in the Access JWT. The origin/Worker must forward the request's CF_Authorization cookie to https://<team>.cloudflareaccess.com/cdn-cgi/access/get-identity, which returns the full identity — id, name, email, groups, geo, user_uuid, account_id, plus a devicePosture object with per-check results (type, success, timestamp, rule_name; e.g. disk_encryption, firewall) and device_sessions. So Coworkstation's 'new device = new session' logic is buildable, but only via this get-identity exchange in the session broker, and posture fields populate only when the WARP/Cloudflare One client is on the device.

**Evidence:** JWT payload table documents only aud/email/exp/iat/nbf/iss/type/identity_nonce/sub/country — no device claims. Docs: send CF_Authorization to /cdn-cgi/access/get-identity to obtain "The device posture attributes" (devicePosture), device_sessions ("A list of all sessions initiated by the user"), is_warp. Tutorial's example response contains id, name, email, groups, geo, user_uuid, account_id and posture entries like {"type": "disk_encryption", "success": false, "rule_name": "Disk Encryption - Windows"}.

**Sources:**
- <https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/authorization-cookie/application-token/>
- <https://developers.cloudflare.com/cloudflare-one/tutorials/extend-sso-with-workers/>
- <https://developers.cloudflare.com/cloudflare-one/identity/devices/>

### P3-F9

**Confidence:** high · **verifier vote:** 2-1, 3-0, 3-0, 3-0 (claims 19+20+21+22 merged; one 2-1 component verified high by its verifier)

Hard limit on browser-only device binding: Cloudflare's Device UUID mechanism requires the Cloudflare One (WARP) client installed on each device AND UUIDs supplied via an MDM deployment file (unique_client_id key) — "It is not possible to assign them manually" and Cloudflare does not auto-generate them for this feature. More broadly, Cloudflare One Client checks and service-to-service posture checks "rely on traffic going through the Cloudflare One Client"; only mTLS and Microsoft Entra Conditional Access posture checks work clientless in Access policies. Implication: Coworkstation's browser-reachable kasmVNC flow cannot get cryptographic device identity from Cloudflare without shipping/managing a WARP client per member device (which the MDM-style product could actually choose to do); otherwise device binding must use get-identity's device_sessions, its own long-lived device cookie, or mTLS client certificates.

**Evidence:** Verbatim: "Cloudflare One allows you to build Zero Trust rules based on device UUIDs supplied in an MDM file"; "You will need to use a managed deployment tool to assign UUIDs. It is not possible to assign them manually"; prerequisite "Cloudflare One Client is deployed on the device"; "Cloudflare One Client and service-to-service posture checks rely on traffic going through the Cloudflare One Client to detect posture information." Access-integrations page: only Entra Conditional Access and Mutual TLS "do not require the Cloudflare One Client." Nuance: the 'MDM file' is just a config file (e.g. /var/lib/cloudflare-warp/mdm.xml) a script can place — no commercial MDM product needed.

**Sources:**
- <https://developers.cloudflare.com/cloudflare-one/identity/devices/warp-client-checks/device-uuid/>
- <https://developers.cloudflare.com/cloudflare-one/reusable-components/posture-checks/>
- <https://developers.cloudflare.com/cloudflare-one/reusable-components/posture-checks/access-integrations/>

## Coverage gaps — STILL unresearched after three passes

No surviving verified claims, a third time, for: DevPod/Gitpod,
Sunshine/Moonlight, Tailscale-based remote desktop, encrypted
backup/restore, multi-box fleet CLI patterns, GPU passthrough,
wake-on-LAN/idle-shutdown automation, and 2026 hosting prices for
KVM-capable boxes. The hosting comparison in particular needs live
price checks rather than another search pass.

## Refuted claims (killed in adversarial verification)

- **0-3** — AWS WorkSpaces exposes exactly two session/billing lifecycle modes per workspace — AlwaysOn (fixed monthly fee) and AutoStop (hourly billing that suspends when the workspace stops) — which is the metering model Coworkstation could imitate with systemd start/stop of per-user kasmVNC sessions.
  - source under test: <https://docs.aws.amazon.com/workspaces/latest/adminguide/running-mode.html>
- **0-3** — Cloudflare device posture checks require additional signals beyond identity: they come either from the Cloudflare One (WARP) client or from third-party endpoint security providers — so binding a Coworkstation desktop session to device posture means deploying the WARP client (or an EDR integration) on every member device.
  - source under test: <https://developers.cloudflare.com/cloudflare-one/reusable-components/posture-checks/>

## Caveats (verbatim from the synthesis)

Coverage gap: of the four question groups, only group 1 (session-management patterns) and the Cloudflare-identity half of the device-binding question produced surviving claims. Group 2 competitors beyond Coder (DevPod/Gitpod, Sunshine/Moonlight, Tailscale tsnet/SSH recording, code-server licensing specifics), all of group 3 moat features (restic/borg backup patterns, fleet CLIs, GPU passthrough vs /dev/dri, WoL/idle-shutdown automation), and all of group 4 hosting/pricing (Hetzner/OVH/mini-PC/GCP nested-virt $/member with /dev/kvm) have NO verified findings in this pass — treat any statements about them as unresearched. Two claims were refuted (AWS WorkSpaces two-billing-modes framing; a mischaracterization of Cloudflare posture-signal sources) — do not carry them forward. Kasm's Developer API and Coder's dormancy features are paid-tier: they are patterns to imitate, not primitives to reuse. Cloudflare 'sub' is stable only while a member remains in the Cloudflare account (removed-and-re-added users get a new sub) and is empty for service tokens. All evidence is vendor documentation fetched live 2026-07-05; endpoint paths, tier gating (Coder 'Premium' rebrand), and Cloudflare docs URLs (recently reorganized under /access-controls/) are subject to change. No ToS-risk changes surfaced in this pass's evidence — the per-member-own-subscription model remains governed by the Anthropic consumer-terms findings from the two prior passes; nothing here contradicts them, but per-user token analytics scraped from members' own accounts was not covered by any verified claim and needs its own ToS check.

## Open questions

- Hosting economics remain unanswered: what is the actual 2026 always-on $/member for 2-10 members needing /dev/kvm (Hetzner auction vs OVH/Kimsufi vs used N100/N305/Ryzen mini-PC at home vs GCP nested virt), and does the Cowork KVM microVM run acceptably on each?
- Per-user token analytics: is there any sanctioned, ToS-safe way to meter Claude usage per member (local Claude Desktop logs, claude-code-remote session data, or Anthropic usage APIs for consumer subscriptions), given each member logs in with their own subscription?
- Clientless device binding in practice: how reliable is get-identity's device_sessions list for 'new device = new session' detection for browser-only users, and is per-member mTLS client-certificate issuance (the one strong clientless signal) tractable for a solo maintainer across members' personal devices?
- Fleet/backup moat features: what do existing FOSS patterns (restic+systemd timers for /home, Ansible-lite or mesh fleet CLIs) actually cost in maintainer effort, and does any existing project already combine them with per-user desktop sessions?

## Sources fetched

- <https://docs.kasm.com/docs/develop/reference/developer-api>
- <https://coder.com/docs/user-guides/workspace-lifecycle>
- <https://coder.com/docs/admin/templates/managing-templates/schedule>
- <https://docs.aws.amazon.com/workspaces/latest/adminguide/running-mode.html>
- <https://kasm.com/docs/latest/guide/workspaces.html>
- <https://github.com/kasmtech/workspaces-issues/issues/624>
- <https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/authorization-cookie/application-token/>
- <https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/authorization-cookie/validating-json/>
- <https://developers.cloudflare.com/cloudflare-one/tutorials/extend-sso-with-workers/>
- <https://developers.cloudflare.com/cloudflare-one/identity/devices/warp-client-checks/device-uuid/>
- <https://developers.cloudflare.com/cloudflare-one/reusable-components/posture-checks/>
- <https://github.com/cloudflare/cf-identity-dynamic>
- <https://coder.com/pricing>
- <https://coder.com/docs/admin/users/organizations>
- <https://coder.com/blog/code-server-multiple-users>
- <https://tailscale.com/docs/features/tailscale-ssh/tailscale-ssh-session-recording>
- <https://kasmweb.com/kasmvnc/docs/latest/gpu_acceleration.html>
- <https://www.kasmweb.com/docs/develop/how_to/manual_intel_amd.html>
- <https://fedoramagazine.org/automate-backups-with-restic-and-systemd/>
- <https://www.hetzner.com/sb/>
- <https://www.hetzner.com/pressroom/standardization-and-price-adjustment-of-our-server-products/>
- <https://valebyte.com/en/blog/ovh-soyoustart-vs-kimsufi-vs-eco-where-the-budget-dedicated-servers-moved/>
- <https://docs.cloud.google.com/compute/docs/instances/nested-virtualization/overview>
- <https://selfhosting.sh/hardware/mini-pc-power-consumption/>

## Run stats
```json
{
  "angles": 5,
  "sourcesFetched": 24,
  "claimsExtracted": 117,
  "claimsVerified": 25,
  "confirmed": 23,
  "killed": 2,
  "unverified": 0,
  "afterSynthesis": 10,
  "urlDupes": 0,
  "budgetDropped": 6,
  "agentCalls": 106
}
```

# Moat research, pass 2 — 2026-07-05

Follow-up to [`2026-07-05-moat-research.md`](2026-07-05-moat-research.md),
covering only what that run missed: the uncovered competitors, the
unresearched moat features, and its two open questions (Anthropic
terms for multi-user/remote operation; private MCP via the connector
path). 104 agents, 22 sources, 103 claims extracted, 25 verified
(21 confirmed, 4 killed), 10 surviving findings.

## Question

> Follow-up research for Coworkstation (github.com/jongodb/coworkstation — a Linux box turned into a personal, browser-reachable Claude Desktop workstation: per-user kasmVNC session behind a Cloudflare Zero Trust tunnel + Access with zero inbound ports, per-member Linux isolation, a client bridge for device folder/screen sharing, and a `doctor` that fails on any exposure). A prior verified research pass (2026-07-05) covered 247/claude-code-remote, LinuxServer/Selkies, kasmVNC, docker-webtop, and Anthropic's new official Claude Desktop for Linux beta (launched 2026-06-30). This pass must cover ONLY what that run missed. Three question groups, each needing primary-source evidence: (1) UNCOVERED COMPETITORS for the job "persistent AI desktop workstation on own hardware, reachable from a tablet": Kasm Workspaces (the commercial parent of kasmVNC — multi-user fleet features, licensing, what its free tier includes), Apache Guacamole, Coder and code-server, DevPod/Gitpod/Devcontainers, Sunshine/Moonlight game-stream stacks, cloud VDI (AWS WorkSpaces, Windows 365), and Tailscale-based remote-desktop setups (Tailscale + RDP/VNC, tsnet apps). For each: what do they do better that a solo-maintainer project should adopt, and what gaps do they leave that Coworkstation should press? (2) UNCOVERED MOAT-EXTENSION FEATURES self-hosters expect — for each, find the state of the art and effort signal for a solo maintainer: encrypted backup/restore of a whole user workstation (restic/borg patterns), fleet management of multiple boxes from one CLI, observability/alerting for session health and Claude token/quota spend, GPU passthrough for local models alongside the desktop, wake-on-LAN and VPS idle-shutdown cost savers. Which two are highest (impact on differentiation)/(effort)? (3) TWO OPEN QUESTIONS from the prior run: (3a) Do Anthropic's consumer terms or the Claude Desktop Linux beta terms say anything about multi-user, shared-box, or remotely-exposed (VNC/tunnel) operation of the desktop app — quote the exact clauses; (3b) Can a self-hosted MCP server behind a Cloudflare-tunneled Access-gated hostname be registered as an Anthropic custom connector (service tokens? OAuth requirement? must the URL be publicly reachable by Anthropic's cloud?), i.e. is "private MCP without public exposure" achievable via the connector path, or only via the local desktop's stdio config? Deliver prioritized recommendations by (impact on differentiation)/(effort for one maintainer), flag anything that changes terms-of-service risk posture, and clearly separate verified findings from vendor claims.

## Synthesis

Coworkstation's two nearest uncovered competitors leave exploitable gaps: Kasm Workspaces' free Community Edition is licensed only for testing/non-profit/non-commercial use and capped at 5 concurrent sessions, and Apache Guacamole — a genuinely clientless, browser-only, multi-protocol (VNC/RDP/SSH/Telnet/Kubernetes) gateway with deep enterprise SSO/MFA extensions — requires assembling Tomcat + guacd + XML/database auth, so Coworkstation should press "fully FOSS, no session cap, single-command install, identity delegated to Cloudflare Access." On moat features, the highest impact/effort win verified this pass is Claude token/quota observability: the MIT-licensed Claude Code Usage Monitor (~8.4k stars) already parses local JSONL session data with zero API/network dependency and can be integrated rather than built. On terms-of-service (Q3a), Anthropic's legal pages condition Pro/Max limits on "ordinary, individual usage," forbid sharing or routing requests through Free/Pro/Max credentials on behalf of others, and reserve OAuth login for plan purchasers — so Coworkstation must architecturally require one Claude account per member and should document that a multi-tenant *product* wrapping Claude belongs on API-key auth. On private MCP (Q3b), the claude.ai custom-connector path effectively requires an endpoint Anthropic's cloud can reach and complete OAuth against (fixed callback https://claude.ai/api/mcp/auth_callback); Anthropic's own outbound-only "MCP tunnels" exist but are a gated research preview explicitly unavailable as claude.ai connectors, and Cloudflare Access service tokens can't be injected by Anthropic's connector client — so today "private MCP without public exposure" is reliably achievable only via the local desktop's stdio config, which is itself a Coworkstation differentiator.

## Confirmed findings

### P2-F0

**Confidence:** high · **verifier vote:** 3-0 (caps/licensing, x3 claims); 2-1 (solo-self-hoster legality nuance)

Kasm Workspaces Community Edition (the commercial parent of kasmVNC) is free only for testing, non-profits, and non-commercial activity, is limited to 5 concurrent sessions, and carries community-only support; a solo non-commercial self-hoster can legally run the full multi-user stack free, but any commercial or >5-session deployment requires a paid (quote-gated, per-user/per-session) license — a licensing and scale gap a fully-FOSS, uncapped Coworkstation can press directly.

**Evidence:** License docs (consistent across versions 1.9.0–1.17.0, verified 2026-07-05): "Kasm Workspaces Community edition is free to download and install for testing, non-profits and non-commercial activities. It is limited to 5 concurrent sessions and community support via our public issue tracker." Marketing page confirms CE is a no-cost version for individuals/non-profits and businesses *testing* the platform. Note: a separate claim that CE has near-full feature parity with paid tiers was REFUTED (0-3) in verification — do not assert parity.

**Sources:**
- <https://docs.kasm.com/docs/latest/license/index.html>
- <https://www.kasmweb.com/docs/develop/license.html>
- <https://kasm.com/community-edition>

### P2-F1

**Confidence:** high · **verifier vote:** 3-0 (x3 claims)

Apache Guacamole competes directly on the 'reachable from any tablet browser with no installed client' job: it is a clientless, browser-delivered remote-desktop gateway whose native guacd proxy dynamically loads per-protocol plugins, fronting at least five protocols (VNC, RDP, SSH, Telnet, Kubernetes) with the client unaware of which is in use — but it ships no desktop environment of its own, so it competes on protocol breadth, not on the turnkey persistent Linux desktop that kasmVNC/webtop and Coworkstation provide.

**Evidence:** Architecture doc verbatim: users connect via browser to a JavaScript client that talks back over HTTP/WebSocket using the Guacamole protocol; "guacd is the heart of Guacamole which dynamically loads support for remote desktop protocols (called 'client plugins')" and "neither the Guacamole client nor the web application need to be aware of what remote desktop protocol is actually being used." Config docs list libguac-client-vnc/rdp/ssh/telnet plus Kubernetes. Homepage: desktops "accessed through Guacamole need not physically exist" — it brokers to existing servers.

**Sources:**
- <https://guacamole.apache.org/doc/gug/guacamole-architecture.html>
- <https://guacamole.apache.org/doc/gug/configuring-guacamole.html>
- <https://guacamole.apache.org>

### P2-F2

**Confidence:** high · **verifier vote:** 3-0 (x2 claims)

Guacamole's adoptable strength is mature enterprise multi-user auth via official extensions (LDAP/Active Directory, Duo and TOTP MFA, SSO via CAS/OIDC/SAML/smart cards); its pressable weakness is deployment complexity — a servlet container (Tomcat) + guacd daemon + guacamole.properties + optional database, with the simplest built-in auth being static XML username/password pairs. Coworkstation's play: delegate identity entirely to Cloudflare Access (matching the auth depth without maintaining it) while offering a single-CLI install Guacamole's official paths cannot match.

**Evidence:** Official manual documents the extension modules (Active Directory/LDAP; Duo; TOTP; CAS; OpenID Connect; SAML; smart cards/certificates) and states default auth "simply reads usernames and passwords from an XML file" (user-mapping.xml with <authorize> tags). Install docs: native deployment "involves installing a servlet container like Apache Tomcat... and building at least guacamole-server from source"; even official Docker requires two containers plus typically a database. Single-container images exist only as unofficial third-party builds.

**Sources:**
- <https://guacamole.apache.org/doc/gug/configuring-guacamole.html>
- <https://guacamole.apache.org/doc/gug/installing-guacamole.html>

### P2-F3

**Confidence:** high · **verifier vote:** 3-0 (x2 claims)

For Claude token/quota observability — the highest (impact on differentiation)/(effort) moat feature verified this pass — Coworkstation should integrate rather than build: Claude Code Usage Monitor (MIT, ~8.4k stars, actively maintained, v4.0.0 June 2026) provides real-time monitoring by reading Claude Code's local JSONL session files and analyzing 5-hour rolling windows, entirely on-box with no Anthropic API access or network calls by default — a perfect fit for Coworkstation's zero-exposure posture and machine-readable enough (state/export output) to wire into a doctor/dashboard.

**Evidence:** GitHub API verified 2026-07-05: MIT license, 8,373 stars, pushed same day, v4.0.0 released 2026-06-27. README: reads local ~/.claude JSONL (configurable --data-paths), documents the 5-hour rolling session window, privacy-first local-only default. Caveats: monitors Claude Code CLI usage, not Claude Desktop app spend; single-user/local, so per-member fleet aggregation needs glue; displayed limits are provenance-labeled local estimates, not authoritative billing data.

**Sources:**
- <https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor>

### P2-F4

**Confidence:** high · **verifier vote:** 3-0 (x2 claims)

TERMS-OF-SERVICE RISK (Q3a, changes risk posture): Anthropic's legal-and-compliance page conditions advertised Pro/Max limits on "ordinary, individual usage," and the Consumer Terms prohibit sharing accounts or making them available to anyone else; Anthropic additionally forbids third parties from offering Claude.ai login or routing requests through Free/Pro/Max credentials on behalf of users. Consequence for Coworkstation: per-member Linux isolation is necessary but not sufficient — each member MUST log into their own Claude account, and an operator letting housemates/teammates work through the operator's consumer-plan credentials would violate the stated policy (which Anthropic enforced without notice against OpenClaw/OpenCode/Roo Code in early 2026).

**Evidence:** Verified verbatim 2026-07-05: "Advertised usage limits for Pro and Max plans assume ordinary, individual usage of Claude Code and the Agent SDK"; "Anthropic does not permit third-party developers to offer Claude.ai login or to route requests through Free, Pro, or Max plan credentials on behalf of their users"; Consumer Terms: "You may not share your Account login information... You also may not make your Account available to anyone else." Scope caveat: the individual-usage sentence is scoped to Claude Code/Agent SDK, but the account-sharing prohibition in the Consumer Terms covers the Desktop app. No clause specifically addressing VNC/tunnel remote exposure of the Desktop app was found — that specific question remains open.

**Sources:**
- <https://code.claude.com/docs/en/legal-and-compliance>
- <https://anthropic.com/legal/consumer-terms>

### P2-F5

**Confidence:** high · **verifier vote:** 3-0

TERMS-OF-SERVICE RISK (positioning): OAuth (Claude.ai login) is "intended exclusively for purchasers" of subscription plans for their own ordinary use; anyone "building products or services that interact with Claude's capabilities" is directed to API-key authentication via the Claude Console or a cloud provider. Coworkstation should therefore position itself as personal infrastructure each member runs under their own subscription (defensible), and explicitly disclaim/document that operating it as a multi-tenant hosted service around consumer credentials would cross into the prohibited product-builder category.

**Evidence:** Verbatim: "OAuth authentication is intended exclusively for purchasers of Claude Free, Pro, Max, Team, and Enterprise subscription plans and is designed to support ordinary use of Claude Code and other native Anthropic applications... Developers building products or services that interact with Claude's capabilities... should use API key authentication through Claude Console or a supported cloud provider." Same page: "Anthropic reserves the right to take measures to enforce these restrictions and may do so without prior notice." Whether a self-hosted per-member workstation where each member uses their own account counts as a 'product or service' is a genuinely open interpretive question — the claim is hedged accordingly.

**Sources:**
- <https://code.claude.com/docs/en/legal-and-compliance>

### P2-F6

**Confidence:** high · **verifier vote:** 3-0

Q3b, connector mechanics: claude.ai custom connectors use a fixed Anthropic-side OAuth callback (https://claude.ai/api/mcp/auth_callback) for hosted surfaces — the self-hosted MCP server's OAuth endpoints must redirect the user's browser back to claude.ai and complete the token exchange with Anthropic's backend (i.e., Anthropic's cloud must be able to reach the server's /token endpoint); non-hosted clients (Claude Code) use loopback redirects instead. This makes an Access-gated hostname problematic unless the Access policy admits Anthropic's server-side exchange.

**Evidence:** Docs verbatim: "OAuth callback: https://claude.ai/api/mcp/auth_callback (hosted surfaces); loopback redirect for Claude Code." Corroborated by operator reports (anthropics/claude-ai-mcp issues #313, #506) showing Anthropic's backend performing the code-for-token exchange against the MCP server's /token endpoint. Note: a sibling claim that the docs are simply silent on public reachability (so the question is unsettled by this source) was REFUTED 0-3 — the mechanics above imply Anthropic-cloud reachability is required in practice.

**Sources:**
- <https://support.claude.com/en/articles/11503834-building-custom-connectors-via-remote-mcp-servers>
- <https://claude.com/docs/connectors/building>

### P2-F7

**Confidence:** high · **verifier vote:** 3-0 (x3 claims)

Q3b, Anthropic's own private path exists but doesn't apply: Anthropic 'MCP tunnels' provide outbound-only connectivity to MCP servers inside private networks (no inbound ports, no public exposure, no IP allowlisting, transported via Cloudflare), proving 'private MCP without exposure' is architecturally supported — BUT tunnels are explicitly "not available as connectors in claude.ai" (only Claude Managed Agents and the Messages API), and they are a gated, request-access research preview provided as-is that Anthropic "may modify or discontinue... at any time." A solo maintainer cannot build guarantees on this path, and claude.ai/Claude Desktop users cannot use it at all today.

**Evidence:** Verified verbatim 2026-07-05: "Traffic flows over an outbound-only connection, so you don't need to open inbound firewall ports, expose services to the public internet, or allowlist Anthropic's IP ranges"; "MCP tunnels created through the Console are not available as connectors in claude.ai"; "MCP tunnels are in research preview... provided 'as-is' without any uptime, support, or continuity commitment... Anthropic may modify or discontinue MCP tunnels at any time." Corroborated by InfoQ (May 2026), The New Stack, and open feature request anthropics/claude-code#29486 asking for claude.ai tunnel access. Cloudflare acts as subprocessor and observes connection metadata.

**Sources:**
- <https://platform.claude.com/docs/en/agents-and-tools/mcp-tunnels/overview>

### P2-F8

**Confidence:** high · **verifier vote:** 3-0 (x3 claims)

Q3b, Cloudflare side: MCP server portals can front self-hosted remote MCP servers behind a single Access-protected hostname, and machine-to-machine clients can bypass browser OAuth via service tokens (CF-Access-Client-Id/Secret headers) — but this only helps the connector path if the MCP client can inject those headers, and Anthropic's claude.ai connector UI offers only OAuth Client ID/Secret with no custom-header field, so service tokens cannot be used via the connector path today. Portals also support only remote HTTP (Streamable HTTP/SSE) servers — stdio-only MCPs can't be portal-fronted. NET ANSWER TO 3b: 'private MCP without public exposure' is reliably achievable today only via the local desktop's stdio config (or wrapping stdio behind HTTP and accepting an Access-reachable OAuth surface); Coworkstation should treat local stdio-on-the-workstation as the differentiating private-MCP story.

**Evidence:** Cloudflare docs verbatim: portals "centralize multiple Model Context Protocol servers onto a single HTTP endpoint"; "Service tokens bypass the browser-based OAuth flow and authenticate using the CF-Access-Client-Id and CF-Access-Client-Secret headers"; "Only remote HTTP MCP servers are supported. MCP servers that use stdio transport only do not expose a remote HTTP endpoint." claude.ai connector header-injection absence corroborated by anthropics/claude-ai-mcp issue #112 and Claude Help Center article 11175166. Feature is GA. Note: a related claim that manual credentials for non-DCR servers provide a workaround was REFUTED/split (1-2) — do not rely on it.

**Sources:**
- <https://developers.cloudflare.com/cloudflare-one/access-controls/ai-controls/mcp-portals/>
- <https://github.com/anthropics/claude-ai-mcp/issues/112>

### P2-F9

**Confidence:** medium · **verifier vote:** None

Prioritized recommendations by (impact on differentiation)/(effort for one maintainer): (1) Ship token/quota observability by integrating Claude Code Usage Monitor per-member into the doctor/dashboard — existing MIT component, local-only, days of glue work, and no competitor in the verified set offers it. (2) Weaponize the verified competitor gaps in positioning and product: keep the single-CLI install and zero-cap FOSS licensing story explicit against Kasm CE's non-commercial 5-session license and Guacamole's Tomcat+guacd+XML assembly, while continuing to delegate enterprise-grade auth to Cloudflare Access rather than rebuilding Guacamole's extension matrix. (3) Document the private-MCP story honestly: local stdio config on the workstation is the supported zero-exposure path; claude.ai custom connectors behind Access are not reliably private today, and MCP tunnels are a preview that excludes claude.ai.

**Evidence:** Synthesis judgment over the 21 verified claims. Confidence is medium because the moat-feature comparison set is incomplete: no claims about encrypted backup/restore (restic/borg), fleet management, GPU passthrough, or wake-on-LAN/idle-shutdown survived verification in this pass, so the 'top two by impact/effort' ranking is made against a partial field — observability is the only moat feature with verified state-of-the-art evidence.

**Sources:**
- <https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor>
- <https://docs.kasm.com/docs/latest/license/index.html>
- <https://guacamole.apache.org/doc/gug/installing-guacamole.html>
- <https://platform.claude.com/docs/en/agents-and-tools/mcp-tunnels/overview>

## Coverage gaps — still unresearched after two passes

No surviving verified claims, again, for: **Coder/code-server,
DevPod/Gitpod/devcontainers, Sunshine/Moonlight, AWS
WorkSpaces/Windows 365, and Tailscale-based setups** (competitive
conclusions rest on Kasm Workspaces + Guacamole only), and for four
of the five moat features: **encrypted backup/restore, fleet
management, GPU passthrough, wake-on-LAN/idle-shutdown** — the
impact/effort ranking rests on observability alone plus judgment.

## Refuted claims (killed in adversarial verification)

- **0-3** — Community Edition retains near feature parity with the paid tiers; the primary difference Kasm states is the support model (community support instead of vendor support), not removed features.
  - source under test: <https://kasm.com/community-edition>
- **0-3** — Kasm CE ships enterprise-grade multi-user features that Coworkstation lacks — including SSO/2FA authentication, data loss prevention, web filtering, security groups/logging, and browser-based access to containerized Linux/Windows desktops deployable on-premise, in private cloud, or as SaaS.
  - source under test: <https://kasm.com/community-edition>
- **1-2** — Custom connectors support OAuth 2.0 with Dynamic Client Registration, and also allow manually supplied credentials for servers that do not implement DCR — so an Access-gated self-hosted MCP server is not strictly required to implement DCR, but there is no documented no-auth or Cloudflare-service-token path.
  - source under test: <https://support.claude.com/en/articles/11503834-building-custom-connectors-via-remote-mcp-servers>
- **0-3** — Anthropic's official custom-connector documentation nowhere states that the MCP server URL must be publicly reachable by Anthropic's cloud, and it contains no mention of IP allowlists, firewalls, or private-network access — so whether 'private MCP behind Cloudflare Access without public exposure' works via the connector path is NOT settled by this primary source and requires empirical testing or another source.
  - source under test: <https://support.claude.com/en/articles/11503834-building-custom-connectors-via-remote-mcp-servers>

## Caveats (verbatim from the synthesis)

Coverage gaps: (1) Several requested competitor categories produced NO surviving verified claims — Coder/code-server, DevPod/Gitpod/devcontainers, Sunshine/Moonlight, AWS WorkSpaces/Windows 365, and Tailscale-based setups are absent from this synthesis; conclusions about the competitive field are therefore limited to Kasm Workspaces and Apache Guacamole. (2) Four of five requested moat-extension features (backup/restore, fleet management, GPU passthrough, WoL/idle-shutdown) have no verified findings, so the impact/effort ranking rests on observability alone plus judgment. (3) Q3a is only partially answered: verified clauses come from Anthropic's Consumer Terms and the Claude Code legal-and-compliance page; no clause specific to the Claude Desktop Linux beta or to VNC/tunnel exposure of the desktop app was found, and the individual-usage-limits sentence is textually scoped to Claude Code/Agent SDK. (4) Q3b's negative answer (no service-token/header path in the claude.ai connector UI) partly rests on GitHub issues and a help-center article rather than a definitive Anthropic statement, and an empirical test of a connector behind an Access-gated hostname was not performed; a related claim was refuted 0-3, suggesting connector-path privacy claims should be treated cautiously. Time-sensitivity: MCP tunnels are an explicitly discontinuable research preview, Anthropic's authentication policy was clarified as recently as Feb 2026 with active enforcement, and Kasm licensing/Cloudflare portal features can change — all Anthropic/Cloudflare findings should be rechecked before any release that depends on them. Refuted-claim hygiene: Kasm CE near-feature-parity and CE-ships-enterprise-features claims were refuted (0-3 each) and must not appear in downstream copy. Kasm's 5-session 'hard cap' enforcement mechanism (technical vs contractual) is unspecified in the license doc.

## Open questions

- Empirical: can a claude.ai custom connector actually complete registration and OAuth against an MCP server on a Cloudflare Access-gated hostname if the Access policy is configured to allow the claude.ai/api/mcp/auth_callback flow and Anthropic's server-side token exchange (e.g., via an Access bypass rule scoped to the OAuth endpoints)? No source settled this; a test deployment would.
- Do the Claude Desktop Linux beta's own terms or in-app EULA (shipped 2026-06-30) contain any clause about remote display, VNC/tunnel exposure, or shared-machine operation of the desktop app, beyond the general Consumer Terms account-sharing prohibition?
- What is the verified state of the art and solo-maintainer effort for the four unresearched moat features — encrypted whole-workstation backup/restore (restic/borg), multi-box fleet management from one CLI, GPU passthrough alongside a kasmVNC desktop, and wake-on-LAN/VPS idle-shutdown — and would any of them outrank observability on impact/effort?
- Will Anthropic graduate MCP tunnels to GA and/or extend them to claude.ai connectors (open request anthropics/claude-code#29486), which would invert this pass's conclusion that private MCP is stdio-only for desktop users?

## Sources fetched

- <https://docs.kasm.com/docs/latest/license/index.html>
- <https://kasm.com/community-edition>
- <https://guacamole.apache.org/doc/gug/guacamole-architecture.html>
- <https://guacamole.apache.org/doc/gug/configuring-guacamole.html>
- <https://symalon.com/en/kasm-workspaces-vs-apache-guacamole-a-comparison-of-open-source-remote-desktop-solutions/>
- <https://www.kasmweb.com/docs/develop/license.html>
- <https://tailscale.com/blog/tailscale-rustdesk-remote-desktop-access>
- <https://dev.to/thevenice/how-i-built-a-free-anydesk-alternative-using-sunshine-moonlight-tailscale-3lh8>
- <https://devopsboys.com/blog/coder-vs-gitpod-vs-devpod-cloud-dev-environments-review-2026>
- <https://www.vcluster.com/blog/comparing-coder-vs-codespaces-vs-gitpod-vs-devpod>
- <https://superrendersfarm.com/article/moonlight-parsec-rdp-remote-desktop-gpu-rendering-2026>
- <https://news.ycombinator.com/item?id=43439524>
- <https://botmonster.com/self-hosting/komodo-vs-portainer-vs-dockge-2026-homelab-decision-guide/>
- <https://homenode.tech/best-self-hosted-backup-tools-2026/>
- <https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor>
- <https://privacy.claude.com/en/articles/9264813-consumer-terms-of-service-updates>
- <https://code.claude.com/docs/en/legal-and-compliance>
- <https://www.anthropic.com/news/usage-policy-update>
- <https://support.claude.com/en/articles/11503834-building-custom-connectors-via-remote-mcp-servers>
- <https://platform.claude.com/docs/en/agents-and-tools/mcp-tunnels/overview>
- <https://github.com/anthropics/claude-ai-mcp/issues/410>
- <https://developers.cloudflare.com/cloudflare-one/access-controls/ai-controls/mcp-portals/>

## Run stats

```json
{
  "angles": 5,
  "sourcesFetched": 22,
  "claimsExtracted": 103,
  "claimsVerified": 25,
  "confirmed": 21,
  "killed": 4,
  "unverified": 0,
  "afterSynthesis": 10,
  "urlDupes": 0,
  "budgetDropped": 8,
  "agentCalls": 104
}
```

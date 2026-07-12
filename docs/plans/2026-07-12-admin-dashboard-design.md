# Coworkstation homepage + admin dashboard

Date: 2026-07-12
Status: designed; implementing v1 (monitoring-first)

## Problem

Two gaps surfaced once the branded gateway landed:

1. **Bridge access is a raw tokened URL** (`/bridge/?t=<32 chars>`) — bad
   UX; it should be reachable from the branded login like everything else.
2. **No admin surface.** The owner wants MDM/MAM-style visibility
   (sessions, usage, devices) and, later, management (enroll/remove
   members, control sessions) — today only via the `cws` CLI over SSH.

## Shape (decisions)

- **Homepage hub (not straight-to-Claude).** After the branded login,
  `/` serves a **homepage**; "Open Claude" navigates to `/session` (the
  kiosk). PWA `start_url` = the homepage. (Chosen over keeping Claude the
  immediate landing.)
- **Role = the box owner.** The primary/owner account is **admin**;
  members added via `cws member add` are regular users. Role is baked per
  gateway instance at setup (`CWS_GW_ROLE=admin|member`) and enforced
  **server-side**: a member's gateway never registers the admin routes,
  so hiding buttons is only cosmetic on top of real isolation.
- **v1 = monitoring-first, read-only.** Then tier **C** (safe session
  controls) then tier **B** (member add/remove) — additive, not a
  re-architecture.

## Architecture

### Entry + homepage (gateway)

- `/` (authed) → homepage (gateway-rendered, branded). Role injected +
  admin routes only registered when `CWS_GW_ROLE=admin`.
- `/session` → proxy the kasm client (the kiosk; keyboard param etc.).
- Buttons: **everyone** — Open Claude, Bridge; **admin** — Monitoring,
  Devices, Members.
- PWA `start_url` → `/`.

### Bridge integration (retire the token URL)

- **Bridge** button → `/bridge`, which the gateway proxies to the local
  bridge (127.0.0.1:8600) **gated by the login cookie**, injecting the
  bridge `t=` token server-side. The user never sees a token.
- Inside: folder-share + clipboard for all; **screen share
  feature-detected** (`navigator.mediaDevices.getDisplayMedia`) — shown
  only on desktop clients, hidden with a note on phones (mobile browsers
  have no screen-capture API — the `getDisplayMedia is not a function`
  wall).
- The separate `/bridge` tunnel path rule is **removed**; one origin, one
  cookie.

### Admin monitoring + the collector (the one privileged read)

Members' homes are `0700`, so the owner's unprivileged gateway cannot
read their data. One small privileged piece:

- **`cws-fleet-snapshot.timer`** (root systemd timer, ~20s) runs the read
  side of the fleet tooling and writes **`/run/coworkstation/fleet.json`**
  (`0640 root:<owner>`). Aggregates **sessions**, **usage**, **audit**,
  **devices** — the existing `cws sessions/usage/audit/devices`, which
  gain a `--json` mode so the collector concatenates rather than scrapes.
- The admin gateway **reads that file** and renders the views. No live
  root socket, no per-request shell-out; staleness bounded by the timer.
- Views (read-only v1): **Monitoring** (members × session/usage/last
  activity + recent-events feed), **Devices** (per-member inventory),
  **Members** (roster; Add/Remove land at tier B).

### Management path (tier C → B): the action channel

Mirror of the collector — the admin gateway **writes a request**, a root
helper executes it:

- **Spool, not a socket.** Gateway drops a request in
  `/run/coworkstation/actions/` (`0700`, owner-only). A root **systemd
  path unit** validates + executes + writes a result the gateway polls.
- **Allowlisted actions only** — a fixed id + validated params mapped to a
  specific `cws` call, passed as an **argv array** (no shell string):
  - **C:** `session.restart|stop|start` (named member), `reclaim`.
  - **B:** `member.add` (name/mem/cpu/allow), `member.remove`
    (`--keep-home`).
- **Guardrails:** destructive actions require in-UI confirm **+ password
  re-entry**; every action is written to the ops audit log (surfaces in
  Monitoring). Members can't reach the admin gateway or its spool.

`v1 ships none of the action channel` — it only reserves the contract.

## Security (defense in depth)

- Cookie (HMAC) gates the whole homepage (existing).
- Role server-side per gateway instance; member origins have no admin
  routes.
- Admin data behind file perms (`fleet.json` `0640 root:owner`).
- Mutations (C/B): allowlisted spool, argv arrays, param validators,
  confirm + re-auth for destructive, full audit trail.
- Bridge token injected server-side, never exposed.

## Testing

- **Node harness (gateway):** homepage renders per role; admin routes 404
  on a member-role gateway; `/bridge` proxied only with a valid cookie and
  with the token injected; monitoring reads a fixture `fleet.json`;
  `/session` proxies upstream.
- **BATS:** `cws … --json` shape; the collector snapshot writer; the
  snapshot/action systemd units emitted; `gateway_setup` sets the role.
- **Live:** owner login → homepage with admin buttons; `bob` login →
  homepage without them; Bridge opens with no token; Monitoring shows
  fleet data.

## Rollout

Additive. Gateway gains the homepage + `/session`; kiosk still reachable.
Deploy via `sudo cws update && sudo cws reconfigure`; retire the `/bridge`
tunnel path rule. v1 = homepage + role + bridge + monitoring + collector;
C then B follow.

## Out of scope (v1) / YAGNI

- The action channel / any mutation (reserved contract only).
- Multi-admin / per-member admin flags (admin = owner).
- Historical metrics/graphs (point-in-time snapshot only).
- Real-time push (poll the ~20s snapshot).

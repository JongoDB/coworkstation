# Coworkstation — engineering handoff

Read this first if you're a new assistant picking up this project. It's a
self-contained brief: what the thing is, how the live box is wired, the
conventions, everything already built, the gotchas that will bite you, and
what's planned. The repo itself is the source of truth — this points you at
the right parts of it.

---

## 1. What Coworkstation is

A single-appliance product that turns a Linux box into a **fleet of
remote, phone-first Claude Desktop workspaces**, reachable from any device
through a browser/PWA. Each user gets a Cloudflare-tunneled hostname; they
log in and land on a hub, and "Open Claude" drops them into a **full-screen
Claude Desktop** (kiosk) streamed over kasmVNC. The box is the *appliance*
that enables realtime sync (files/clipboard/screen) and cloud/Cowork
operations — it is deliberately **not** a general workspace/desktop.

The porcelain CLI is `cws`. Everything installs from a git checkout.

---

## 2. The live box + how to reach it

- **SSH:** `ssh cws@cws-ssh.fightingsmartcyber.com` (the owner's public key
  is installed; login is automatic — no password). This is the box owner
  account, `cws`.
- **OS / install:** Ubuntu 24.04. The repo is checked out at
  `/opt/coworkstation`; `/usr/local/bin/cws` and `cws-launch` symlink into
  it. Run privileged ops with `sudo cws …`.
- **Members:** owner `cws` (display `:1`) and member `bob` (`:2`). An extra
  per-device session for cws runs on `:50`.
- **Tunnel (Cloudflare, api mode):** hostnames →
  - `cws.fightingsmartcyber.com` → owner session
  - `bob-cws.fightingsmartcyber.com` → bob
  - `cws-s50-cws.fightingsmartcyber.com` → cws's `:50` device session
  - Cloudflare **Access gates are currently OFF** (the gateway's own login
    is the gate). Tunnel config lives in `/etc/coworkstation/tunnel.conf`
    (+ token); ingress is managed via the Cloudflare API (`lib/tunnel-api.sh`).
- **Credentials:** get a user's kasmVNC gate password with
  `sudo cws credentials <user>`. **Do not commit passwords.** The owner is
  currently signed into Claude on `:1`.
- **Ports (all loopback; the tunnel fronts them):** kasm `8443` (cws `:1`),
  `8444` (bob), `8492` (`:50`); **gateway** `8700+display` (8701 cws, 8702
  bob); **bridge** `8600+display`; fleet snapshot `/run/coworkstation/fleet.json`;
  action spool `/run/coworkstation/actions/`.
- **Drive the real browser** for client-side testing via the
  claude-in-chrome extension (Playwright couldn't carry Basic auth onto the
  kasm WebSocket). Screenshot server-side with `scrot` under `DISPLAY=:N
  XAUTHORITY=/home/<user>/.Xauthority` (installed: `scrot`, `xdotool`,
  `wmctrl`, `xvfb`).

### Current deployed state (2026-07-12)

`/etc/coworkstation/appliance.conf`: `profile=kasmvnc`, `kiosk=1`,
`owner=cws`, plus `hostname=`. Live and verified:

- **Kiosk mode on** — every session boots into full-screen Claude (no
  XFCE), with a supervisor that recycles Claude if it's closed/hidden.
- **Claude Desktop 1.19367.0**, auto-updating (unattended-upgrades
  allow-lists Anthropic's apt origin).
- **Keyring works** — `--password-store=gnome-libsecret` on shared-bus
  sessions (the 1.19367 build fixed Electron `safeStorage`); the "sign-in
  won't be saved" warning is gone and sign-in persists encrypted. Extra
  `:50+` sessions stay on `basic` (private bus, no working secret service).
- **Branded gateway** fronts all hostnames: login → `/home` hub → Open
  Claude / Bridge / (owner only) Admin. Bridge is cookie-gated (no token
  URL). Admin dashboard tiers **A/C/B** all shipped (monitoring, session
  controls, member add/remove) via a validated action channel.

---

## 3. Architecture map (key files)

| Area | Files |
|---|---|
| CLI porcelain | `cws` (dispatch, menu, `cws kiosk on/off/status`, credentials, client) |
| Provisioning | `setup.sh` (modes: setup / doctor / reconfigure), `member.sh` (add/remove) |
| kasm profile / kiosk | `lib/profiles/kasmvnc.sh` — cert, yaml, **`kasmvnc_xstartup`** (kiosk supervisor + no-strand recycle + `:50` dbus split), kiosk deps (matchbox/xdotool/x11-xserver-utils/browser), default-browser install |
| Claude launch guardian | `libexec/cws-launch` — store flag (`resolve_store_flag`), config-backup rotation, stale-singleton clearing, optional `--force-device-scale-factor` |
| Gateway (the front door) | `gateway/server.js` — cookie login, `/home` hub, `/session`→kasm proxy (Basic injected, **case-sensitive `Authorization`**), `/bridge` proxy (token injected), `/admin` + `/api/fleet` + `/api/action` (role-gated), WS splicing; `gateway/www/*` (login/home/admin html+js, manifest, sw, icons) |
| Gateway provisioning | `lib/gateway.sh` — port math, unit env (role/bridge/fleet/actions), `gateway_route on/off`, tunnel reroute, **fleet collector** units, **action channel** units + tmpfiles |
| Admin monitoring (root) | `libexec/cws-fleet-snapshot` → `/run/coworkstation/fleet.json` (0640 root:owner), on a ~20s systemd timer |
| Admin actions (root) | `libexec/cws-action-exec` — allowlisted, argv-array, param-validated executor, triggered by a systemd `.path` watching the spool |
| Client bridge | `bridge/server.js` (folder-share + desktop screen-share; clipboard removed), `lib/clientbridge.sh`, `bridge/client-screen-mcp.js` |
| Fleet / tunnel / common | `lib/fleet.sh` (sessions/usage/audit/devices), `lib/tunnel-api.sh` (Cloudflare API + `ingress_json_*`), `lib/common.sh`, `lib/session.sh` (extra `:50+` sessions) |
| Tests | `tests/*.bats`, `tests/helpers/gateway-test.js` + `bridge-test.js` (live node harnesses) |
| Designs | `docs/plans/2026-07-06-session-keyring-design.md`, `…-07-12-immersive-claude-kiosk-design.md`, `…-07-12-admin-dashboard-design.md`; history in `CHANGELOG.md` |

### Request flow (kiosk, per session)

`Cloudflare tunnel → gateway (loopback :870N)`. The gateway: serves the
branded login, gates on a signed (HMAC) cookie, serves `/home` + `/admin`,
proxies `/bridge*` to the bridge (token injected) and everything else to
kasm (`Authorization: Basic` injected — kasm is Basic-only and matches the
header name **case-sensitively**). Inside kasm, `kasmvnc_xstartup` runs
`matchbox-window-manager` + a supervisor loop that launches Claude via
`cws-launch` and **recycles it if the screen goes blank** (close-to-tray
would otherwise strand the user; detection is `xdotool search --pid` —
`--class` does NOT match Claude's main window, and matchbox doesn't
populate `_NET_CLIENT_LIST` so wmctrl/EWMH is useless).

---

## 4. Conventions & workflow

- **Tests are the gate.** `shellcheck -x` all shell + `bats` all `tests/*.bats`
  + `node --check` the JS. The live node harnesses (`gateway-test.js`,
  `bridge-test.js`) run under a `live:` bats test (skip if no node). CI:
  `.github/workflows/tests.yml` (+ `release.yml`).
- **Run bats on Linux.** On macOS, ~2–3 tests fail locally on BSD `date +%N`
  (`rotate_backup`) and `stat -c` (`setup_cert`/`setup_auth`) — **expected,
  they pass on Linux CI**. Use `docker run --rm -v "$PWD":/repo -w /repo
  ubuntu:24.04 …` if you need a clean run (apt can be slow under emulation).
- **Deploy loop:** commit → `git push` → on the box `sudo cws update`
  (git pull) → `sudo cws reconfigure` (re-applies idempotent config:
  polkit, xstartup, gateways with role, collector, action channel) →
  restart the affected services (`systemctl --user restart
  cws-gateway.service` / `cws-bridge.service`; `kasmvnc.service` /
  `kasmvnc-s50.service` to pick up a new xstartup). `sudo cws kiosk on/off`
  flips kiosk box-wide and reconfigures.
- **Commit author must be the noreply email** or the push is rejected with
  GH007: `git config user.email "198221045+JongoDB@users.noreply.github.com"`
  (name `JongoDB`). End commit messages with the `Co-Authored-By` /
  `Claude-Session` trailers already in the git log.
- **Autonomy:** the owner has granted deploy/merge/build without asking each
  step. Hard limits still hold: never type passwords/credentials into
  fields (the owner does that), no force-push / history-rewrite on `main`
  without explicit OK, confirm outward-facing/irreversible actions (tunnel
  re-routes were done live but announced).

---

## 5. What's already built (this is done — don't redo it)

In rough order; see `CHANGELOG.md` for detail.

1. **Kiosk mode** — matchbox + supervised Claude replacing XFCE; `:50+`
   private-bus isolation; no-strand recycle on close/minimize;
   `cws kiosk on/off/status`.
2. **Dynamic resolution** — kasm remote-resize already tracks the client
   viewport (→ Claude's mobile layout at phone width, no code). Opt-in
   `CWS_DEVICE_SCALE` HiDPI knob (NOT auto-applied — see gotchas).
3. **Default browser for OAuth** — Chrome (amd64)/Chromium installed + set
   default so "Continue with Google" works; `claude://` handler closes the
   loop.
4. **Auto-updates** — unattended-upgrades tracks Anthropic's Claude apt repo.
5. **Keyring / safeStorage fix** — 1.19367 build uses the OS keyring;
   `cws-launch` uses `gnome-libsecret` on shared-bus sessions → warning
   gone, encrypted persistent sign-in, and Cowork's device bridge unblocked.
6. **Branded gateway + PWA** — cookie login (kasm is Basic-only, no themeable
   page), CWS logo/icons, service worker; `/home` hub; role-gated admin;
   bridge fronted with token injection (no token URL); tunnel `/bridge`
   path rule retired.
7. **Admin dashboard A→C→B** — Monitoring/Devices/Members tabs; session
   Restart/Stop + Reclaim; member Add/Remove (password re-auth, owner
   protected); root fleet-snapshot collector; allowlisted, param-validated,
   audited action channel (`cws-action-exec`).
8. **Security hardening** — `member.add` allow-list validated against argv
   flag-smuggling at both gateway and executor.

---

## 6. Gotchas that will bite you

- **kasmVNC is HTTP Basic-auth only** (realm "Websockify"); there is no
  themeable login page. The `Authorization` header is matched
  **case-sensitively** (capital `A`) — inject it capitalized.
- **Claude's window:** `xdotool --class` does NOT match its main content
  window (only tiny helpers); use `--pid`. matchbox doesn't fill
  `_NET_CLIENT_LIST`, so `wmctrl`/EWMH returns nothing.
- **Mobile browsers can't:** `getDisplayMedia` (screen capture) — screen
  share is desktop-only; File System Access API (folder sync) — desktop
  Chrome/Edge only. On phones the file path is upload-a-file. This is a
  hard wall, not our bug.
- **HiDPI:** the login shim captures `devicePixelRatio` but `cws-launch`
  does **not** auto-apply it — over kasm's CSS-px framebuffer,
  `--force-device-scale-factor` shrinks the logical viewport (414→138) and
  breaks the layout. It's a manual env knob until framebuffers are device-px.
- **Bridge screen-share round-trip** works server-side now (safeStorage
  fixed), but the *client* still needs a desktop browser to capture.
- **`/run` is tmpfs** — the fleet.json dir and action spool are recreated
  by the collector service / a `tmpfiles.d` entry at boot.
- **macOS test failures** (date/stat) are expected locally; **GH007** on
  push if the author isn't the noreply email; **force-push to main** and
  **SSH username enumeration** are classifier-blocked.

---

## 7. Planned / open work

- **scrcpy over wireless ADB (Android screen share + control)** — proposed,
  not started. The box captures (and can control) the paired Android phone,
  no app install; feeds Claude's device tools. Owner asked for it; needs a
  brainstorm on the pairing UX first. iOS would need a native ReplayKit
  extension (deferred).
- **Enrich the fleet snapshot** — `cws-fleet-snapshot` currently reports the
  roster + live session state reliably; `usageTokens`/`devices`/`audit` are
  placeholders. Add `--json` output to `cws usage/devices/audit` (fleet.sh)
  and fold it into the collector.
- **Dashboard polish** — the Members tab's Add/Remove use blocking
  `confirm()`/`prompt()`; could become in-page modals. member.add can be
  slow (full provisioning) — the gateway polls ~60s then returns "still
  running."
- **Dead code** — the bridge's `/bridge/clipboard` endpoints remain after
  the UI was removed; harmless, can be pruned.
- **Upstream watch** — the keyring path is restored; if a future Claude
  build regresses `safeStorage`, revert `resolve_store_flag` to `basic`
  (tracked at JongoDB/coworkstation#12).

---

## 8. First moves for the new assistant

1. `git clone` / open the repo; read `CHANGELOG.md` and the three
   `docs/plans/*.md` designs.
2. `ssh cws@cws-ssh.fightingsmartcyber.com`; `sudo cat
   /etc/coworkstation/appliance.conf`; `cws sessions`, `cws devices`.
3. Confirm green tests before changing anything (Linux/CI or docker).
4. Make changes TDD-first, deploy via the loop in §4, verify on the box.
5. For the phone experience, drive the real browser (claude-in-chrome) at a
   phone viewport and screenshot; the owner does any password entry.

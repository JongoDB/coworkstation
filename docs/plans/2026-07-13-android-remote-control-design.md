# Android remote control — Claude drives a paired phone (`cws phone`)

**Status:** design. Architecture chosen and on-device-validated on a Samsung
Galaxy S21 Ultra (Android 15 / One UI); **one gate remains before
implementation** — the 48–72 h Doze idle soak (see §9). Fallback path
identified if it fails.

**One line:** give a headless Claude on the box the ability to **see and
control a paired Android phone over the internet** — screenshot + tap / swipe /
type / keys + file access — with **no root** and the phone **anywhere** (not on
the box's LAN), by driving the phone-side **mobilerun Portal** app's local HTTP
API across a **self-hosted mesh VPN**, exposed to Cowork through the same
device-tools path as `cws client screenshot`.

---

## 1. Goal & scope

Coworkstation is a fleet of phone-first Claude Desktop workspaces. This feature
inverts the usual relationship: instead of the phone being a *client that views
Claude*, the phone becomes a *device Claude drives*. The owner asked for
"screenshare, local Android filesystem access, phone control" from a Cowork
task, working **from anywhere**, not just the same Wi-Fi.

In scope (v1):
- **Claude-driven** control: screenshot, tap, swipe, text (Unicode), key events
  (BACK/HOME/RECENTS), and the accessibility tree for semantic targeting.
- **File access** phone⇄box over the internet (via Syncthing, already shipped).
- Works when the box **cannot** reach the phone's IP directly (cellular / CGNAT).
- No root. One-time provisioning may use adb; **runtime uses no adb**.

Out of scope (v1): iOS (needs a Mac/WebDriverAgent leg — deferred); a human
live-view/takeover UI (droidVNC-NG can add this later — see §9); reaching other
apps' private storage (impossible without root — see §8).

## 2. Non-goals / hard limits (set expectations honestly)

- **No-root filesystem ceiling.** Reachable: the phone's **shared storage**
  (Download, DCIM, Documents, media, user folders). **Never** other apps'
  `Android/data`/`Android/obb` or the system FS. If the wanted data lives in
  another app's private dir, no root-free tool can reach it.
- **Accessibility input limits.** All no-root control rides Android's
  AccessibilityService: it **cannot touch the secure lock screen** (a reboot may
  need one human unlock), and `FLAG_SECURE` screens capture black.
- **Text needs a focused field.** `keyboard/input` uses the a11y `ACTION_SET_TEXT`
  fallback unless the Mobilerun IME is selected; with no editable field focused
  it fails (expected — Claude focuses a field first).

## 3. Chosen architecture (three independent layers)

```
PHONE:  [ cloudflared (Termux) ]  +  [ mobilerun Portal (a11y svc + local HTTP :8080) ]  +  [ Syncthing-Fork ]
BOX:    [ Cloudflare Tunnel ]  →  cws phone {screenshot|tap|text|key|swipe|status|tree}  +  [ Syncthing ]
                     │  curl https://phone-<user>.<zone>/... -H "Bearer <token>"  (+ CF Access svc-token)
                     └─ Claude runs these via Cowork's device_bash  (mirrors `cws client screenshot`)
```

**Why mobilerun Portal** (over droidVNC-NG / adb / RustDesk): purpose-built for
AI agents (accessibility tree + screenshots), MIT-licensed app (AGPL since
v0.7.18 — we ship it **unmodified**), binds `0.0.0.0` so it's reachable over the
mesh **with no adb at runtime and no wireless-debugging "reboot wall"**, uses
AccessibilityService `takeScreenshot()` on Android 11+ (no MediaProjection
consent), and is driven by plain `curl`→JSON. Full comparison and the rejected
options are in the research trail; `docs/HANDOFF.md` §7 tracked the original
(dropped) scrcpy/wireless-ADB idea.

**Why Cloudflare Tunnel for transport:** the agent-drivable control paths all need
the box to reach a port on the phone; over CGNAT that needs an outbound-originated
tunnel. Cloudflare Tunnel reuses the appliance's existing stack (§4.2) instead of a
separate mesh. Files are the exception — Syncthing brings its own relay,
independent of the tunnel.

## 4. Components

### 4.1 Phone side (provisioned once)
- **mobilerun Portal APK** (pinned version, unmodified; sideloaded). Enables:
  the AccessibilityService (`com.mobilerun.portal/.service.MobilerunAccessibilityService`)
  and the local HTTP socket server on `:8080`.
- **Mobilerun Keyboard (IME)** selected — for robust Unicode text into any field.
- **Termux + `cloudflared`** (see §4.2, §6) — originates the Cloudflare Tunnel
  exposing Portal `:8080` to the box; auto-started at boot via **Termux:Boot**.
- **Syncthing-Fork** (Catfriend1) — two-way file sync of shared storage; the
  original Syncthing-Android app was discontinued (Oct 2024).

### 4.2 Transport — Cloudflare Tunnel (decided; reuses the appliance's stack)
The appliance is already Cloudflare-fronted and manages ingress via the
Cloudflare API (`lib/tunnel-api.sh`). We reuse it rather than run a separate mesh:
- The **phone runs `cloudflared`** (in **Termux**) originating a named tunnel that
  exposes its local Portal `:8080`. Outbound-only from the phone → works over
  CGNAT/cellular with no LAN and no mesh control plane to operate.
- The box manages the phone's tunnel + ingress + DNS via the Cloudflare API it
  already speaks; `cws phone` targets the phone's Cloudflare hostname
  (e.g. `phone-<user>.<zone>`), gated by a **Cloudflare Access service token**
  (only the box holds it) **plus** the Portal bearer token — defence in depth.
- **Honest tradeoff:** `cloudflared` is a **second phone-side background process**
  (Portal is the first) running in **Termux**, which One UI kills more eagerly
  than a proper app. It needs **Termux:Boot** + the same battery exemptions as
  Portal, and its unattended survival is now part of the spike gate (§8). If it
  proves flaky under Doze, the fallback *for this leg only* is a proper mesh-VPN
  app (Netbird/Tailscale); the rest of the design is unchanged. A cleaner future
  option that drops Termux entirely: point Portal's built-in **"Connect to Host"**
  (reverse WebSocket) at a self-hosted endpoint behind the box's tunnel —
  deferred (needs a mobilerun-protocol-compatible server).

### 4.3 Box side — `cws phone` porcelain
- A CLI (following the `cws client` pattern) that `curl`s the phone's Portal API.
  Per-user config `~/.config/cws-phone/{endpoint,token}` (`0600`), like the
  bridge token. No box-side server process — the box is a *client* of the
  phone's Portal (simpler than `bridge/`).
- A lightweight **health check** (`cws phone status` / a systemd `--user` timer)
  that pings `/ping` and surfaces "phone unreachable" (for the fleet snapshot /
  admin dashboard later).

### 4.4 Device-tools integration (how Claude uses it)
- Cowork surfaces **`device_bash` + `device_stage_files`**, not local MCP tools
  (documented in `lib/clientbridge.sh`). So Claude runs `cws phone screenshot
  ~/phone.png` via `device_bash`, then stages/views it — **exactly** the working
  `cws client screenshot` pattern. No new model plumbing needed.
- Optional later: a `phone-screen-mcp.js` mirroring `bridge/client-screen-mcp.js`
  for non-Cowork surfaces.

## 5. `cws phone` command surface (maps 1:1 to Portal endpoints)

| Command | Portal call | Notes |
|---|---|---|
| `cws phone screenshot [FILE]` | `GET /screenshot?hideOverlay=false` | returns **base64 PNG in JSON** (`{"status":"success","result":"<b64>"}`) — decode to `FILE` |
| `cws phone tree` | `GET /a11y_tree` | semantic element list w/ bounds — for targeting |
| `cws phone tap X Y` | `POST /tap x= y=` | |
| `cws phone swipe X1 Y1 X2 Y2 [MS]` | `POST /swipe startX= startY= endX= endY= duration=` | |
| `cws phone text "…"` | `POST /keyboard/input base64_text=<b64>` | base64-encode; needs a focused field (§2) |
| `cws phone key BACK\|HOME\|RECENTS` | `POST /keyboard/key key_code=` / global action | |
| `cws phone status` | `GET /ping` (+ `/state`) | liveness / health |
| `cws phone app <pkg>` | `POST /app package=` | launch app |
| `cws phone pair` | provisioning (adb, one-time) | see §7 |

All authenticated with `Authorization: Bearer <token>`; **logical errors return
HTTP 200 with `status:error`** in the body, so the CLI parses the body, not just
the code.

## 6. Provisioning / pairing UX (`cws phone pair`)

The handoff flagged "pairing UX" as the thing to design. It **dissolved** from the
old wireless-debugging pairing-code dance into: *install a few apps, grant one
permission, enroll in the mesh.* One helper wraps it (adb once; then no adb):

1. `adb install` the pinned Portal APK (`-g` grants runtime perms).
2. Enable the a11y service (bypasses the Android-15 "restricted settings" gate):
   `adb shell settings put secure enabled_accessibility_services <component>`.
3. **Enable the HTTP server headlessly** (the one non-obvious command — verified
   on-device; it is `content insert` with a bound boolean, **not** query/call):
   `adb shell content insert --uri content://com.mobilerun.portal/toggle_socket_server --bind enabled:b:true --bind port:i:8080`
4. Fetch the stable bearer token:
   `adb shell content query --uri content://com.mobilerun.portal/auth_token` (a
   persisted UUID — fetch once, holds across reboot).
5. Select the Mobilerun IME (robust text); apply the **One UI hardening**
   (Unrestricted battery · Never-sleeping app · turn **off** "Pause app activity
   if unused" · Keep Screen Awake) — the settings that keep the service alive.
6. Install **Termux + `cloudflared`**; run a named tunnel exposing
   `localhost:8080` (token-based, auto-start via Termux:Boot). The box creates the
   tunnel route + DNS + Access service-token via the Cloudflare API, then stores
   the phone's **hostname + Portal token + service token** in `~/.config/cws-phone`.
7. Install/point **Syncthing-Fork** at the box's Syncthing for files.

Phone footprint: **3 apps** — Portal, Termux (running `cloudflared`), Syncthing —
plus the Portal IME and a handful of one-time toggles. On mobile the on-phone taps
are the owner's (we never type into their phone).

## 7. Security posture

- The control channel is a bearer-token HTTP server on the phone; **the mesh is
  the real isolation boundary** (WireGuard-class encryption, private overlay).
  Bind `cws phone` to the mesh IP; don't expose the phone's `:8080` to its LAN.
- The token is a persisted UUID stored `0600` on the box, mirroring the bridge
  token model. Portal's ContentProvider is `exported` (any on-device app can read
  the token) — acceptable for a **dedicated** appliance phone; note it.
- Ship the Portal APK **unmodified** (AGPL-3.0) → `cws` is unaffected; pin the
  version + record its sha256.

## 8. What we proved (spike, 2026-07-13) & what remains

Validated live on the S21 Ultra / Android 15 / One UI, over **wireless adb** for
provisioning and **wifi** for the API:
- Headless enable, token fetch, and the full API suite **green over the LAN**
  (ping, screenshot, a11y_tree, tap, swipe, key, Unicode text), ~0.4–3 s
  screenshot latency (varies with QHD frame size).
- **Reboot survival — best case:** after a **cold reboot** the Portal
  auto-started and answered over wifi **pre-unlock, with zero interaction** — the
  biggest feasibility risk (unattended persistence on an aggressive OEM) cleared.

**Remaining gate:** the **48–72 h Doze idle soak** (`portalspike.sh retest`). If
it survives One UI deep-sleep, we implement. **If it fails:** mitigate with a
box-side watchdog (health-check + a re-arm), or fall back to **droidVNC-NG**
(mature VNC-server-on-phone, driven by a headless VNC client) which also throws
off a free human live-view for the immersive-kiosk story.

**Transport not yet tested.** The spike proved the Portal over the **LAN**; the
chosen **Cloudflare Tunnel** path (cloudflared-in-Termux) is unvalidated. Add a
Stage-2 to the spike: cloudflared survives reboot+Doze in Termux, and the box
reaches the Portal through the phone's Cloudflare hostname end-to-end. This is the
second thing to clear before implementation.

## 9. Testing

- **BATS + shellcheck** for the `cws phone` porcelain: arg parsing, config r/w
  (`0600`), endpoint/token resolution, base64 encode of text, base64 **decode**
  of screenshots, error-body parsing (HTTP 200 + `status:error`). Mock `curl`.
- A `live:` node/bash harness (skipped without a device) that drives a real
  Portal, mirroring `tests/helpers/*-test.js`.
- Provisioning (`cws phone pair`) asserts the exact adb commands are emitted
  (the `content insert` enable, the a11y component), like other `*.bats`.

## 10. Gotchas (learned the hard way — bake into code & docs)

- **Enable = `content insert --bind enabled:b:true`** (query/call no-op).
- **Screenshots are base64-in-JSON**, not raw PNG — decode with a real JSON
  parser, not `sed` (BSD sed chokes on multi-MB single-line base64).
- **Text needs a focused field / the Mobilerun IME**; downgrade a bare
  text-without-focus failure to a warning, not an error.
- **Wireless adb drops on reboot** → reboot survival must be checked by polling
  the Portal over wifi, not via adb.
- **One UI battery hardening is load-bearing** — without it the service dies.
- Latency scales with screen resolution; consider a capture-scale param later.

## 11. Deploy / integration path

Follows the standard loop (`docs/HANDOFF.md` §4): `cws phone` lives in `lib/` +
the `cws` dispatcher; provisioning helpers in `libexec/`; per-user config +
optional health-timer via a `phone.sh` provisioner; tests gate green; deploy via
`sudo cws update` + `reconfigure`. The mesh is a new box-side dependency
(install + a systemd unit).

## 12. Open questions

- **Transport: Cloudflare Tunnel (decided).** Reuses the appliance's existing
  Cloudflare stack; no separate mesh to operate. **Watch item:** the phone-side
  `cloudflared`/Termux persistence under One UI Doze — validate in the soak
  (§8); a mesh-VPN app is the fallback for that leg only.
- **Multi-phone / multi-user**: v1 targets one companion phone; the config layout
  (`~/.config/cws-phone/`) leaves room per user.
- **iOS**: deferred (Mac/WebDriverAgent leg; the accessibility-app model does not
  translate to stock iOS).

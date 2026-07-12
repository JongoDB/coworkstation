# Immersive Claude-only kiosk (phone/tablet-first)

Date: 2026-07-12
Status: designed; three de-risk spikes pending before implementation

## Problem

Today the box boots into a full XFCE desktop and autostarts Claude
Desktop inside it. The desktop chrome is dead weight: the container is
the *appliance* that syncs the client device with Claude, not a
workspace. On a phone — where a member can already reach the mirrored
session — the desktop is cramped and un-native.

## Goal

Boot straight into **one fullscreen Claude Desktop**, sized and shaped
for the client device, delivered as an installable web app. The target
is **mobile/tablet-first**: Android and iOS phones, plus iPadOS and
Android tablets. The felt experience: open the app (or the home-screen
icon) → one login → land in a screen-fitted, signed-in Claude, as close
to a native Claude app as possible without one existing.

Two facts make this achievable now:

- Claude Desktop renders `claude.ai`, which is **mobile-responsive** —
  at a phone-width viewport it reflows to the mobile layout instead of a
  shrunken desktop UI. (Linchpin; spike #1.)
- The box's Claude sign-in **persists in the profile** across restarts
  (observed surviving every reboot), so "one login → already-signed-in
  Claude" needs no per-session account sign-in.

## Scope decisions

- **Client:** mobile/tablet-first (Android/iOS phones; iPadOS/Android
  tablets). Laptops still work — Claude's responsive layout simply
  widens to fill them inside the same kiosk.
- **Front door:** a branded login *page* (cookie session), not the
  HTTP Basic-auth dialog. The dialog is the un-seamless bit and fights a
  standalone PWA.
- **Kiosk always:** every session boots into fullscreen Claude on every
  client — no XFCE. Matches "appliance, not workspace." Admin access
  stays via SSH; there is no in-session desktop escape hatch.

## Architecture

Five pieces. Four are buildable now; screenshare is blocked upstream.
None of the hard-won guardian/bridge fixes are touched — we add a kiosk
*host* and a phone-shaped *front door* around the same Claude, the same
`cws-launch` guardian, and the same bridge that already work.

### 1. Kiosk session

Lives in `kasmvnc_xstartup()` (`lib/profiles/kasmvnc.sh`) — the
function PR #1 already branches on session number. Replace the
`exec startxfce4` tail with three things:

1. **A minimal window manager: `matchbox-window-manager`.** Purpose-built
   for single-app kiosks — force-fullscreens the top-level window, no
   title bars, taskbar, or desktop. Openbox is the fallback if matchbox
   misbehaves with Electron. A no-WM setup is rejected: Electron menus
   and dialogs need a WM to place them.
2. **A supervisor loop for Claude.** XFCE currently both keeps the
   session alive and fires the `~/.config/autostart` entry that launches
   Claude. Without XFCE both jobs fall to the xstartup:
   `while true; do (cws-launch); sleep 2; done`. `cws-launch` still execs
   Claude with all guarding intact; on exit the loop relaunches (the
   next pass's singleton-clearing handles the stale lock) — no
   black-screen-on-crash. The autostart `.desktop` becomes redundant
   under kiosk (matchbox does not process XDG autostart); we drive the
   launch from here so it cannot double-fire.
3. **A branded backdrop** (`xsetroot`/solid fill) so any letterboxing
   around Claude is brand color, not desktop gray.

Preserved as-is: the `dnum<50` vs `:50+` D-Bus split (matchbox under
`dbus-run-session` for extra sessions, shared bus otherwise), plus every
guardian behavior (config backup, singleton-clearing,
`--password-store=basic`).

### 2. Dynamic resolution (linchpin)

kasmVNC already supports **remote resizing** — the client reports its
viewport and the server resizes the X screen (RANDR `SetDesktopSize`).
The kiosk forces Remote Resizing as the default (in the kasm client
config, or pinned via URL param on the login redirect) so the phone
viewport drives server resolution and the user never opens a settings
menu.

**Tension:** Claude's mobile layout triggers under ~768 CSS px. Electron
on Linux maps CSS px to X pixels 1:1, so a 390-px-wide X screen gives
the mobile layout but a 390-px framebuffer that upscales soft on a 2–3×
DPR phone.

**Fix — decouple the two:** size the X framebuffer to the phone's
*device* pixels (e.g. ~1170×2532) for crispness, and launch Claude with
`--force-device-scale-factor` set to the client DPR so its *logical*
viewport stays phone-sized (~390 wide → mobile layout) while rendering
at high DPI. The login page/PWA reads `window.devicePixelRatio` and
forwards it.

**Measured on box (2026-07-12).** Read-only telemetry from a live,
authenticated kasm session confirmed the mechanism: the server X
framebuffer (`1920×932`) **exactly equals** the browser's CSS viewport
(`innerWidth×innerHeight`) at DPR 1. So:

- **Remote resize already tracks the client viewport by default** — a
  phone reporting a 390-wide viewport gets a 390-wide X screen → Claude
  renders its mobile layout. **No resolution code is needed for the core
  phone-optimized layout.**
- kasm sizes the framebuffer in **CSS px, ignoring DPR**, so on a retina
  phone the 390-px framebuffer upscales soft. True crispness needs the
  framebuffer at device px *and* `--force-device-scale-factor=DPR`.

**Decision — DPR crispness is an opt-in knob, not core.** The
scale-factor is fixed at Claude launch, but a persistent session can be
reached by clients of different DPR (phone DPR 3, laptop DPR 1), so no
single value is universally right. Rather than relaunch Claude per
connection, `cws-launch` gained an **optional** `--force-device-scale-factor`
driven by `CWS_DEVICE_SCALE` or a `device-scale` file in the session's
config home (default unset = today's working behavior). The login shim
(§3) can record `window.devicePixelRatio` there for a phone/tablet-first
session. Making the framebuffer itself device-px (a client-side kasm
tweak) is deferred until measured on a real phone.

### 3. Branded login page + PWA

**Verified on box (spike #3, 2026-07-12):** the kasm gate is **raw HTTP
Basic auth** — each display's Xvnc httpd (ports 8443/8444/8492) answers
`WWW-Authenticate: Basic realm="Websockify"`, backed by `~/.kasmpasswd`.
There is **no built-in cookie login page to theme**. So the branded
front door takes the **fallback branch**: a thin auth-proxy shim.

**Approach — auth-proxy shim.** A small reverse proxy sits in front of
the per-display kasm httpd and:
- serves `/login` (branded static page) + the PWA assets unauthenticated;
- on `POST /login`, validates the submitted password by attempting the
  upstream kasm auth, then sets a signed HttpOnly session cookie;
- for the kasm client + `websockify` WebSocket, requires the cookie and
  injects `Authorization: Basic` upstream (kasm demands Basic, and
  `.kasmpasswd` stores only a hash, so the shim holds the plaintext in a
  server-side session keyed by the cookie — same secret already in use).

This is the "separate auth microservice" the first draft listed as
out-of-scope; spike #3 moved it **in** scope. Keep it minimal (one small
service, e.g. Caddy/Go/Node) and per-box. It also hosts the PWA assets,
so there is no need to write into kasm's root.

**Why cookie-based:** a standalone PWA + Basic auth is exactly the
clunky combo we are removing. A cookie set by the login form persists in
the PWA's standalone context — log in once, re-launch straight into the
session. The login page also forwards DPR (see §2).

**Why cookie-based:** a standalone PWA + Basic auth is exactly the
clunky combo we are removing. A cookie set by the login form persists in
the PWA's standalone context — log in once, re-launch straight into the
session. The login page also forwards DPR (see §2).

**PWA assets** served by the shim:
- `manifest.json` — `display: standalone`, `orientation: any` (so iPad
  landscape works; phones stay portrait by how they're held), maskable
  192/512 icons, `theme_color`, `start_url` = kiosk.
- A **minimal** service worker — enough for installability: cache the
  login shell + icons, offline splash. It does **not** cache the live
  VNC WebSocket.
- iOS/iPadOS extras — `apple-touch-icon`,
  `apple-mobile-web-app-capable`, status-bar meta, and a one-time
  "Share → Add to Home Screen" hint (Safari has no install prompt).
  Android gets a real Install button via `beforeinstallprompt`.

### 4. Touch & keyboard input (per device class)

**Touch:** kasmVNC translates touch to pointer events — tap = click,
drag = scroll, two-finger = right-click/scroll. Claude receives these as
mouse/wheel events, so scrolling is kasm's drag-to-scroll rather than
native inertial scroll — usable, tunable via kasm gesture settings.

**Soft keyboard — the honest weak point.** VNC sees only pixels, so
tapping a text field cannot *auto*-summon the native keyboard. The
standard fix (kasmVNC supports it): a keyboard button focuses a hidden
input → the native keyboard appears → keystrokes forward to Claude. The
**clipboard bridge** is the heavy-text escape hatch (compose natively,
paste in).

**Spike #2 — confirmed on a live Android phone (2026-07-12).** The
mechanism is kasmVNC's **Settings → "Show Virtual Keyboard Control"**,
which reveals a keyboard button (lower-right) that raises the native
keyboard. It works but is **off by default** and the button is a small,
finnicky tap target. Since the gateway serves the client, the kiosk must:
1. **default that setting on** (ship the kasm client config / localStorage
   preset with the virtual-keyboard control enabled), and
2. **enlarge/reposition the button** into a comfortable tap target
   (client CSS override served by the gateway).
Tracked as a gateway client-config task.

**Browser for OAuth (found live, fixed).** Separately, Claude's
"Continue with Google" opens the system browser for the OAuth handoff;
the appliance shipped none, so sign-in failed with "Failed to execute
default Web Browser." Kiosk setup now installs a default browser
(Chrome/Chromium) and sets the per-user xdg default; the `claude://`
handler closes the loop back into the app. (See CHANGELOG.)

**Device-class handling (one adaptive PWA):**
- **Phone (Android/iOS):** narrow viewport → Claude mobile layout;
  DPR 2–3 → `--force-device-scale-factor`; portrait.
- **Tablet (iPadOS/Android):** wider viewport → Claude's roomier
  layout (better on a tablet); DPR 2; landscape **and** portrait.
- **iPadOS caveat:** Safari defaults to desktop-class browsing (desktop
  UA, large viewport), so iPad naturally lands on the wide layout, and
  add-to-home PWA works like iOS. DPR passthrough still applies.

### 5. Bridge on mobile/tablet + screenshare

- **Clipboard — works, matters more here.** Copy/paste between client
  and Claude keeps working and becomes the primary heavy-text path on
  mobile. Caveat: mobile browsers gate `navigator.clipboard` behind a
  user gesture and permission (iOS Safari strict), so we keep kasm's
  explicit paste affordance rather than assuming silent sync.
- **Folder-share — honest scope change.** The current bridge syncs a
  box-side `~/ClientBridge/` folder, which assumes a desktop client that
  can mount/watch a directory. Phones/tablets cannot (no File System
  Access API on iOS Safari; partial on Android). On mobile/tablet,
  bridge file access becomes **pick-and-upload / download individual
  files** via the OS share sheet and file picker — not a live-synced
  folder. Live folder sync stays a desktop-client capability.
- **Screenshare — still blocked.** Blocked upstream by the
  safeStorage/enclave bug (device tools never reach the model); even
  once fixed, phone screen capture from a browser is limited
  (`getDisplayMedia` restricted on iOS). Documented as a known gap;
  revisit with the safeStorage fix. Tracked at
  JongoDB/coworkstation#12.

## Testing

**Spikes first — build nothing until these three clear** (one session
on the box):

1. **Rendering (gate zero):** at a phone-width viewport, does Claude
   reflow to mobile layout, does `--force-device-scale-factor` stay
   crisp, and do kasm-resize + Electron cooperate on live
   rotation/resize? If Claude will not reflow, the premise changes.
2. **Keyboard round-trip:** the hidden-input → native-keyboard path on
   Android, iOS, and iPadOS.
3. **Auth mode:** confirm kasm uses (or can switch to) a themeable
   cookie login vs raw Basic auth.

**Unit (BATS + `shellcheck -x`, same suite discipline):**
- `kasmvnc.bats` — `kasmvnc_xstartup` emits matchbox + supervisor loop +
  branded backdrop for `dnum<50`, and the `dbus-run-session` wrap for
  `:50+`; remote-resize config present.
- `setup.bats` — every file installed (login theme assets,
  `manifest.json`, `sw.js`, icons) lands at the right path with the
  right content, and `reconfigure` re-applies them under
  `appliance_force`. Assert path + content, like the colord polkit rule.
- Not unit-testable (live E2E on the box via the browser MCP at
  phone/tablet viewports): boot-to-Claude, resolution match, cookie
  login, PWA install, touch, keyboard, clipboard. Run BATS in
  `ubuntu:24.04` docker (macOS `date`/`stat` caveat).

## Rollout

Safe by construction: put kiosk behind a profile toggle that
`setup`/`reconfigure` apply, defaulting **on** once spikes pass, with
the XFCE path retained in code purely as a rollback lever (not a user
escape hatch — kiosk-always stands). Deploy via
`sudo cws update && sudo cws reconfigure`, then verify all three
principals become kiosk: primary, member `bob`, and `:50`.

**Build order after spikes:** kiosk session → resolution → login + PWA →
touch/keyboard polish → mobile per-file bridge.

## Out of scope / YAGNI

- Live folder sync on mobile (desktop-client only; mobile gets per-file
  transfer).
- Screenshare on any client (blocked upstream; #12).
- Rich session management in the auth shim (multi-factor, account
  self-service). It is a single-password gate + cookie; keep it thin.
- Caching the VNC stream in the service worker (install/splash only).
- A native Android/iOS app (the PWA is the deliverable).

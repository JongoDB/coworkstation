#!/usr/bin/env node

/**
 * cws-bridge — the client bridge server (browser tier).
 *
 * Serves a small page (behind the SAME Cloudflare Access gate as the
 * session, via a path route on the session hostname) that lets the
 * connecting device act as a source for the remote Claude session:
 *
 *   - folder share: File System Access API (desktop Chrome/Edge) —
 *     picked files land under ~/ClientBridge/<share>/ on the box,
 *     where Cowork mounts and the Code tab consume them.
 *   - screen share: getDisplayMedia frames, ~1 fps JPEG, kept ONLY as
 *     the latest frame in the user's runtime dir (tmpfs — nothing
 *     persists) for the client-screen MCP server to hand to Claude.
 *   - clipboard bridge: shuttles text between the device clipboard
 *     and the box session's X clipboard (xclip; file fallback) —
 *     the WebKit/iPad path kasmVNC's viewer cannot offer.
 *
 * The page is an installable PWA (manifest + tiny network-first
 * service worker); the link token is remembered in localStorage so
 * the home-screen app works without re-pasting the URL.
 *
 * Consent posture: both shares are user-initiated per session, the
 * page shows a loud SHARING banner, and closing the tab stops
 * everything (frames go stale in seconds and the MCP refuses them).
 *
 * Local-user isolation: the page is static and harmless, but every
 * mutating/reading endpoint requires the per-user bearer token
 * (~/.config/cws-bridge/token, embedded in the link `cws client
 * bridge-link` prints) so other local users on the shared box cannot
 * post frames/files into this user's bridge via loopback.
 *
 * Node core only — no npm dependencies. HTTP only (no websockets):
 * every payload is a plain POST, which keeps this testable and boring.
 */

const http = require('http');
const fs = require('fs');
const path = require('path');
const { execFile } = require('child_process');
const crypto = require('crypto');

const PORT = parseInt(process.env.CWS_BRIDGE_PORT || '8600', 10);
const TOKEN_FILE = process.env.CWS_BRIDGE_TOKEN_FILE ||
    path.join(process.env.HOME || '/', '.config/cws-bridge/token');
const FILES_DIR = process.env.CWS_BRIDGE_FILES_DIR ||
    path.join(process.env.HOME || '/', 'ClientBridge');
const RUNTIME_DIR = process.env.CWS_BRIDGE_RUNTIME_DIR ||
    path.join(process.env.XDG_RUNTIME_DIR || '/tmp', 'cws-bridge');
const MAX_BODY = 64 * 1024 * 1024;      // 64 MiB per file
const MAX_FRAME = 8 * 1024 * 1024;      // 8 MiB per frame
const MAX_CLIP = 1024 * 1024;           // 1 MiB of clipboard text

// Clipboard target: the box session's X clipboard via xclip when a
// DISPLAY is known; otherwise a runtime-dir file (also the test mode,
// CWS_BRIDGE_CLIP_MODE=file). The file fallback still round-trips
// between devices through the page — it just doesn't reach the X
// session's Ctrl-V.
const CLIP_MODE = process.env.CWS_BRIDGE_CLIP_MODE || 'auto';
const CLIP_DISPLAY = process.env.CWS_BRIDGE_DISPLAY ||
    process.env.DISPLAY || '';

// Device registry (ADR-008 phase 3a): every device that touches the
// bridge gets a server-minted cookie id, and each request records
// the Cloudflare Access identity that made it. The identity header
// is trustworthy here because the ONLY route to this loopback server
// is the tunnel with Access in front; browser-only cryptographic
// device identity is not possible (WARP-client only), so the cookie
// is the device key and the verified Access identity is the person.
const DEVICES_FILE = process.env.CWS_BRIDGE_DEVICES_FILE ||
    path.join(process.env.HOME || '/', '.config/cws-bridge/devices.json');
const MAX_DEVICES = 100;

let token = '';
try {
    token = fs.readFileSync(TOKEN_FILE, 'utf8').trim();
} catch (err) {
    console.error(`cws-bridge: cannot read token file ${TOKEN_FILE}`);
    process.exit(1);
}
fs.mkdirSync(RUNTIME_DIR, { recursive: true, mode: 0o700 });
fs.mkdirSync(FILES_DIR, { recursive: true });

function authed(req) {
    const h = req.headers['x-cws-bridge-token'] || '';
    return token.length > 0 && h === token;
}

// Resolve a client-supplied relative path strictly inside root/share.
// Rejects absolute paths, traversal, and empty segments.
function safeJoin(root, share, rel) {
    if (!/^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$/.test(share)) return null;
    const clean = path.normalize(rel).replace(/^([/\\])+/, '');
    if (clean.startsWith('..') || clean.includes('../') ||
        clean.includes('..\\') || path.isAbsolute(clean)) {
        return null;
    }
    const full = path.join(root, share, clean);
    if (!full.startsWith(path.join(root, share) + path.sep) &&
        full !== path.join(root, share)) {
        return null;
    }
    return full;
}

function loadDevices() {
    try {
        return JSON.parse(fs.readFileSync(DEVICES_FILE, 'utf8'));
    } catch (err) {
        return {};
    }
}

function saveDevices(devices) {
    try {
        fs.mkdirSync(path.dirname(DEVICES_FILE), { recursive: true });
        fs.writeFileSync(DEVICES_FILE, JSON.stringify(devices, null, 1),
            { mode: 0o600 });
    } catch (err) { /* registry is best-effort, never block requests */ }
}

function deviceCookie(req) {
    const m = /(?:^|;\s*)cws_device=([\w-]{8,64})(?:;|$)/
        .exec(req.headers.cookie || '');
    return m ? m[1] : null;
}

// Upsert the calling device. Mints the cookie when `res` is given
// (the page GET); authed API calls just record. Returns the id.
function deviceTouch(req, res) {
    let id = deviceCookie(req);
    if (!id && res) {
        id = crypto.randomUUID();
        res.setHeader('Set-Cookie', `cws_device=${id}; Path=/bridge; ` +
            'Max-Age=63072000; SameSite=Lax');
    }
    if (!id) return null;
    const devices = loadDevices();
    const d = devices[id] || { firstSeen: Date.now(), hits: 0 };
    d.lastSeen = Date.now();
    d.hits += 1;
    d.ua = String(req.headers['user-agent'] || '-').slice(0, 200);
    d.identity =
        String(req.headers['cf-access-authenticated-user-email'] || '-')
            .slice(0, 200);
    devices[id] = d;
    const ids = Object.keys(devices);
    if (ids.length > MAX_DEVICES) {
        ids.sort((a, b) => devices[a].lastSeen - devices[b].lastSeen)
            .slice(0, ids.length - MAX_DEVICES)
            .forEach((old) => delete devices[old]);
    }
    saveDevices(devices);
    return id;
}

function clipFile() { return path.join(RUNTIME_DIR, 'clipboard.txt'); }

function xclip(args, input) {
    return new Promise((resolve, reject) => {
        const child = execFile('xclip',
            ['-selection', 'clipboard'].concat(args),
            { env: { ...process.env, DISPLAY: CLIP_DISPLAY },
              timeout: 3000, maxBuffer: MAX_CLIP },
            (err, stdout) => err ? reject(err) : resolve(stdout));
        if (input !== undefined) {
            child.stdin.on('error', () => { /* xclip died; cb has it */ });
            child.stdin.end(input);
        }
    });
}

async function clipRead() {
    if (CLIP_MODE !== 'file' && CLIP_DISPLAY) {
        try {
            return { text: await xclip(['-o']), source: 'session' };
        } catch (err) { /* fall through to the file */ }
    }
    try {
        return { text: fs.readFileSync(clipFile(), 'utf8'), source: 'file' };
    } catch (err) {
        return { text: '', source: 'empty' };
    }
}

async function clipWrite(text) {
    // Always mirror to the file so a fetch works even if xclip dies.
    fs.writeFileSync(clipFile(), text, { mode: 0o600 });
    if (CLIP_MODE !== 'file' && CLIP_DISPLAY) {
        try {
            await xclip(['-i'], text);
            return 'session';
        } catch (err) { /* file mirror already written */ }
    }
    return 'file';
}

function readBody(req, limit) {
    return new Promise((resolve, reject) => {
        const chunks = [];
        let size = 0;
        req.on('data', (c) => {
            size += c.length;
            if (size > limit) {
                reject(new Error('payload too large'));
                req.destroy();
                return;
            }
            chunks.push(c);
        });
        req.on('end', () => resolve(Buffer.concat(chunks)));
        req.on('error', reject);
    });
}

function json(res, code, obj) {
    const body = JSON.stringify(obj);
    res.writeHead(code, { 'Content-Type': 'application/json' });
    res.end(body);
}

async function handle(req, res) {
    const url = new URL(req.url, 'http://localhost');
    const p = url.pathname;

    // Static page: harmless without the token (which arrives in the
    // link fragment/query the operator hands out).
    if (req.method === 'GET' && (p === '/bridge' || p === '/bridge/')) {
        deviceTouch(req, res);
        res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
        res.end(PAGE);
        return;
    }
    if (req.method === 'GET' && p === '/bridge/healthz') {
        json(res, 200, { ok: true });
        return;
    }
    // PWA shell assets: same trust level as the page itself.
    if (req.method === 'GET' && p === '/bridge/manifest.webmanifest') {
        res.writeHead(200, { 'Content-Type': 'application/manifest+json' });
        res.end(MANIFEST);
        return;
    }
    if (req.method === 'GET' && p === '/bridge/sw.js') {
        res.writeHead(200, { 'Content-Type': 'text/javascript' });
        res.end(SW);
        return;
    }
    if (req.method === 'GET' && p === '/bridge/icon.svg') {
        res.writeHead(200, { 'Content-Type': 'image/svg+xml' });
        res.end(ICON);
        return;
    }

    if (!authed(req)) {
        json(res, 401, { error: 'missing or bad bridge token' });
        return;
    }
    deviceTouch(req);

    if (req.method === 'GET' && p === '/bridge/devices') {
        json(res, 200, { ok: true, devices: loadDevices() });
        return;
    }

    if (req.method === 'POST' && p === '/bridge/frame') {
        const body = await readBody(req, MAX_FRAME);
        const tmp = path.join(RUNTIME_DIR, '.frame.tmp');
        fs.writeFileSync(tmp, body, { mode: 0o600 });
        fs.renameSync(tmp, path.join(RUNTIME_DIR, 'latest.jpg'));
        fs.writeFileSync(path.join(RUNTIME_DIR, 'latest.meta'),
            JSON.stringify({ ts: Date.now(), bytes: body.length }),
            { mode: 0o600 });
        json(res, 200, { ok: true });
        return;
    }

    if (req.method === 'POST' && p === '/bridge/file') {
        const share = url.searchParams.get('share') || 'default';
        const rel = url.searchParams.get('path') || '';
        const dest = safeJoin(FILES_DIR, share, rel);
        if (!dest || !rel) {
            json(res, 400, { error: 'bad share or path' });
            return;
        }
        const body = await readBody(req, MAX_BODY);
        fs.mkdirSync(path.dirname(dest), { recursive: true });
        fs.writeFileSync(dest, body);
        json(res, 200, { ok: true, stored: path.relative(FILES_DIR, dest) });
        return;
    }

    if (req.method === 'GET' && p === '/bridge/clipboard') {
        const clip = await clipRead();
        json(res, 200, { ok: true, text: clip.text, source: clip.source });
        return;
    }

    if (req.method === 'POST' && p === '/bridge/clipboard') {
        const body = await readBody(req, MAX_CLIP);
        const target = await clipWrite(body.toString('utf8'));
        json(res, 200, { ok: true, target: target });
        return;
    }

    if (req.method === 'GET' && p === '/bridge/status') {
        let frame = null;
        try {
            frame = JSON.parse(fs.readFileSync(
                path.join(RUNTIME_DIR, 'latest.meta'), 'utf8'));
        } catch (err) { /* no frame yet */ }
        json(res, 200, {
            ok: true,
            frameAgeMs: frame ? Date.now() - frame.ts : null,
            filesDir: FILES_DIR,
        });
        return;
    }

    json(res, 404, { error: 'not found' });
}

// ============================================================
// The page (inline; vanilla JS; no external assets)
// ============================================================

const PAGE = `<!DOCTYPE html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Coworkstation bridge</title>
<link rel="manifest" href="/bridge/manifest.webmanifest">
<link rel="icon" href="/bridge/icon.svg" type="image/svg+xml">
<link rel="apple-touch-icon" href="/bridge/icon.svg">
<meta name="theme-color" content="#1c1c1c">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-title" content="Coworkstation">
<style>
 :root{color-scheme:dark;--brand:#dd6042}
 *{box-sizing:border-box}
 body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;
      background:#1c1c1c;color:#ececec;max-width:620px;margin:0 auto;line-height:1.55;
      padding:max(20px,env(safe-area-inset-top)) 20px max(24px,env(safe-area-inset-bottom))}
 header{display:flex;align-items:center;gap:12px;margin:6px 0 18px}
 header img{width:40px;height:40px;border-radius:11px}
 header .t{font-size:18px;font-weight:600}
 header a.back{margin-left:auto;color:var(--brand);text-decoration:none;font-size:13px}
 h2{font-size:13px;text-transform:uppercase;letter-spacing:.5px;color:#8a8a8a;
    margin:26px 0 8px}
 p{color:#c8c8c8;font-size:14px}
 button{font-size:15px;font-weight:600;padding:12px 18px;margin:4px 8px 4px 0;
        border-radius:12px;border:0;background:#262626;color:#ececec;cursor:pointer}
 button.primary{background:var(--brand);color:#fff}
 button:active{transform:translateY(1px)}
 #sharing{display:none;background:#3a1e1e;color:#ff8a80;padding:12px 16px;
          border-radius:12px;font-weight:600;margin:12px 0}
 .ok{color:#7fd6a2}.err{color:#ff8a80}
 code{background:#2a2a2a;color:var(--brand);padding:.1rem .35rem;border-radius:6px;font-size:.9em}
 textarea{background:#262626;border:1px solid #333;border-radius:12px;color:#fff;
          padding:12px;width:100%;font:inherit}
 small,.hint{color:#7a7a7a}
 a{color:var(--brand)}
 #screenshare[hidden]{display:none}
</style></head><body>
<header>
 <img src="/cws-icon-512.png" alt="">
 <span class="t">Bridge</span>
 <a class="back" href="/home">← Home</a>
</header>
<p>Make this device a source for your Claude session on the box.
Everything here is off until you turn it on, and stops when you close
this tab.</p>
<div id="sharing"><svg width="12" height="12" viewBox="0 0 12 12"
 style="vertical-align:-1px;margin-right:6px"><circle cx="6" cy="6" r="5"
 fill="#e5484d"/></svg>SCREEN SHARING IS ON — Claude can see the shared
screen. Close the tab or press Stop to end it.</div>
<div id="screenshare">
<h2>Screen share</h2>
<p>Claude sees ~1 frame/second of whatever you pick (screen, window,
or tab). In a Cowork task, ask it to run
<code>cws client screenshot ~/screen.jpg</code> on your device, then
stage and view <code>~/screen.jpg</code>.</p>
<button class="primary" id="startScreen">Start screen share</button>
<button id="stopScreen">Stop</button>
</div>
<p class="hint" id="noScreen" hidden>Screen share needs a desktop browser —
phones and tablets don't expose a screen-capture API.</p>
<h2>Folder share (desktop Chrome/Edge)</h2>
<p>Files you pick are copied to <code>~/ClientBridge/</code> on the
box. Re-sync any time; nothing else on this device is touched.</p>
<button id="pickFolder">Pick a folder & sync</button>
<button id="resync">Re-sync</button>
<h2>Clipboard</h2>
<p>Bridges this device's clipboard and the box session's clipboard —
works on iPad/Safari, where the desktop viewer can't. Text passes
through the box only.</p>
<textarea id="clipText" rows="3" style="width:100%;font:inherit"
 placeholder="Paste here (or use Send to read this device's clipboard)"
></textarea><br>
<button id="clipSend">Send to box</button>
<button id="clipFetch">Fetch from box</button>
<p><small>Tip: install this page as an app (Share &rarr; Add to Home
Screen) — the link's token is remembered on this device.</small></p>
<p id="log"></p>
<script>
// The install-to-home-screen flow loses the URL token, so remember it
// per device. This origin is already gated by Cloudflare Access.
let token = new URLSearchParams(location.search).get('t') ||
    (location.hash || '').replace(/^#t=/, '');
try {
    if (token) localStorage.setItem('cws-bridge-token', token);
    else token = localStorage.getItem('cws-bridge-token') || '';
} catch (e) { /* storage disabled; URL token still works */ }
if (navigator.serviceWorker) {
    navigator.serviceWorker.register('/bridge/sw.js').catch(() => {});
}
const log = (m, cls) => {
    const el = document.getElementById('log');
    el.textContent = m; el.className = cls || '';
};
if (!token) log('No token in the link — get a fresh link with: ' +
    'sudo cws client bridge-link', 'err');
const hdrs = { 'X-CWS-Bridge-Token': token };

let stream = null, timer = null, dirHandle = null;
const v = document.createElement('video'), c = document.createElement('canvas');

async function frameLoop() {
    if (!stream) return;
    const track = stream.getVideoTracks()[0];
    if (!track || track.readyState !== 'live') { stopScreen(); return; }
    c.width = v.videoWidth; c.height = v.videoHeight;
    if (c.width === 0) return;
    c.getContext('2d').drawImage(v, 0, 0);
    const blob = await new Promise(r => c.toBlob(r, 'image/jpeg', 0.7));
    await fetch('/bridge/frame', { method: 'POST', headers: hdrs, body: blob })
        .catch(() => {});
}
async function startScreen() {
    stream = await navigator.mediaDevices.getDisplayMedia({ video: true });
    v.srcObject = stream; await v.play();
    document.getElementById('sharing').style.display = 'block';
    timer = setInterval(frameLoop, 1000);
    stream.getVideoTracks()[0].addEventListener('ended', stopScreen);
    log('Screen share running.', 'ok');
}
function stopScreen() {
    if (timer) clearInterval(timer);
    if (stream) stream.getTracks().forEach(t => t.stop());
    stream = null; timer = null;
    document.getElementById('sharing').style.display = 'none';
    log('Screen share stopped.');
}
async function syncDir() {
    if (!dirHandle) return;
    let n = 0;
    async function walk(handle, prefix) {
        for await (const [name, h] of handle.entries()) {
            if (h.kind === 'file') {
                const f = await h.getFile();
                await fetch('/bridge/file?share=' + dirHandle.name +
                    '&path=' + encodeURIComponent(prefix + name),
                    { method: 'POST', headers: hdrs, body: f });
                n++;
            } else if (h.kind === 'directory') {
                await walk(h, prefix + name + '/');
            }
        }
    }
    await walk(dirHandle, '');
    log('Synced ' + n + ' files to ~/ClientBridge/' + dirHandle.name, 'ok');
}
// Screen capture needs getDisplayMedia, which mobile browsers do not
// expose — hide the whole section on phones/tablets rather than let the
// user tap into a "getDisplayMedia is not a function" error.
if (!(navigator.mediaDevices && navigator.mediaDevices.getDisplayMedia)) {
    document.getElementById('screenshare').hidden = true;
    document.getElementById('noScreen').hidden = false;
}
document.getElementById('startScreen').onclick =
    () => startScreen().catch(e => log(String(e), 'err'));
document.getElementById('stopScreen').onclick = stopScreen;
document.getElementById('pickFolder').onclick = async () => {
    if (!window.showDirectoryPicker) {
        log('Folder pick needs desktop Chrome/Edge; on tablets use ' +
            'ClientSync instead.', 'err');
        return;
    }
    dirHandle = await window.showDirectoryPicker();
    await syncDir();
};
document.getElementById('resync').onclick =
    () => syncDir().catch(e => log(String(e), 'err'));

const clipBox = document.getElementById('clipText');
document.getElementById('clipSend').onclick = async () => {
    try {
        // Prefer the device clipboard; WebKit allows readText only on
        // a user gesture, and may still decline — textarea is the
        // universal fallback.
        if (!clipBox.value && navigator.clipboard &&
            navigator.clipboard.readText) {
            clipBox.value = await navigator.clipboard.readText()
                .catch(() => '');
        }
        if (!clipBox.value) {
            log('Nothing to send — paste into the box above first.', 'err');
            return;
        }
        const r = await fetch('/bridge/clipboard',
            { method: 'POST', headers: hdrs, body: clipBox.value });
        const j = await r.json();
        if (!r.ok) throw new Error(j.error || r.status);
        log('Sent to the box clipboard (' + j.target + ').', 'ok');
    } catch (e) { log('Send failed: ' + e, 'err'); }
};
document.getElementById('clipFetch').onclick = async () => {
    try {
        const r = await fetch('/bridge/clipboard', { headers: hdrs });
        const j = await r.json();
        if (!r.ok) throw new Error(j.error || r.status);
        clipBox.value = j.text;
        // Same user gesture, so WebKit permits the write; if it
        // declines, the text is in the box for a manual copy.
        let copied = false;
        if (navigator.clipboard && navigator.clipboard.writeText) {
            copied = await navigator.clipboard.writeText(j.text)
                .then(() => true, () => false);
        }
        log(copied ? 'Box clipboard copied to this device.'
                   : 'Fetched — long-press the text above to copy.', 'ok');
    } catch (e) { log('Fetch failed: ' + e, 'err'); }
};
</script></body></html>`;

const MANIFEST = JSON.stringify({
    name: 'Coworkstation',
    short_name: 'Coworkstation',
    description: 'Client bridge for your Coworkstation box',
    start_url: '/bridge/',
    scope: '/bridge/',
    display: 'standalone',
    background_color: '#1b2a4a',
    theme_color: '#1b2a4a',
    icons: [{
        src: '/bridge/icon.svg',
        sizes: 'any',
        type: 'image/svg+xml',
        purpose: 'any',
    }],
});

const ICON = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
<rect width="64" height="64" rx="12" fill="#1b2a4a"/>
<rect x="10" y="14" width="44" height="28" rx="4" fill="none"
 stroke="#e8ecf5" stroke-width="4"/>
<path d="M22 52h20M32 42v10" stroke="#e8ecf5" stroke-width="4"
 stroke-linecap="round"/>
<circle cx="32" cy="28" r="6" fill="#e8ecf5"/>
</svg>`;

// Network-first shell cache: the page still opens (with its saved
// token) during a brief tunnel blip; API calls are never cached.
const SW = `const SHELL = ['/bridge/', '/bridge/icon.svg'];
self.addEventListener('install', (e) => {
    e.waitUntil(caches.open('cws-bridge-v1')
        .then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', (e) => {
    e.waitUntil(self.clients.claim());
});
self.addEventListener('fetch', (e) => {
    const url = new URL(e.request.url);
    if (e.request.method !== 'GET' ||
        !SHELL.includes(url.pathname)) return;
    e.respondWith(fetch(e.request).then((r) => {
        const copy = r.clone();
        caches.open('cws-bridge-v1')
            .then((c) => c.put(e.request, copy));
        return r;
    }).catch(() => caches.match(e.request)));
});
`;

const server = http.createServer((req, res) => {
    handle(req, res).catch((err) => {
        json(res, 500, { error: String(err.message) });
    });
});
server.listen(PORT, '127.0.0.1', () => {
    console.error(`cws-bridge listening on 127.0.0.1:${PORT}`);
});

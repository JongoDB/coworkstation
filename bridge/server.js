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

const PORT = parseInt(process.env.CWS_BRIDGE_PORT || '8600', 10);
const TOKEN_FILE = process.env.CWS_BRIDGE_TOKEN_FILE ||
    path.join(process.env.HOME || '/', '.config/cws-bridge/token');
const FILES_DIR = process.env.CWS_BRIDGE_FILES_DIR ||
    path.join(process.env.HOME || '/', 'ClientBridge');
const RUNTIME_DIR = process.env.CWS_BRIDGE_RUNTIME_DIR ||
    path.join(process.env.XDG_RUNTIME_DIR || '/tmp', 'cws-bridge');
const MAX_BODY = 64 * 1024 * 1024;      // 64 MiB per file
const MAX_FRAME = 8 * 1024 * 1024;      // 8 MiB per frame

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
        res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
        res.end(PAGE);
        return;
    }
    if (req.method === 'GET' && p === '/bridge/healthz') {
        json(res, 200, { ok: true });
        return;
    }

    if (!authed(req)) {
        json(res, 401, { error: 'missing or bad bridge token' });
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
<style>
 body{font-family:system-ui,sans-serif;margin:2rem auto;max-width:640px;
      padding:0 1rem;line-height:1.5}
 button{font-size:1rem;padding:.6rem 1.2rem;margin:.3rem .4rem .3rem 0;
        border-radius:8px;border:1px solid #999;cursor:pointer}
 #sharing{display:none;background:#c62828;color:#fff;padding:.6rem 1rem;
          border-radius:8px;font-weight:700;margin:.5rem 0}
 .ok{color:#1b7f4d}.err{color:#c62828}
 code{background:#eee;padding:.1rem .35rem;border-radius:4px}
</style></head><body>
<h1>Coworkstation bridge</h1>
<p>Make this device a source for your Claude session on the box.
Everything here is off until you turn it on, and stops when you close
this tab.</p>
<div id="sharing">🔴 SCREEN SHARING IS ON — Claude can see the shared
screen. Close the tab or press Stop to end it.</div>
<h2>Screen share</h2>
<p>Claude sees ~1 frame/second of whatever you pick (screen, window,
or tab). Ask it to use the <code>client_screenshot</code> tool.</p>
<button id="startScreen">Start screen share</button>
<button id="stopScreen">Stop</button>
<h2>Folder share (desktop Chrome/Edge)</h2>
<p>Files you pick are copied to <code>~/ClientBridge/</code> on the
box. Re-sync any time; nothing else on this device is touched.</p>
<button id="pickFolder">Pick a folder & sync</button>
<button id="resync">Re-sync</button>
<p id="log"></p>
<script>
const token = new URLSearchParams(location.search).get('t') ||
    (location.hash || '').replace(/^#t=/, '');
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
</script></body></html>`;

const server = http.createServer((req, res) => {
    handle(req, res).catch((err) => {
        json(res, 500, { error: String(err.message) });
    });
});
server.listen(PORT, '127.0.0.1', () => {
    console.error(`cws-bridge listening on 127.0.0.1:${PORT}`);
});

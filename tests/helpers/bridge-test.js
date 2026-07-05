#!/usr/bin/env node
// Live test harness for bridge/server.js + client-screen-mcp.js:
// boots the real server on a random port with sandbox dirs, exercises
// every endpoint (auth, traversal, frame handoff), then drives the MCP
// server over stdio and asserts the screenshot round-trips. Exits 0
// on success, 1 with a message on the first failure.

const { spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const readline = require('readline');

const here = __dirname;
const serverJs = path.join(here, '..', '..', 'bridge', 'server.js');
const mcpJs = path.join(here, '..', '..', 'bridge', 'client-screen-mcp.js');

function fail(msg) {
    console.error('FAIL: ' + msg);
    process.exit(1);
}

async function main() {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'cws-bridge-'));
    const runtime = path.join(tmp, 'runtime');
    const files = path.join(tmp, 'files');
    const tokenFile = path.join(tmp, 'token');
    fs.writeFileSync(tokenFile, 'testtoken123\n');
    const port = 18000 + Math.floor(Math.random() * 2000);

    const srv = spawn('node', [serverJs], {
        env: {
            ...process.env,
            CWS_BRIDGE_PORT: String(port),
            CWS_BRIDGE_TOKEN_FILE: tokenFile,
            CWS_BRIDGE_FILES_DIR: files,
            CWS_BRIDGE_RUNTIME_DIR: runtime,
            CWS_BRIDGE_CLIP_MODE: 'file',
        },
        stdio: ['ignore', 'ignore', 'pipe'],
    });
    let srvErr = '';
    srv.stderr.on('data', (d) => { srvErr += d; });

    const base = `http://127.0.0.1:${port}`;
    // wait for it to listen
    let up = false;
    for (let i = 0; i < 50 && !up; i++) {
        try {
            const r = await fetch(`${base}/bridge/healthz`);
            up = r.ok;
        } catch (e) { await new Promise((r) => setTimeout(r, 100)); }
    }
    if (!up) fail('server never came up: ' + srvErr);

    const tok = { 'X-CWS-Bridge-Token': 'testtoken123' };

    // 1) static page serves without a token
    const page = await fetch(`${base}/bridge/`);
    if (!page.ok) fail('page not served');
    const html = await page.text();
    if (!html.includes('SCREEN SHARING IS ON')) {
        fail('consent banner missing from page');
    }
    if (!html.includes('manifest.webmanifest') ||
        !html.includes('clipFetch')) {
        fail('PWA manifest link or clipboard UI missing from page');
    }

    // 1b) PWA shell assets serve without a token
    let r = await fetch(`${base}/bridge/manifest.webmanifest`);
    if (!r.ok) fail('manifest not served');
    const manifest = await r.json();
    if (manifest.start_url !== '/bridge/' || manifest.scope !== '/bridge/') {
        fail('manifest start_url/scope wrong: ' + JSON.stringify(manifest));
    }
    r = await fetch(`${base}/bridge/sw.js`);
    if (!r.ok || !(await r.text()).includes('cws-bridge-v1')) {
        fail('service worker not served');
    }
    r = await fetch(`${base}/bridge/icon.svg`);
    if (!r.ok || !(r.headers.get('content-type') || '')
        .includes('image/svg+xml')) {
        fail('icon not served as svg');
    }

    // 2) endpoints refuse without the token
    r = await fetch(`${base}/bridge/frame`,
        { method: 'POST', body: 'x' });
    if (r.status !== 401) fail('frame accepted without token');
    r = await fetch(`${base}/bridge/clipboard`);
    if (r.status !== 401) fail('clipboard read without token');
    r = await fetch(`${base}/bridge/file?share=s&path=a.txt`,
        { method: 'POST', body: 'x' });
    if (r.status !== 401) fail('file accepted without token');
    r = await fetch(`${base}/bridge/status`);
    if (r.status !== 401) fail('status served without token');

    // 3) file upload lands under FILES_DIR/share, traversal refused
    r = await fetch(`${base}/bridge/file?share=proj&path=sub/hello.txt`,
        { method: 'POST', headers: tok, body: 'hi from client' });
    if (!r.ok) fail('file upload failed');
    const stored = fs.readFileSync(
        path.join(files, 'proj', 'sub', 'hello.txt'), 'utf8');
    if (stored !== 'hi from client') fail('file content mismatch');
    r = await fetch(`${base}/bridge/file?share=proj&path=` +
        encodeURIComponent('../../evil.txt'),
        { method: 'POST', headers: tok, body: 'evil' });
    if (r.status !== 400) fail('traversal was not refused');
    if (fs.existsSync(path.join(tmp, 'evil.txt'))) {
        fail('traversal escaped the share root');
    }
    r = await fetch(`${base}/bridge/file?share=` +
        encodeURIComponent('bad/share') + '&path=a.txt',
        { method: 'POST', headers: tok, body: 'x' });
    if (r.status !== 400) fail('bad share name accepted');

    // 4) frame post -> runtime latest.jpg + status age
    const fakeJpg = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]);
    r = await fetch(`${base}/bridge/frame`,
        { method: 'POST', headers: tok, body: fakeJpg });
    if (!r.ok) fail('frame post failed');
    if (!fs.existsSync(path.join(runtime, 'latest.jpg'))) {
        fail('latest.jpg not written');
    }
    r = await fetch(`${base}/bridge/status`, { headers: tok });
    const st = await r.json();
    if (typeof st.frameAgeMs !== 'number' || st.frameAgeMs > 5000) {
        fail('status frame age wrong: ' + JSON.stringify(st));
    }

    // 4b) clipboard round-trip (file mode) + empty state
    r = await fetch(`${base}/bridge/clipboard`, { headers: tok });
    let clip = await r.json();
    if (!r.ok || clip.text !== '' || clip.source !== 'empty') {
        fail('fresh clipboard not empty: ' + JSON.stringify(clip));
    }
    const clipText = 'from the client device éà ✓';
    r = await fetch(`${base}/bridge/clipboard`,
        { method: 'POST', headers: tok, body: clipText });
    if (!r.ok || (await r.json()).target !== 'file') {
        fail('clipboard post failed');
    }
    r = await fetch(`${base}/bridge/clipboard`, { headers: tok });
    clip = await r.json();
    if (clip.text !== clipText || clip.source !== 'file') {
        fail('clipboard round-trip mismatch: ' + JSON.stringify(clip));
    }

    // 5) MCP: client_screenshot returns the frame; stale frame refused
    const mcp = spawn('node', [mcpJs], {
        env: { ...process.env, CWS_BRIDGE_RUNTIME_DIR: runtime },
        stdio: ['pipe', 'pipe', 'inherit'],
    });
    const rl = readline.createInterface({ input: mcp.stdout });
    const replies = [];
    rl.on('line', (l) => { if (l.trim()) replies.push(JSON.parse(l)); });
    const send = (m) => mcp.stdin.write(JSON.stringify(m) + '\n');
    const waitFor = async (id) => {
        for (let i = 0; i < 50; i++) {
            const hit = replies.find((m) => m.id === id);
            if (hit) return hit;
            await new Promise((r) => setTimeout(r, 100));
        }
        fail('no MCP reply for id ' + id);
    };
    send({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} });
    await waitFor(1);
    send({ jsonrpc: '2.0', id: 2, method: 'tools/call',
        params: { name: 'client_screenshot', arguments: {} } });
    const shot = await waitFor(2);
    const img = shot.result.content[0];
    if (img.type !== 'image' || img.mimeType !== 'image/jpeg') {
        fail('screenshot not an image: ' + JSON.stringify(shot.result));
    }
    if (Buffer.from(img.data, 'base64').compare(fakeJpg) !== 0) {
        fail('screenshot bytes differ from posted frame');
    }
    // stale: age the meta far past the freshness window
    const meta = JSON.parse(fs.readFileSync(
        path.join(runtime, 'latest.meta'), 'utf8'));
    meta.ts = Date.now() - 60 * 1000;
    fs.writeFileSync(path.join(runtime, 'latest.meta'),
        JSON.stringify(meta));
    send({ jsonrpc: '2.0', id: 3, method: 'tools/call',
        params: { name: 'client_screenshot', arguments: {} } });
    const stale = await waitFor(3);
    if (!stale.result.isError ||
        !String(stale.result.content[0].text).includes('stopped')) {
        fail('stale frame was not refused: ' + JSON.stringify(stale.result));
    }

    mcp.kill();
    srv.kill();
    console.log('bridge live test: all assertions passed');
    process.exit(0);
}

main().catch((e) => fail(String(e && e.stack || e)));

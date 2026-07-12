#!/usr/bin/env node
/*
 * gateway-test.js — end-to-end harness for gateway/server.js
 *
 * Spins a fake kasm upstream + the real gateway, then exercises the login
 * gate, cookie session, HTTP proxy, DPR capture, and the WebSocket
 * upgrade gate. Exits 0 on success, non-zero (with a message) on the
 * first failure. Mirrors tests/helpers/bridge-test.js.
 */
'use strict';

const http = require('http');
const net = require('net');
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { spawn } = require('child_process');

const REPO = path.resolve(__dirname, '..', '..');
const UP_PORT = 8790;
const GW_PORT = 8791;
const PASSWORD = 'testpw123';

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'cws-gw-'));
const credFile = path.join(tmp, 'kasm-credentials');
const secretFile = path.join(tmp, 'secret');
const scaleFile = path.join(tmp, 'device-scale');
fs.writeFileSync(credFile, `username=cws\npassword=${PASSWORD}\n`);

function die(msg) { console.error('FAIL:', msg); cleanup(); process.exit(1); }
let gw;
function cleanup() {
	try { if (gw) gw.kill('SIGKILL'); } catch (_) {}
	try { upstream.close(); } catch (_) {}
	try { fs.rmSync(tmp, { recursive: true, force: true }); } catch (_) {}
}

// --- fake kasm upstream (requires Basic auth, like kasm) ---------------
const EXPECT_AUTH = 'Basic ' + Buffer.from('cws:' + PASSWORD).toString('base64');
const upstream = http.createServer((req, res) => {
	if (req.headers.authorization !== EXPECT_AUTH) {
		res.writeHead(401, { 'WWW-Authenticate': 'Basic realm="x"' });
		res.end('unauth');
		return;
	}
	res.writeHead(200, { 'Content-Type': 'text/plain' });
	res.end('UPSTREAM_OK ' + req.url);
});
upstream.on('upgrade', (req, socket) => {
	if (req.headers.authorization !== EXPECT_AUTH) { socket.destroy(); return; }
	const key = req.headers['sec-websocket-key'] || '';
	const accept = crypto.createHash('sha1')
		.update(key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11')
		.digest('base64');
	socket.write('HTTP/1.1 101 Switching Protocols\r\n'
		+ 'Upgrade: websocket\r\nConnection: Upgrade\r\n'
		+ 'Sec-WebSocket-Accept: ' + accept + '\r\n\r\n');
	// keep the socket briefly so the client can read the 101
	setTimeout(() => socket.destroy(), 200);
});

// --- small HTTP client -------------------------------------------------
function req(opts, body) {
	return new Promise((resolve, reject) => {
		const r = http.request(Object.assign({ host: '127.0.0.1' }, opts),
			(res) => {
				let b = '';
				res.on('data', (c) => { b += c; });
				res.on('end', () => resolve({
					status: res.statusCode, headers: res.headers, body: b,
				}));
			});
		r.on('error', reject);
		if (body) r.write(body);
		r.end();
	});
}

function wsAttempt(cookie) {
	return new Promise((resolve) => {
		const s = net.connect(GW_PORT, '127.0.0.1', () => {
			const key = crypto.randomBytes(16).toString('base64');
			let raw = 'GET /websockify HTTP/1.1\r\nHost: x\r\n'
				+ 'Upgrade: websocket\r\nConnection: Upgrade\r\n'
				+ 'Sec-WebSocket-Version: 13\r\n'
				+ 'Sec-WebSocket-Key: ' + key + '\r\n';
			if (cookie) raw += 'Cookie: ' + cookie + '\r\n';
			raw += '\r\n';
			s.write(raw);
		});
		let got = '';
		s.on('data', (d) => { got += d.toString(); });
		s.on('close', () => resolve(got));
		s.on('error', () => resolve(got));
		setTimeout(() => { try { s.destroy(); } catch (_) {} }, 400);
	});
}

async function main() {
	await new Promise((r) => upstream.listen(UP_PORT, '127.0.0.1', r));

	gw = spawn('node', [path.join(REPO, 'gateway', 'server.js')], {
		env: Object.assign({}, process.env, {
			CWS_GW_PORT: String(GW_PORT),
			CWS_GW_UPSTREAM: String(UP_PORT),
			CWS_GW_CRED: credFile,
			CWS_GW_SECRET: secretFile,
			CWS_GW_WWW: path.join(REPO, 'gateway', 'www'),
			CWS_GW_SCALE_FILE: scaleFile,
		}),
		stdio: ['ignore', 'ignore', 'inherit'],
	});
	// wait for listen
	await new Promise((r) => setTimeout(r, 600));

	// 1. login page served unauthenticated
	let res = await req({ port: GW_PORT, path: '/cws-login' });
	if (res.status !== 200 || !/Coworkstation/.test(res.body)) {
		die('login page not served: ' + res.status);
	}

	// 2. gated path without a cookie -> redirect to login
	res = await req({ port: GW_PORT, path: '/' });
	if (res.status !== 302 || res.headers.location !== '/cws-login') {
		die('unauthed root should 302 to login, got ' + res.status);
	}

	// 3. wrong password -> back to login with error, no cookie
	res = await req({ port: GW_PORT, path: '/cws-login', method: 'POST',
		headers: { 'Content-Type': 'application/x-www-form-urlencoded' } },
		'password=nope');
	if (res.status !== 303 || !/e=1/.test(res.headers.location || '')
		|| res.headers['set-cookie']) {
		die('wrong password should 303 e=1 with no cookie');
	}

	// 4. correct password + dpr -> cookie set, redirect to /, scale recorded
	res = await req({ port: GW_PORT, path: '/cws-login', method: 'POST',
		headers: { 'Content-Type': 'application/x-www-form-urlencoded' } },
		'password=' + PASSWORD + '&dpr=3');
	const setCookie = (res.headers['set-cookie'] || [])[0] || '';
	if (res.status !== 302 || res.headers.location !== '/'
		|| !/cws_gw=/.test(setCookie)) {
		die('correct password should 302 / with a cws_gw cookie');
	}
	const cookie = setCookie.split(';')[0];
	if (fs.readFileSync(scaleFile, 'utf8').trim() !== '3') {
		die('device scale not recorded from dpr');
	}

	// 5. authed request is proxied to the upstream
	res = await req({ port: GW_PORT, path: '/hello',
		headers: { Cookie: cookie } });
	if (res.status !== 200 || !/UPSTREAM_OK \/hello/.test(res.body)) {
		die('authed request not proxied: ' + res.status + ' ' + res.body);
	}

	// 6. tampered cookie is rejected
	const tampered = cookie.replace(/.$/, (c) => (c === 'A' ? 'B' : 'A'));
	res = await req({ port: GW_PORT, path: '/', headers: { Cookie: tampered } });
	if (res.status !== 302) die('tampered cookie should be rejected');

	// 7. WebSocket upgrade gated: with cookie -> 101 from upstream
	const wsOk = await wsAttempt(cookie);
	if (!/101 Switching Protocols/.test(wsOk)) {
		die('authed websocket upgrade did not reach upstream 101');
	}
	// without cookie -> no 101 (socket closed by gateway)
	const wsNo = await wsAttempt(null);
	if (/101 Switching Protocols/.test(wsNo)) {
		die('unauthed websocket upgrade should be refused');
	}

	console.log('gateway-test: OK (login gate, cookie, proxy, dpr, ws gate)');
	cleanup();
	process.exit(0);
}

main().catch((e) => die(e && e.stack || String(e)));

#!/usr/bin/env node
/*
 * gateway/server.js — Coworkstation kiosk front door
 *
 * A tiny loopback reverse proxy that puts a BRANDED, COOKIE-BASED login
 * in front of a kasmVNC session, so a phone/tablet PWA gets a clean
 * "enter password -> land in the app" entry instead of the browser's
 * HTTP Basic auth dialog (kasmVNC is Basic-auth-only; there is no login
 * page to theme — see docs/plans/2026-07-12-immersive-claude-kiosk-design.md).
 *
 * The gate is the shim's signed session cookie. kasm keeps its own Basic
 * auth ON (so a same-box local user still cannot reach the loopback kasm
 * port without the password); the gateway INJECTS Authorization: Basic
 * upstream from the same kasm-credentials it validates logins against, so
 * the phone never sees a Basic dialog. The Cloudflare tunnel routes the
 * hostname to THIS port; we serve the login + PWA assets, gate every
 * other request on the cookie, and proxy the kasm client + its
 * /websockify WebSocket upstream to 127.0.0.1:UPSTREAM.
 *
 * Pure Node stdlib — no npm deps, matching bridge/server.js. Runs as the
 * session user via a systemd user unit (see lib/gateway.sh).
 *
 * Env:
 *   CWS_GW_PORT       listen port on 127.0.0.1 (required)
 *   CWS_GW_UPSTREAM   kasm websocket port on 127.0.0.1 (required)
 *   CWS_GW_CRED       path to kasm-credentials (password=... line)
 *   CWS_GW_SECRET     path to the HMAC signing secret (0600)
 *   CWS_GW_WWW        directory of login + PWA assets
 *   CWS_GW_SCALE_FILE optional: write the client's devicePixelRatio here
 *                     on login, for cws-launch's --force-device-scale-factor
 */
'use strict';

const http = require('http');
const net = require('net');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const PORT = parseInt(process.env.CWS_GW_PORT || '8701', 10);
const UPSTREAM = parseInt(process.env.CWS_GW_UPSTREAM || '8443', 10);
const CRED = process.env.CWS_GW_CRED || '';
const SECRET_FILE = process.env.CWS_GW_SECRET || '';
const WWW = process.env.CWS_GW_WWW || path.join(__dirname, 'www');
const SCALE_FILE = process.env.CWS_GW_SCALE_FILE || '';

const COOKIE = 'cws_gw';
const SESSION_TTL_S = 30 * 24 * 60 * 60; // 30 days

// --- secret + cookie signing ------------------------------------------

// Load (or lazily create) the per-box HMAC secret. The unit points every
// launch at the same file so cookies survive restarts.
function loadSecret() {
	try {
		const s = fs.readFileSync(SECRET_FILE);
		if (s && s.length >= 16) return s;
	} catch (_) { /* fall through to generate */ }
	const s = crypto.randomBytes(32);
	try {
		fs.writeFileSync(SECRET_FILE, s, { mode: 0o600 });
	} catch (e) {
		// No secret file configured/writable: keep an in-memory secret so
		// the process still works (cookies just won't survive a restart).
		console.error('[gateway] secret not persisted:', e.message);
	}
	return s;
}
const SECRET = loadSecret();

function b64url(buf) {
	return Buffer.from(buf).toString('base64')
		.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
function signSession(expEpochS) {
	const payload = b64url(JSON.stringify({ exp: expEpochS }));
	const mac = b64url(crypto.createHmac('sha256', SECRET)
		.update(payload).digest());
	return `${payload}.${mac}`;
}
function verifySession(value) {
	if (!value || value.indexOf('.') < 0) return false;
	const [payload, mac] = value.split('.', 2);
	const expected = b64url(crypto.createHmac('sha256', SECRET)
		.update(payload).digest());
	// constant-time compare
	const a = Buffer.from(mac); const b = Buffer.from(expected);
	if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return false;
	try {
		const { exp } = JSON.parse(Buffer.from(payload
			.replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString());
		return typeof exp === 'number' && exp > Math.floor(Date.now() / 1000);
	} catch (_) { return false; }
}

function parseCookies(header) {
	const out = {};
	(header || '').split(';').forEach((p) => {
		const i = p.indexOf('=');
		if (i > 0) out[p.slice(0, i).trim()] = p.slice(i + 1).trim();
	});
	return out;
}
function isAuthed(req) {
	return verifySession(parseCookies(req.headers.cookie)[COOKIE]);
}

// --- password check ----------------------------------------------------

// The kasm gate credentials, stored in plaintext in ~/.vnc/kasm-credentials
// (username=.../password=...). Read fresh each time (the file is tiny and
// may be rotated); used both to validate the login and to inject Basic
// auth upstream.
function kasmCreds() {
	try {
		const txt = fs.readFileSync(CRED, 'utf8');
		const u = txt.match(/^username=(.*)$/m);
		const p = txt.match(/^password=(.*)$/m);
		return { user: u ? u[1] : null, pass: p ? p[1] : null };
	} catch (_) { return { user: null, pass: null }; }
}
function passwordOk(submitted) {
	const expected = kasmCreds().pass;
	if (expected == null || submitted == null) return false;
	const a = Buffer.from(String(submitted));
	const b = Buffer.from(String(expected));
	return a.length === b.length && crypto.timingSafeEqual(a, b);
}

// Authorization: Basic header for the upstream kasm httpd, so kasm keeps
// its Basic auth on while the phone never sees the dialog. Null if the
// credentials are unreadable (then kasm will 401 — fail closed).
function upstreamAuth() {
	const { user, pass } = kasmCreds();
	if (user == null || pass == null) return null;
	return 'Basic ' + Buffer.from(user + ':' + pass).toString('base64');
}

// --- static assets -----------------------------------------------------

const TYPES = {
	'.html': 'text/html; charset=utf-8',
	'.js': 'text/javascript; charset=utf-8',
	'.css': 'text/css; charset=utf-8',
	'.svg': 'image/svg+xml',
	'.png': 'image/png',
	'.webmanifest': 'application/manifest+json',
	'.json': 'application/json',
};
function serveAsset(name, res) {
	// name is a fixed, caller-chosen basename — never from the URL.
	const file = path.join(WWW, name);
	fs.readFile(file, (err, buf) => {
		if (err) { res.writeHead(404).end('not found'); return; }
		res.writeHead(200, { 'Content-Type': TYPES[path.extname(name)]
			|| 'application/octet-stream' });
		res.end(buf);
	});
}

function setSessionCookie(res) {
	const exp = Math.floor(Date.now() / 1000) + SESSION_TTL_S;
	res.setHeader('Set-Cookie', `${COOKIE}=${signSession(exp)}; Path=/; `
		+ `HttpOnly; Secure; SameSite=Lax; Max-Age=${SESSION_TTL_S}`);
}

// Persist the client's devicePixelRatio for cws-launch (crisp HiDPI).
function recordScale(dpr) {
	if (!SCALE_FILE || !dpr) return;
	const n = Number(dpr);
	if (!(n > 0) || n > 6) return;         // sane bound
	try { fs.writeFileSync(SCALE_FILE, String(n)); } catch (_) { /* ignore */ }
}

// --- HTTP handling -----------------------------------------------------

function handleLoginPost(req, res) {
	let body = '';
	req.on('data', (c) => {
		body += c;
		if (body.length > 4096) req.destroy();   // no huge posts
	});
	req.on('end', () => {
		const params = new URLSearchParams(body);
		if (passwordOk(params.get('password'))) {
			recordScale(params.get('dpr'));
			setSessionCookie(res);
			res.writeHead(302, { Location: '/' }).end();
		} else {
			res.writeHead(303, { Location: '/cws-login?e=1' }).end();
		}
	});
}

const server = http.createServer((req, res) => {
	const url = req.url || '/';
	const p = url.split('?')[0];

	// Unauthenticated: login + PWA shell assets.
	if (p === '/cws-login' && req.method === 'POST') {
		return handleLoginPost(req, res);
	}
	if (p === '/cws-login') return serveAsset('login.html', res);
	if (p === '/cws-logout') {
		res.setHeader('Set-Cookie', `${COOKIE}=; Path=/; Max-Age=0`);
		return res.writeHead(302, { Location: '/cws-login' }).end();
	}
	if (p === '/manifest.webmanifest') return serveAsset('manifest.webmanifest', res);
	if (p === '/sw.js') return serveAsset('sw.js', res);
	if (p === '/cws-icon.svg') return serveAsset('cws-icon.svg', res);
	if (p === '/cws-app.js') return serveAsset('cws-app.js', res);

	// Everything else requires a valid session.
	if (!isAuthed(req)) {
		return res.writeHead(302, { Location: '/cws-login' }).end();
	}
	proxyHttp(req, res);
});

function proxyHttp(req, res) {
	const headers = Object.assign({}, req.headers);
	// Node lowercases inbound header names; kasm's websockify Basic-auth
	// parser matches "Authorization" CASE-SENSITIVELY, so drop any
	// lowercase copy and inject with the capitalized name it expects.
	delete headers.authorization;
	const auth = upstreamAuth();
	if (auth) headers.Authorization = auth;   // kasm Basic, injected
	const up = http.request({
		host: '127.0.0.1', port: UPSTREAM, method: req.method,
		path: req.url, headers: headers,
	}, (upRes) => {
		res.writeHead(upRes.statusCode || 502, upRes.headers);
		upRes.pipe(res);
	});
	up.on('error', () => { if (!res.headersSent) res.writeHead(502); res.end('upstream error'); });
	req.pipe(up);
}

// WebSocket (kasm /websockify): gate on the cookie, then splice raw TCP.
server.on('upgrade', (req, socket, head) => {
	if (!isAuthed(req)) { socket.destroy(); return; }
	const up = net.connect(UPSTREAM, '127.0.0.1', () => {
		// replay the client's upgrade request, injecting the kasm Basic
		// header (skip any client-sent Authorization so ours wins)
		let raw = `${req.method} ${req.url} HTTP/1.1\r\n`;
		for (let i = 0; i < req.rawHeaders.length; i += 2) {
			if (req.rawHeaders[i].toLowerCase() === 'authorization') continue;
			raw += `${req.rawHeaders[i]}: ${req.rawHeaders[i + 1]}\r\n`;
		}
		const auth = upstreamAuth();
		if (auth) raw += `Authorization: ${auth}\r\n`;
		raw += '\r\n';
		up.write(raw);
		if (head && head.length) up.write(head);
		socket.pipe(up);
		up.pipe(socket);
	});
	up.on('error', () => socket.destroy());
	socket.on('error', () => up.destroy());
});

server.listen(PORT, '127.0.0.1', () => {
	console.error(`[gateway] listening on 127.0.0.1:${PORT}`
		+ ` -> kasm 127.0.0.1:${UPSTREAM}`);
});

/*
 * sw.js — minimal service worker for the Coworkstation PWA.
 *
 * Just enough for installability + an offline login shell. The live
 * session is a WebSocket to kasm, so we deliberately DO NOT cache app
 * traffic — only the static login shell + icon. Everything else falls
 * straight through to the network.
 */
'use strict';

var CACHE = 'cws-shell-v1';
var SHELL = ['/cws-login', '/cws-app.js', '/cws-icon.svg', '/manifest.webmanifest'];

self.addEventListener('install', function (e) {
  e.waitUntil(caches.open(CACHE).then(function (c) {
    return c.addAll(SHELL);
  }).then(function () { return self.skipWaiting(); }));
});

self.addEventListener('activate', function (e) {
  e.waitUntil(caches.keys().then(function (keys) {
    return Promise.all(keys.filter(function (k) { return k !== CACHE; })
      .map(function (k) { return caches.delete(k); }));
  }).then(function () { return self.clients.claim(); }));
});

self.addEventListener('fetch', function (e) {
  var url = new URL(e.request.url);
  // Only the static shell is cache-first; never intercept the session,
  // the WebSocket, or the login POST.
  if (e.request.method === 'GET' && SHELL.indexOf(url.pathname) >= 0) {
    e.respondWith(caches.match(e.request).then(function (hit) {
      return hit || fetch(e.request);
    }));
  }
  // else: default network handling
});

/*
 * cws-app.js — login-page behavior for the Coworkstation kiosk PWA.
 * Pure vanilla JS, no deps. Runs only on the login shell.
 */
(function () {
  'use strict';

  // Forward the real devicePixelRatio so the gateway can record it for
  // cws-launch's --force-device-scale-factor (crisp HiDPI rendering).
  var dpr = document.getElementById('dpr');
  if (dpr) dpr.value = String(window.devicePixelRatio || 1);

  // Surface a failed attempt (?e=1) without leaking anything in markup.
  if (/[?&]e=1(&|$)/.test(location.search)) {
    var err = document.getElementById('err');
    if (err) err.textContent = 'Incorrect password. Try again.';
  }

  // iOS/iPadOS has no install prompt: hint "Add to Home Screen" once, when
  // running in a browser tab (not already installed as a standalone PWA).
  var isIOS = /iP(hone|ad|od)/.test(navigator.platform || '') ||
    (navigator.userAgent.indexOf('Mac') >= 0 && 'ontouchend' in document);
  var standalone = window.navigator.standalone === true ||
    (window.matchMedia && window.matchMedia('(display-mode: standalone)').matches);
  if (isIOS && !standalone) {
    var hint = document.getElementById('hint');
    if (hint) hint.textContent =
      'Tip: tap Share, then "Add to Home Screen" for the full-screen app.';
  }

  // Register the service worker so the app is installable. Best-effort.
  if ('serviceWorker' in navigator) {
    window.addEventListener('load', function () {
      navigator.serviceWorker.register('/sw.js').catch(function () {});
    });
  }
})();

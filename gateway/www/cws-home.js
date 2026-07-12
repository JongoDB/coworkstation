/*
 * cws-home.js — homepage behavior. Reveals the admin section only for the
 * owner. This is cosmetic: the /admin routes themselves 404 on a member
 * gateway, so the real gate is server-side.
 */
(function () {
  'use strict';
  fetch('/api/me', { credentials: 'same-origin' })
    .then(function (r) { return r.json(); })
    .then(function (me) {
      if (me && me.role === 'admin') {
        var el = document.getElementById('admin');
        if (el) el.style.display = 'block';
      }
    })
    .catch(function () { /* stay member-only on error */ });

  if ('serviceWorker' in navigator) {
    navigator.serviceWorker.register('/sw.js').catch(function () {});
  }
})();

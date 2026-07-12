/*
 * cws-admin.js — renders the read-only fleet snapshot (v1 monitoring).
 * Polls /api/fleet (a file the root collector writes) every 20s.
 */
(function () {
  'use strict';

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"]/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c];
    });
  }
  function stateClass(s) {
    if (s === 'active') return 'active';
    if (s === 'idle') return 'idle';
    return 'down';
  }

  function render(f) {
    var members = (f && f.members) || [];
    var mb = document.getElementById('members');
    mb.innerHTML = members.length ? members.map(function (m) {
      return '<tr><td>' + esc(m.name) + '</td>'
        + '<td><span class="pill ' + stateClass(m.state) + '">'
          + esc(m.state || 'unknown') + '</span></td>'
        + '<td class="muted">:' + esc(m.display) + '</td>'
        + '<td>' + esc(m.usageTokens != null ? m.usageTokens : '—') + '</td>'
        + '<td class="muted">' + esc(m.lastActivity || '—') + '</td></tr>';
    }).join('') : '<tr><td colspan="5" class="empty">No members.</td></tr>';

    var dr = document.getElementById('devicerows');
    var rows = [];
    members.forEach(function (m) {
      (m.devices || []).forEach(function (d) {
        rows.push('<tr><td>' + esc(m.name) + '</td><td>' + esc(d.name || d.id)
          + '</td><td class="muted">' + esc(d.lastSeen || '—') + '</td></tr>');
      });
    });
    dr.innerHTML = rows.length ? rows.join('')
      : '<tr><td colspan="3" class="empty">No devices seen yet.</td></tr>';

    var au = document.getElementById('audit');
    var events = (f && f.audit) || [];
    au.innerHTML = events.length ? events.map(function (e) {
      return '<li><time>' + esc(e.ts || '') + '</time>' + esc(e.text || e.event || '')
        + '</li>';
    }).join('') : '<li class="empty">No recent activity.</li>';

    var stale = document.getElementById('stale');
    if (f && f.generated) stale.textContent = 'updated ' + esc(f.generated);
    if (f && f.error) stale.textContent = f.error;
  }

  function poll() {
    fetch('/api/fleet', { credentials: 'same-origin' })
      .then(function (r) { return r.json(); })
      .then(render)
      .catch(function () {});
  }
  poll();
  setInterval(poll, 20000);
})();

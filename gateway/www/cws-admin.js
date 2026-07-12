/*
 * cws-admin.js — renders the read-only fleet snapshot (v1 monitoring) into
 * three tabs (Monitoring / Devices / Members). Polls /api/fleet every 20s.
 */
(function () {
  'use strict';

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"]/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c];
    });
  }
  function stateClass(s) {
    return s === 'active' ? 'active' : (s === 'idle' ? 'idle' : 'down');
  }

  // --- tabs ---
  function tabs() { return Array.prototype.slice.call(document.querySelectorAll('nav.tabs a')); }
  function selectTab(name) {
    var n = name || 'monitoring';
    tabs().forEach(function (a) { a.classList.toggle('active', a.dataset.tab === n); });
    ['monitoring', 'devices', 'members'].forEach(function (t) {
      var el = document.getElementById('tab-' + t);
      if (el) el.classList.toggle('active', t === n);
    });
  }
  function currentTab() { return (location.hash || '#monitoring').replace('#', ''); }
  window.addEventListener('hashchange', function () { selectTab(currentTab()); });

  // --- render ---
  function render(f) {
    var members = (f && f.members) || [];

    document.getElementById('members').innerHTML = members.length
      ? members.map(function (m) {
        return '<tr><td>' + esc(m.name) + '</td>'
          + '<td><span class="pill ' + stateClass(m.state) + '">'
            + esc(m.state || 'unknown') + '</span></td>'
          + '<td class="muted">:' + esc(m.display) + '</td>'
          + '<td>' + esc(m.usageTokens != null ? m.usageTokens : '—') + '</td>'
          + '<td class="muted">' + esc(m.lastActivity || '—') + '</td></tr>';
      }).join('')
      : '<tr><td colspan="5" class="empty">No members.</td></tr>';

    document.getElementById('roster').innerHTML = members.length
      ? members.map(function (m) {
        return '<tr><td>' + esc(m.name) + '</td><td class="muted">:'
          + esc(m.display) + '</td><td><span class="pill ' + stateClass(m.state)
          + '">' + esc(m.state || 'unknown') + '</span></td></tr>';
      }).join('')
      : '<tr><td colspan="3" class="empty">No members.</td></tr>';

    var rows = [];
    members.forEach(function (m) {
      (m.devices || []).forEach(function (d) {
        rows.push('<tr><td>' + esc(m.name) + '</td><td>' + esc(d.name || d.id)
          + '</td><td class="muted">' + esc(d.lastSeen || '—') + '</td></tr>');
      });
    });
    document.getElementById('devicerows').innerHTML = rows.length ? rows.join('')
      : '<tr><td colspan="3" class="empty">No devices seen yet.</td></tr>';

    var events = (f && f.audit) || [];
    document.getElementById('audit').innerHTML = events.length
      ? events.map(function (e) {
        return '<li><time>' + esc(e.ts || '') + '</time>'
          + esc(e.text || e.event || '') + '</li>';
      }).join('')
      : '<li class="empty">No recent activity.</li>';

    var stale = document.getElementById('stale');
    if (f && f.error) stale.textContent = f.error;
    else if (f && f.generated) stale.textContent = 'Updated ' + esc(f.generated);
  }

  function poll() {
    fetch('/api/fleet', { credentials: 'same-origin' })
      .then(function (r) { return r.json(); }).then(render).catch(function () {});
  }

  selectTab(currentTab());
  poll();
  setInterval(poll, 20000);
})();

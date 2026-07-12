/*
 * cws-admin.js — read-only fleet snapshot (Monitoring/Devices/Members
 * tabs) plus tier C/B actions (session control, reclaim, member add/remove)
 * via POST /api/action. Destructive actions re-prompt for the password.
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

  var toast = document.getElementById('toast');
  var toastTimer;
  function showToast(msg, kind) {
    toast.textContent = msg;
    toast.className = kind || '';
    toast.style.display = 'block';
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { toast.style.display = 'none'; }, 5000);
  }

  // POST an action; returns a promise of the result object.
  function callAction(payload, btn) {
    if (btn) btn.disabled = true;
    showToast('Working…', '');
    return fetch('/api/action', {
      method: 'POST', credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    }).then(function (r) { return r.json(); }).then(function (res) {
      showToast(res.ok ? 'Done.' : ('Failed: ' + (res.output || 'error')),
        res.ok ? 'ok' : 'err');
      poll();
      return res;
    }).catch(function () { showToast('Request failed.', 'err'); })
      .finally(function () { if (btn) btn.disabled = false; });
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
        var n = esc(m.name);
        return '<tr><td>' + n + '</td>'
          + '<td><span class="pill ' + stateClass(m.state) + '">'
            + esc(m.state || 'unknown') + '</span></td>'
          + '<td class="muted">:' + esc(m.display) + '</td>'
          + '<td>' + esc(m.usageTokens != null ? m.usageTokens : '—') + '</td>'
          + '<td><button class="act" data-act="session.restart" data-user="' + n
            + '">Restart</button><button class="act" data-act="session.stop" data-user="'
            + n + '">Stop</button></td></tr>';
      }).join('')
      : '<tr><td colspan="5" class="empty">No members.</td></tr>';

    document.getElementById('roster').innerHTML = members.length
      ? members.map(function (m) {
        var n = esc(m.name);
        var rm = m.owner ? '<span class="muted">owner</span>'
          : '<button class="act danger" data-act="member.remove" data-user="' + n
            + '">Remove</button>';
        return '<tr><td>' + n + '</td><td class="muted">:' + esc(m.display)
          + '</td><td><span class="pill ' + stateClass(m.state) + '">'
          + esc(m.state || 'unknown') + '</span></td><td>' + rm + '</td></tr>';
      }).join('')
      : '<tr><td colspan="4" class="empty">No members.</td></tr>';

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

  // --- action wiring (event delegation) ---
  document.addEventListener('click', function (e) {
    var btn = e.target.closest && e.target.closest('button[data-act]');
    if (!btn) return;
    var act = btn.dataset.act;
    var user = btn.dataset.user || '';
    if (act === 'member.remove') {
      if (!confirm('Remove member "' + user + '"? This deletes their account'
        + ' and home directory.')) return;
      var pw = prompt('Confirm your password to remove "' + user + '":');
      if (!pw) return;
      callAction({ action: act, user: user, password: pw }, btn);
    } else if (act === 'reclaim') {
      if (confirm('Stop idle sessions now?')) callAction({ action: act }, btn);
    } else {
      callAction({ action: act, user: user }, btn);
    }
  });

  var addForm = document.getElementById('addForm');
  if (addForm) addForm.addEventListener('submit', function (e) {
    e.preventDefault();
    var d = new FormData(addForm);
    callAction({
      action: 'member.add', user: (d.get('user') || '').trim(),
      mem: (d.get('mem') || '').trim(), cpu: (d.get('cpu') || '').trim(),
      allow: (d.get('allow') || '').trim(),
    }).then(function (res) { if (res && res.ok) addForm.reset(); });
  });

  function poll() {
    fetch('/api/fleet', { credentials: 'same-origin' })
      .then(function (r) { return r.json(); }).then(render).catch(function () {});
  }

  selectTab(currentTab());
  poll();
  setInterval(poll, 20000);
})();

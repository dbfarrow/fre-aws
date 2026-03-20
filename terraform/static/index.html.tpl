<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Claude Code</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }

    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;
      background: #0f1117;
      color: #e0e0e0;
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
    }

    .card {
      background: #1a1d27;
      border: 1px solid #2a2d3a;
      border-radius: 12px;
      padding: 40px;
      width: 420px;
      max-width: 95vw;
    }

    h1 { font-size: 1.4rem; color: #fff; margin-bottom: 6px; }

    .subtitle {
      color: #666;
      font-size: 0.85rem;
      margin-bottom: 32px;
    }

    .status-row {
      display: flex;
      align-items: center;
      gap: 12px;
      margin-bottom: 28px;
    }

    .dot {
      width: 12px;
      height: 12px;
      border-radius: 50%;
      flex-shrink: 0;
      transition: background 0.4s;
    }

    .dot-grey   { background: #484860; }
    .dot-yellow { background: #f5a623; }
    .dot-green  { background: #27ae60; }

    .dot-pulse {
      animation: pulse 1.5s ease-in-out infinite;
    }

    @keyframes pulse {
      0%, 100% { opacity: 1; }
      50%       { opacity: 0.35; }
    }

    .status-label { color: #aaa; font-size: 0.95rem; }
    .uptime-label { color: #555; font-size: 0.78rem; margin-top: 3px; }

    .buttons {
      display: flex;
      flex-direction: column;
      gap: 10px;
    }

    button {
      padding: 13px 20px;
      border: none;
      border-radius: 8px;
      font-size: 0.95rem;
      font-weight: 500;
      cursor: pointer;
      transition: opacity 0.2s;
      width: 100%;
    }

    button:disabled {
      opacity: 0.3;
      cursor: default;
    }

    button:not(:disabled):hover { opacity: 0.82; }

    .btn-terminal {
      background: #6c63ff;
      color: #fff;
      font-size: 1.05rem;
      padding: 15px 20px;
    }

    .btn-start { background: #2d6a4f; color: #fff; }
    .btn-stop  { background: #7b3535; color: #fff; }

    .error-inline {
      color: #e74c3c;
      font-size: 0.85rem;
      margin-top: 14px;
      min-height: 1.2em;
    }

    .info-page {
      color: #888;
      font-size: 0.92rem;
      line-height: 1.6;
      text-align: center;
    }

    .info-page a { color: #6c63ff; }
  </style>
</head>
<body>
<div class="card" id="root">

  <!-- Loading state (shown on init) -->
  <div id="view-loading" class="info-page">Loading&hellip;</div>

  <!-- Dashboard (shown when authenticated) -->
  <div id="view-dashboard" style="display:none">
    <h1>Claude Code</h1>
    <div class="subtitle" id="el-username"></div>

    <div class="status-row">
      <div class="dot dot-grey dot-pulse" id="el-dot"></div>
      <div>
        <div class="status-label" id="el-status">Checking&hellip;</div>
        <div class="uptime-label" id="el-uptime"></div>
      </div>
    </div>

    <div class="buttons">
      <button class="btn-terminal" id="btn-terminal" disabled onclick="openTerminal()">
        Open Terminal
      </button>
      <button class="btn-start" id="btn-start" disabled onclick="startInstance()">
        Start Instance
      </button>
      <button class="btn-stop" id="btn-stop" disabled onclick="stopInstance()">
        Stop Instance
      </button>
    </div>

    <div class="error-inline" id="el-error"></div>
  </div>

  <!-- Error / expired page -->
  <div id="view-error" style="display:none" class="info-page">
    <p id="el-error-msg"></p>
  </div>

</div>

<script>
(function () {
  'use strict';

  var API = '${api_url}'.replace(/\/$/, '');
  var username = null;
  var pollHandle = null;
  var lastState = {};

  // ---- View helpers --------------------------------------------------------

  function showView(id) {
    ['view-loading', 'view-dashboard', 'view-error'].forEach(function (v) {
      document.getElementById(v).style.display = v === id ? '' : 'none';
    });
  }

  function showErrorPage(html) {
    document.getElementById('el-error-msg').innerHTML = html;
    showView('view-error');
  }

  // ---- JWT storage ---------------------------------------------------------

  function jwtKey(u) { return 'jwt_' + u; }
  function getJwt(u) { return localStorage.getItem(jwtKey(u)); }
  function setJwt(u, t) { localStorage.setItem(jwtKey(u), t); }

  // ---- Login (magic link) --------------------------------------------------

  function doLogin(token) {
    fetch(API + '/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token: token })
    })
      .then(function (r) {
        if (!r.ok) throw new Error('login failed');
        return r.json();
      })
      .then(function (data) {
        setJwt(data.username, data.jwt);
        // Redirect to stable, bookmarkable URL (strips token from query string)
        window.location.replace('/u/' + data.username);
      })
      .catch(function () {
        showErrorPage(
          'Your invitation link is invalid or has expired.<br>' +
          'Please contact your admin for a new link.'
        );
      });
  }

  // ---- Dashboard -----------------------------------------------------------

  function startDashboard(u) {
    username = u;
    document.getElementById('el-username').textContent = u;
    showView('view-dashboard');
    pollStatus();
    pollHandle = setInterval(pollStatus, 10000);
  }

  function pollStatus() {
    var jwt = getJwt(username);
    if (!jwt) { handleExpired(); return; }

    fetch(API + '/status', {
      headers: { 'Authorization': 'Bearer ' + jwt }
    })
      .then(function (r) {
        if (r.status === 401) { handleExpired(); return null; }
        return r.json();
      })
      .then(function (data) {
        if (data) updateUI(data);
      })
      .catch(function () {
        setStatus('Connection error', 'grey', false);
      });
  }

  function handleExpired() {
    if (pollHandle) clearInterval(pollHandle);
    showErrorPage(
      'Your session has expired.<br>' +
      'Please ask your admin to send a new <a href="mailto:admin">invitation link</a>.'
    );
  }

  function updateUI(data) {
    lastState = data;
    var state = data.ec2_state;
    var ready = data.ssm_ready;

    var dotColor = 'grey', label = '', pulse = false;

    if (state === 'not_found' || state === 'terminated' || state === 'shutting-down') {
      label = 'Instance not available';
    } else if (state === 'stopped') {
      label = 'Instance stopped';
    } else if (state === 'pending') {
      dotColor = 'yellow'; pulse = true; label = 'Starting\u2026';
    } else if (state === 'stopping') {
      dotColor = 'yellow'; pulse = true; label = 'Stopping\u2026';
    } else if (state === 'running' && !ready) {
      dotColor = 'yellow'; label = 'Running \u2014 agent connecting\u2026';
    } else if (state === 'running' && ready) {
      dotColor = 'green'; label = 'Ready';
    }

    setStatus(label, dotColor, pulse);

    var uptimeEl = document.getElementById('el-uptime');
    if (data.uptime && state === 'running') {
      var since = new Date(data.uptime);
      uptimeEl.textContent = 'Up since ' +
        since.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    } else {
      uptimeEl.textContent = '';
    }

    document.getElementById('btn-start').disabled    = state !== 'stopped';
    document.getElementById('btn-stop').disabled     = state !== 'running';
    document.getElementById('btn-terminal').disabled = !(state === 'running' && ready);
  }

  function setStatus(label, color, pulse) {
    var dot = document.getElementById('el-dot');
    dot.className = 'dot dot-' + color + (pulse ? ' dot-pulse' : '');
    document.getElementById('el-status').textContent = label;
  }

  function flashError(msg) {
    var el = document.getElementById('el-error');
    el.textContent = msg;
    setTimeout(function () { el.textContent = ''; }, 5000);
  }

  // ---- Button actions ------------------------------------------------------

  function startInstance() {
    document.getElementById('btn-start').disabled = true;
    authFetch('/start', 'POST')
      .then(function (r) {
        if (!r.ok) throw new Error();
        setStatus('Starting\u2026', 'yellow', true);
      })
      .catch(function () {
        flashError('Failed to start instance. Please try again.');
        document.getElementById('btn-start').disabled = false;
      });
  }

  function stopInstance() {
    document.getElementById('btn-stop').disabled = true;
    authFetch('/stop', 'POST')
      .then(function (r) {
        if (!r.ok) throw new Error();
        setStatus('Stopping\u2026', 'yellow', true);
      })
      .catch(function () {
        flashError('Failed to stop instance. Please try again.');
        document.getElementById('btn-stop').disabled = false;
      });
  }

  function openTerminal() {
    document.getElementById('btn-terminal').disabled = true;
    authFetch('/terminal', 'GET')
      .then(function (r) {
        if (!r.ok) throw new Error();
        return r.json();
      })
      .then(function (data) {
        window.open(data.url, '_blank');
      })
      .catch(function () {
        flashError('Failed to open terminal. Please try again.');
      })
      .finally(function () {
        var s = lastState;
        document.getElementById('btn-terminal').disabled =
          !(s.ec2_state === 'running' && s.ssm_ready);
      });
  }

  function authFetch(path, method) {
    return fetch(API + path, {
      method: method,
      headers: { 'Authorization': 'Bearer ' + getJwt(username) }
    });
  }

  // Expose button handlers to onclick attributes
  window.startInstance = startInstance;
  window.stopInstance  = stopInstance;
  window.openTerminal  = openTerminal;

  // ---- Router (runs on page load) ------------------------------------------

  var path   = window.location.pathname;
  var params = new URLSearchParams(window.location.search);
  var userMatch = path.match(/^\/u\/([^/]+)$/);

  if (userMatch) {
    var u = userMatch[1];
    var stored = getJwt(u);
    if (stored) {
      startDashboard(u);
    } else {
      var tok = params.get('token');
      if (tok) {
        doLogin(tok);
      } else {
        showErrorPage(
          'Your session has expired.<br>' +
          'Please ask your admin to send a new <a href="mailto:admin">invitation link</a>.'
        );
      }
    }
  } else if (params.has('token')) {
    doLogin(params.get('token'));
  } else {
    showErrorPage(
      'No invitation link found.<br>' +
      'Please ask your admin for access.'
    );
  }

}());
</script>
</body>
</html>

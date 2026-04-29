/* ═══════════════════════════════════════════════════════════
   Panel Naive + Hy2 by RIXXX — Frontend App
   ═══════════════════════════════════════════════════════════ */

'use strict';

// ─── STATE ───────────────────────────────────────────────
let currentPage      = 'dashboard';
let currentInstallTab = 'naive';   // naive | hy2 | both
let currentUsersTab   = 'naive';   // naive | hy2
let ws = null;
let installRunning = false;
let deleteUserTarget = null;       // { kind: 'naive'|'hy2', username }
let currentStatus = null;

// ─── INIT ─────────────────────────────────────────────────
document.addEventListener('DOMContentLoaded', () => {
  checkAuth();

  document.getElementById('loginForm').addEventListener('submit', async (e) => {
    e.preventDefault();
    await doLogin();
  });
  document.getElementById('logoutBtn').addEventListener('click', doLogout);

  document.querySelectorAll('.nav-item').forEach(item => {
    item.addEventListener('click', (e) => { e.preventDefault(); goToPage(item.dataset.page); });
  });

  document.getElementById('refreshStatusBtn').addEventListener('click', loadDashboard);

  // Prefill passwords on install page
  genPwdInto('installNaivePassword');
  genPwdInto('installHy2Password');
});

// ─── AUTH ────────────────────────────────────────────────
async function checkAuth() {
  try {
    const res = await fetch('/api/me');
    if (res.ok) {
      const data = await res.json();
      showApp(data.username);
    } else { showLogin(); }
  } catch { showLogin(); }
}

function showLogin() {
  document.getElementById('loginPage').classList.remove('hidden');
  document.getElementById('app').classList.add('hidden');
}

function showApp(username) {
  document.getElementById('loginPage').classList.add('hidden');
  document.getElementById('app').classList.remove('hidden');
  if (username) {
    document.getElementById('sidebarUsername').textContent = username;
    document.getElementById('sidebarUserAvatar').textContent = username[0].toUpperCase();
  }
  goToPage('dashboard');
}

async function doLogin() {
  const username = document.getElementById('loginUsername').value.trim();
  const password = document.getElementById('loginPassword').value;
  const errEl = document.getElementById('loginError');
  const btn = document.querySelector('#loginForm button[type="submit"]');
  const btnText = btn.querySelector('.btn-text');
  const btnLoader = btn.querySelector('.btn-loader');

  if (!username || !password) { showAlert(errEl, 'Заполните все поля', 'error'); return; }

  btn.disabled = true; btnText.classList.add('hidden'); btnLoader.classList.remove('hidden');
  errEl.classList.add('hidden');

  try {
    const res = await fetch('/api/login', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username, password })
    });
    const data = await res.json();
    if (data.success) showApp(username);
    else showAlert(errEl, data.message || 'Ошибка входа', 'error');
  } catch {
    showAlert(errEl, 'Ошибка соединения с сервером', 'error');
  } finally {
    btn.disabled = false; btnText.classList.remove('hidden'); btnLoader.classList.add('hidden');
  }
}

async function doLogout() {
  await fetch('/api/logout', { method: 'POST' });
  showLogin();
}

// ─── NAVIGATION ─────────────────────────────────────────
function goToPage(page) {
  currentPage = page;
  document.querySelectorAll('.page').forEach(p => p.classList.remove('active'));
  document.querySelectorAll('.nav-item').forEach(n => n.classList.remove('active'));
  const pageEl = document.getElementById(page + 'Page');
  if (pageEl) pageEl.classList.add('active');
  const navEl = document.querySelector(`.nav-item[data-page="${page}"]`);
  if (navEl) navEl.classList.add('active');

  if (page === 'dashboard') loadDashboard();
  if (page === 'users') loadUsers();
  if (page === 'tuning') loadTuning();
  if (page === 'diag') loadDiagPorts();
  if (page === 'bypass') loadBypass();
  if (page === 'settings') loadSettingsInfo();
}

// ─── SETTINGS — динамическая версия панели ──────────────
async function loadSettingsInfo() {
  const el = document.getElementById('panelVersion');
  if (!el) return;
  try {
    const res = await fetch('/api/system/version');
    if (!res.ok) throw new Error('HTTP ' + res.status);
    const d = await res.json();
    el.textContent = d.version || '—';
    if (d.source === 'fallback') {
      el.title = 'Файл /etc/rixxx-panel/version не найден — показана версия по умолчанию';
    } else {
      el.title = 'Из /etc/rixxx-panel/version';
    }
  } catch (e) {
    el.textContent = '—';
    el.title = 'Не удалось получить версию: ' + e.message;
  }
}

// ─── DIAGNOSTICS ────────────────────────────────────────
async function loadDiagPorts() {
  const box = document.getElementById('diagPortsBox');
  if (!box) return;
  box.textContent = 'Загружаю...';
  try {
    const res = await fetch('/api/diag/ports');
    const d = await res.json();
    box.textContent = d.output || '(пусто)';
  } catch (e) {
    box.textContent = 'Ошибка: ' + e.message;
  }
}

async function loadDiagLogs(kind) {
  const id = kind === 'naive' ? 'diagLogNaive' : 'diagLogHy2';
  const box = document.getElementById(id);
  if (!box) return;
  box.textContent = 'Загружаю...';
  try {
    const res = await fetch('/api/logs/' + kind + '?lines=80');
    const d = await res.json();
    box.textContent = (d.output || '(пусто)').slice(-8000);
    // Скролл вниз
    box.scrollTop = box.scrollHeight;
  } catch (e) {
    box.textContent = 'Ошибка: ' + e.message;
  }
}

async function loadDiagHysteriaConfig() {
  const box = document.getElementById('diagHysteriaCfg');
  if (!box) return;
  box.textContent = 'Загружаю...';
  try {
    const res = await fetch('/api/diag/hysteria-config');
    const d = await res.json();
    box.textContent = d.output || '(пусто)';
  } catch (e) {
    box.textContent = 'Ошибка: ' + e.message;
  }
}

async function fixHy2Tls() {
  const box = document.getElementById('fixHy2Result');
  if (!box) return;
  box.textContent = 'Ищем cert Caddy на диске, переписываем Hy2 конфиг, перезапускаем...';
  try {
    const res = await fetch('/api/diag/fix-hy2-tls', { method: 'POST' });
    const d = await res.json();
    const prefix = d.ok ? '✅ ' : '⚠ ';
    const lines = [
      prefix + (d.message || d.error || 'Готово'),
      d.ca      ? ('CA: ' + d.ca) : null,
      d.certPath ? ('cert: ' + d.certPath) : null,
      d.keyPath  ? ('key:  ' + d.keyPath) : null,
      d.hint     ? ('Подсказка: ' + d.hint) : null,
      d.details  ? ('Детали: ' + d.details) : null
    ].filter(Boolean);
    box.textContent = lines.join('\n');
    if (d.ok && typeof showToast === 'function') showToast('Hy2 TLS починен', 'success');
    if (!d.ok && typeof showToast === 'function') showToast('Починка не удалась', 'error');
  } catch (e) {
    box.textContent = 'Ошибка запроса: ' + e.message;
  }
}

// ─── DASHBOARD ──────────────────────────────────────────
async function loadDashboard() {
  try {
    const res = await fetch('/api/status');
    const data = await res.json();
    currentStatus = data;

    // Общая инфа
    document.getElementById('serverDomain').textContent = data.domain || '—';
    document.getElementById('serverIp').textContent = data.serverIp || '—';
    document.getElementById('serverArch').textContent = data.arch || '—';
    const total = (data.naive?.usersCount || 0) + (data.hy2?.usersCount || 0);
    document.getElementById('totalUsers').textContent = total;

    // NaiveProxy карточка
    if (data.stack?.naive) {
      document.getElementById('naiveNotInstalled').classList.add('hidden');
      document.getElementById('naiveInstalled').classList.remove('hidden');
      document.getElementById('naiveUsersCount').textContent = data.naive.usersCount || 0;
      setStatusBadge('naiveStatusBadge', data.naive.active);
    } else {
      document.getElementById('naiveNotInstalled').classList.remove('hidden');
      document.getElementById('naiveInstalled').classList.add('hidden');
      setStatusBadge('naiveStatusBadge', null);
    }

    // Hy2 карточка
    if (data.stack?.hy2) {
      document.getElementById('hy2NotInstalled').classList.add('hidden');
      document.getElementById('hy2Installed').classList.remove('hidden');
      document.getElementById('hy2UsersCount').textContent = data.hy2.usersCount || 0;
      setStatusBadge('hy2StatusBadge', data.hy2.active);
    } else {
      document.getElementById('hy2NotInstalled').classList.remove('hidden');
      document.getElementById('hy2Installed').classList.add('hidden');
      setStatusBadge('hy2StatusBadge', null);
    }

    // Quick links
    await renderQuickLinks(data);

  } catch (err) {
    console.error('dashboard error', err);
  }
}

function setStatusBadge(id, active) {
  const el = document.getElementById(id);
  if (active === null || active === undefined) {
    el.innerHTML = '<span class="dot dot-gray"></span> не установлен';
  } else if (active) {
    el.innerHTML = '<span class="dot dot-green"></span> работает';
  } else {
    el.innerHTML = '<span class="dot dot-red"></span> остановлен';
  }
}

async function renderQuickLinks(status) {
  const emptyEl = document.getElementById('quickLinksEmpty');
  const listEl = document.getElementById('quickLinksList');

  if (!status.installed || !status.domain) {
    emptyEl.classList.remove('hidden');
    listEl.classList.add('hidden');
    listEl.innerHTML = '';
    return;
  }

  listEl.innerHTML = '';
  let hasAny = false;

  // Naive ссылки
  if (status.stack.naive) {
    try {
      const r = await fetch('/api/naive/users');
      const { users } = await r.json();
      users.slice(0, 3).forEach(u => {
        hasAny = true;
        const link = `naive+https://${u.username}:${u.password}@${status.domain}:443`;
        listEl.innerHTML += `
          <div class="quick-link-item">
            <span class="ql-type naive-tag">Naive</span>
            <span class="ql-user">${escapeHtml(u.username)}</span>
            <span class="ql-url">${escapeHtml(link)}</span>
            <button class="quick-link-copy" onclick="copyText('${escapeHtml(link)}')">Копировать</button>
          </div>`;
      });
    } catch {}
  }

  // Hy2 ссылки
  if (status.stack.hy2) {
    try {
      const r = await fetch('/api/hy2/users');
      const { users } = await r.json();
      users.slice(0, 3).forEach(u => {
        hasAny = true;
        // userpass: в URI auth = username:password (см. docs hysteria2 URI-Scheme)
        const link = `hysteria2://${encodeURIComponent(u.username)}:${encodeURIComponent(u.password)}@${status.domain}:443?sni=${status.domain}&insecure=0#${encodeURIComponent(u.username)}`;
        listEl.innerHTML += `
          <div class="quick-link-item">
            <span class="ql-type hy2-tag">Hy2</span>
            <span class="ql-user">${escapeHtml(u.username)}</span>
            <span class="ql-url">${escapeHtml(link)}</span>
            <button class="quick-link-copy" onclick="copyText('${escapeHtml(link)}')">Копировать</button>
          </div>`;
      });
    } catch {}
  }

  if (hasAny) {
    emptyEl.classList.add('hidden');
    listEl.classList.remove('hidden');
  } else {
    emptyEl.classList.remove('hidden');
    listEl.classList.add('hidden');
  }
}

async function serviceAction(kind, action) {
  const label = kind === 'naive' ? 'Caddy' : 'Hysteria2';
  const badgeId = kind === 'naive' ? 'naiveStatusBadge' : 'hy2StatusBadge';
  showToast(`${label}: ${action}...`, 'info');
  try {
    const res = await fetch(`/api/service/${kind}/${action}`, { method: 'POST' });
    const data = await res.json();
    showToast(data.message, data.success ? 'success' : 'error');
    // Обновляем бейдж немедленно по ответу сервера
    if (data.success && data.active !== undefined && data.active !== null) {
      setStatusBadge(badgeId, data.active);
    }
    // Затем через 2с — полное обновление дашборда
    setTimeout(loadDashboard, 2000);
  } catch {
    showToast('Ошибка соединения', 'error');
  }
}

// ─── INSTALL ────────────────────────────────────────────
function switchInstallTab(tab) {
  currentInstallTab = tab;
  document.querySelectorAll('#installPage .tab-btn').forEach(b => {
    b.classList.toggle('active', b.dataset.tab === tab);
  });

  const naiveFields = document.getElementById('naiveFields');
  const hy2Fields = document.getElementById('hy2Fields');
  const title = document.getElementById('installFormTitle');
  const note = document.getElementById('installNote');

  if (tab === 'naive') {
    naiveFields.classList.remove('hidden');
    hy2Fields.classList.add('hidden');
    title.textContent = 'Параметры NaiveProxy';
    note.innerHTML = '<strong>ℹ NaiveProxy</strong> — TCP/443, HTTP/2 forward proxy через Caddy. Маскируется под сайт.';
  } else if (tab === 'hy2') {
    naiveFields.classList.add('hidden');
    hy2Fields.classList.remove('hidden');
    title.textContent = 'Параметры Hysteria2';
    note.innerHTML = '<strong>⚡ Hysteria2</strong> — UDP/443, QUIC-based. Свой congestion control Brutal. Быстрый.';
  } else { // both
    naiveFields.classList.remove('hidden');
    hy2Fields.classList.remove('hidden');
    title.textContent = 'Naive + Hysteria2 на одном сервере';
    note.innerHTML = '<strong>✨ Оба протокола</strong> на одном домене и порту 443 (TCP + UDP). Hy2 использует сертификат Caddy.';
  }
}

function genPwdInto(elId) {
  const chars = 'ABCDEFGHJKMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789';
  let pwd = '';
  for (let i = 0; i < 20; i++) pwd += chars[Math.floor(Math.random() * chars.length)];
  const el = document.getElementById(elId);
  if (el) el.value = pwd;
}

function startInstall() {
  if (installRunning) return;

  const domain = document.getElementById('installDomain').value.trim();
  const email = document.getElementById('installEmail').value.trim();
  const alertEl = document.getElementById('installAlert');

  if (!domain || !email) { showAlert(alertEl, '❌ Заполните домен и email', 'error'); return; }
  if (!domain.includes('.')) { showAlert(alertEl, '❌ Неверный домен', 'error'); return; }
  if (!email.includes('@')) { showAlert(alertEl, '❌ Неверный email', 'error'); return; }

  // Payload по табу
  let payload;
  if (currentInstallTab === 'naive') {
    const login = document.getElementById('installNaiveLogin').value.trim();
    const password = document.getElementById('installNaivePassword').value.trim();
    if (!login) { showAlert(alertEl, '❌ Введите логин Naive', 'error'); return; }
    if (password.length < 8) { showAlert(alertEl, '❌ Пароль Naive минимум 8 символов', 'error'); return; }
    payload = { type: 'install_naive', domain, email, login, password };
  } else if (currentInstallTab === 'hy2') {
    const password = document.getElementById('installHy2Password').value.trim();
    if (password.length < 8) { showAlert(alertEl, '❌ Пароль Hy2 минимум 8 символов', 'error'); return; }
    payload = { type: 'install_hy2', domain, email, password, useCaddyCert: false };
  } else {
    const naiveLogin = document.getElementById('installNaiveLogin').value.trim();
    const naivePassword = document.getElementById('installNaivePassword').value.trim();
    const hy2Password = document.getElementById('installHy2Password').value.trim();
    if (!naiveLogin) { showAlert(alertEl, '❌ Введите логин Naive', 'error'); return; }
    if (naivePassword.length < 8) { showAlert(alertEl, '❌ Пароль Naive минимум 8', 'error'); return; }
    if (hy2Password.length < 8) { showAlert(alertEl, '❌ Пароль Hy2 минимум 8', 'error'); return; }
    payload = { type: 'install_both', domain, email, naiveLogin, naivePassword, hy2Password };
  }

  alertEl.classList.add('hidden');
  installRunning = true;

  // UI reset
  document.getElementById('installDone').classList.add('hidden');
  document.getElementById('installLog').innerHTML = '';
  document.getElementById('progressBar').style.width = '0%';
  document.getElementById('progressPercent').textContent = '0%';
  document.querySelectorAll('.install-step').forEach(s => s.classList.remove('active', 'done'));

  const btn = document.getElementById('startInstallBtn');
  btn.disabled = true;
  btn.innerHTML = `
    <svg class="spin" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
      <path d="M12 2v4M12 18v4M4.93 4.93l2.83 2.83M16.24 16.24l2.83 2.83M2 12h4M18 12h4M4.93 19.07l2.83-2.83M16.24 7.76l2.83-2.83"/>
    </svg>
    Установка...`;

  const wsProto = location.protocol === 'https:' ? 'wss:' : 'ws:';
  ws = new WebSocket(`${wsProto}//${location.host}`);

  ws.onopen = () => ws.send(JSON.stringify(payload));
  ws.onmessage = (event) => handleWsMessage(JSON.parse(event.data));
  ws.onerror = () => { appendLog('❌ WebSocket ошибка', 'error'); resetInstallBtn(); installRunning = false; };
  ws.onclose = () => { if (installRunning) installRunning = false; };
}

function handleWsMessage(msg) {
  if (msg.type === 'log') {
    appendLog(msg.text, msg.level);
    if (msg.step) activateStep(msg.step);
    if (msg.progress !== null && msg.progress !== undefined) setProgress(msg.progress);
  } else if (msg.type === 'install_done') {
    installRunning = false;
    setProgress(100);
    markStepDone('done');
    showInstallDone(msg.links || {});
    resetInstallBtn();
  } else if (msg.type === 'install_error') {
    installRunning = false;
    appendLog(`❌ ${msg.message}`, 'error');
    resetInstallBtn();
    showAlert(document.getElementById('installAlert'), `Ошибка установки: ${msg.message}`, 'error');
  }
}

function appendLog(text, level = 'info') {
  const terminal = document.getElementById('installLog');
  const line = document.createElement('div');
  line.className = `log-line log-${level}`;
  line.textContent = `› ${text}`;
  terminal.appendChild(line);
  terminal.scrollTop = terminal.scrollHeight;
}

function setProgress(pct) {
  document.getElementById('progressBar').style.width = pct + '%';
  document.getElementById('progressPercent').textContent = pct + '%';
}

let currentActiveStep = null;
function activateStep(stepName) {
  if (currentActiveStep && currentActiveStep !== stepName) markStepDone(currentActiveStep);
  const el = document.getElementById('step-' + stepName);
  if (el) {
    el.classList.add('active');
    el.classList.remove('done');
    currentActiveStep = stepName;
  }
}
function markStepDone(stepName) {
  const el = document.getElementById('step-' + stepName);
  if (el) { el.classList.remove('active'); el.classList.add('done'); }
}

function showInstallDone(links) {
  const wrap = document.getElementById('doneLinksWrap');
  wrap.innerHTML = '';
  if (links.naive) {
    wrap.innerHTML += `
      <div class="done-link-item">
        <div class="done-link-label"><span class="ql-type naive-tag">Naive</span> Ссылка для подключения:</div>
        <div class="done-link">${escapeHtml(links.naive)}</div>
        <button class="btn btn-outline btn-sm" onclick="copyText('${escapeHtml(links.naive)}')">
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>
          Копировать
        </button>
      </div>`;
  }
  if (links.hy2) {
    wrap.innerHTML += `
      <div class="done-link-item">
        <div class="done-link-label"><span class="ql-type hy2-tag">Hy2</span> Ссылка для подключения:</div>
        <div class="done-link">${escapeHtml(links.hy2)}</div>
        <button class="btn btn-outline btn-sm" onclick="copyText('${escapeHtml(links.hy2)}')">
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>
          Копировать
        </button>
      </div>`;
  }
  document.getElementById('installDone').classList.remove('hidden');
  document.querySelectorAll('.install-step').forEach(s => { s.classList.remove('active'); s.classList.add('done'); });
  showToast('✅ Установка завершена!', 'success');
}

function resetInstallBtn() {
  const btn = document.getElementById('startInstallBtn');
  btn.disabled = false;
  btn.innerHTML = `
    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="16 16 12 12 8 16"/><line x1="12" y1="12" x2="12" y2="21"/><path d="M20.39 18.39A5 5 0 0 0 18 9h-1.26A8 8 0 1 0 3 16.3"/></svg>
    Начать установку`;
}

// ─── USERS ──────────────────────────────────────────────
function switchUsersTab(tab) {
  currentUsersTab = tab;
  document.querySelectorAll('#usersPage .tab-btn').forEach(b => {
    b.classList.toggle('active', b.dataset.utab === tab);
  });
  loadUsers();
}

async function loadUsers() {
  const tbody = document.getElementById('usersTableBody');
  const table = document.getElementById('usersTable');
  const empty = document.getElementById('emptyUsers');

  try {
    const [usersRes, statusRes] = await Promise.all([
      fetch(`/api/${currentUsersTab}/users`),
      fetch('/api/status')
    ]);
    const { users } = await usersRes.json();
    const status = await statusRes.json();

    // Обновляем счётчики табов
    try {
      const n = await (await fetch('/api/naive/users')).json();
      const h = await (await fetch('/api/hy2/users')).json();
      document.getElementById('naiveTabCount').textContent = (n.users || []).length;
      document.getElementById('hy2TabCount').textContent = (h.users || []).length;
    } catch {}

    if (!users || users.length === 0) {
      table.style.display = 'none';
      empty.style.display = 'flex';
      return;
    }

    table.style.display = 'table';
    empty.style.display = 'none';
    tbody.innerHTML = '';

    users.forEach((u, i) => {
      const link = status.installed && status.domain
        ? (currentUsersTab === 'naive'
            ? `naive+https://${u.username}:${u.password}@${status.domain}:443`
            : `hysteria2://${encodeURIComponent(u.username)}:${encodeURIComponent(u.password)}@${status.domain}:443?sni=${status.domain}&insecure=0#${encodeURIComponent(u.username)}`)
        : '';
      const date = u.createdAt ? new Date(u.createdAt).toLocaleDateString('ru') : '—';
      const expireCell = formatExpireCell(u);
      const rowClass = u.expired ? 'row-expired' : '';
      tbody.innerHTML += `
        <tr class="${rowClass}">
          <td>${i + 1}</td>
          <td class="td-login">${escapeHtml(u.username)}</td>
          <td class="td-pwd">${escapeHtml(u.password)}</td>
          <td class="td-link" title="${escapeHtml(link)}">
            ${link ? `<span style="cursor:pointer" onclick="copyText('${escapeHtml(link)}')" title="Скопировать">${escapeHtml(link)}</span>` : '<span style="color:var(--text-muted)">Сервер не установлен</span>'}
          </td>
          <td>${date}</td>
          <td class="td-expire">${expireCell}</td>
          <td class="td-actions">
            ${link ? `<button class="btn btn-outline btn-sm" onclick="copyText('${escapeHtml(link)}')" title="Копировать">
              <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>
            </button>` : ''}
            <button class="btn btn-outline btn-sm" onclick="showExtendModal('${currentUsersTab}', '${escapeHtml(u.username)}')" title="Продлить / изменить срок">
              <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="9"/><polyline points="12 7 12 12 15 14"/></svg>
            </button>
            <button class="btn btn-danger btn-sm" onclick="showDeleteModal('${currentUsersTab}', '${escapeHtml(u.username)}')">
              <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6"/><path d="M10 11v6M14 11v6"/><path d="M9 6V4a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2"/></svg>
            </button>
          </td>
        </tr>`;
    });
  } catch (err) {
    showToast('Ошибка загрузки пользователей', 'error');
  }
}

function showAddUserModal() {
  const isHy2 = currentUsersTab === 'hy2';
  document.getElementById('addUserModalTitle').textContent =
    isHy2 ? 'Добавить Hy2 пользователя' : 'Добавить Naive пользователя';
  document.getElementById('newUserLogin').value = '';
  genPwdInto('newUserPassword');
  const exp = document.getElementById('newUserExpire');
  if (exp) exp.value = '7';
  document.getElementById('addUserAlert').classList.add('hidden');
  openModal('addUserModal');
}

async function addUser() {
  const username = document.getElementById('newUserLogin').value.trim();
  const password = document.getElementById('newUserPassword').value.trim();
  const expireDays = parseInt(document.getElementById('newUserExpire')?.value || '0', 10);
  const alertEl = document.getElementById('addUserAlert');

  if (!username || !password) { showAlert(alertEl, 'Введите логин и пароль', 'error'); return; }
  if (password.length < 8) { showAlert(alertEl, 'Пароль минимум 8 символов', 'error'); return; }

  try {
    const res = await fetch(`/api/${currentUsersTab}/users`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username, password, expireDays })
    });
    const data = await res.json();
    if (data.success) {
      closeModal('addUserModal');
      const suffix = expireDays > 0 ? ` (${expireDays} дн.)` : ' (бессрочно)';
      showToast(`✅ ${username} добавлен${suffix}`, 'success');
      loadUsers();
    } else {
      showAlert(alertEl, data.message || 'Ошибка', 'error');
    }
  } catch {
    showAlert(alertEl, 'Ошибка соединения', 'error');
  }
}

// ─── EXPIRE helpers ─────────────────────────────────────
function formatExpireCell(u) {
  if (!u.expiresAt) return '<span class="badge-muted">Бессрочно</span>';
  if (u.expired)    return '<span class="badge-danger">Истёк</span>';
  const sec = u.remainingSec;
  if (sec == null) return '<span class="badge-muted">—</span>';
  const d = Math.floor(sec / 86400);
  const h = Math.floor((sec % 86400) / 3600);
  const m = Math.floor((sec % 3600) / 60);
  let label;
  if (d > 0)      label = `${d} д ${h} ч`;
  else if (h > 0) label = `${h} ч ${m} м`;
  else            label = `${m} мин`;
  const cls = (sec < 86400) ? 'badge-warn' : 'badge-ok';
  const dt = new Date(u.expiresAt).toLocaleString('ru');
  return `<span class="${cls}" title="${dt}">${label}</span>`;
}

let extendUserTarget = null;
function showExtendModal(kind, username) {
  extendUserTarget = { kind, username };
  document.getElementById('extendUserName').textContent = `${kind === 'naive' ? 'Naive' : 'Hy2'}: ${username}`;
  // Подгрузим текущее значение expiresAt
  fetch(`/api/${kind}/users`).then(r => r.json()).then(({ users }) => {
    const u = (users || []).find(x => x.username === username);
    const cur = document.getElementById('extendUserCurrent');
    if (u && u.expiresAt) {
      cur.textContent = `Текущий срок: до ${new Date(u.expiresAt).toLocaleString('ru')}` + (u.expired ? ' (истёк)' : '');
    } else {
      cur.textContent = 'Текущий срок: бессрочно';
    }
  }).catch(() => {});
  document.getElementById('extendUserDays').value = '7';
  openModal('extendUserModal');
}

async function confirmExtendUser() {
  if (!extendUserTarget) return;
  const { kind, username } = extendUserTarget;
  const expireDays = parseInt(document.getElementById('extendUserDays').value || '0', 10);
  try {
    const res = await fetch(`/api/${kind}/users/${encodeURIComponent(username)}`, {
      method: 'PATCH', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ expireDays })
    });
    const data = await res.json();
    if (data.success) {
      closeModal('extendUserModal');
      showToast(expireDays > 0 ? `Срок для ${username} продлён (${expireDays} дн.)` : `${username} теперь бессрочный`, 'success');
      extendUserTarget = null;
      loadUsers();
    } else {
      showToast(data.message || 'Ошибка', 'error');
    }
  } catch {
    showToast('Ошибка соединения', 'error');
  }
}

function showDeleteModal(kind, username) {
  deleteUserTarget = { kind, username };
  document.getElementById('deleteUserName').textContent = `${kind === 'naive' ? 'Naive' : 'Hy2'}: ${username}`;
  openModal('deleteUserModal');
}

async function confirmDeleteUser() {
  if (!deleteUserTarget) return;
  const { kind, username } = deleteUserTarget;
  try {
    const res = await fetch(`/api/${kind}/users/${encodeURIComponent(username)}`, { method: 'DELETE' });
    const data = await res.json();
    if (data.success) {
      closeModal('deleteUserModal');
      showToast(`Пользователь ${username} удалён`, 'success');
      deleteUserTarget = null;
      loadUsers();
    } else {
      showToast(data.message || 'Ошибка удаления', 'error');
    }
  } catch {
    showToast('Ошибка соединения', 'error');
  }
}

// ─── TUNING ─────────────────────────────────────────────
async function loadTuning() {
  try {
    const res = await fetch('/api/tuning/status');
    const d = await res.json();

    document.getElementById('ccVal').textContent = d.cc || '—';
    document.getElementById('qdiscVal').textContent = d.qdisc || '—';
    document.getElementById('rmemVal').textContent = formatBytes(d.rmem_max);
    document.getElementById('wmemVal').textContent = formatBytes(d.wmem_max);

    setBadge('bbrBadge', d.bbrOn, d.bbrOn ? 'BBR активен' : 'BBR выключен');
    setBadge('udpBadge', d.udpBufOk, d.udpBufOk ? 'буферы 16MB+' : 'буферы мало');
  } catch {
    showToast('Ошибка загрузки тюнинга', 'error');
  }
}

function setBadge(id, ok, label) {
  const el = document.getElementById(id);
  if (ok === null) el.innerHTML = '<span class="dot dot-gray"></span> —';
  else el.innerHTML = ok ? `<span class="dot dot-green"></span> ${label}` : `<span class="dot dot-yellow"></span> ${label}`;
}

function formatBytes(v) {
  const n = Number(v || 0);
  if (!n) return '—';
  if (n >= 1048576) return (n / 1048576).toFixed(1) + ' MB';
  if (n >= 1024) return (n / 1024).toFixed(0) + ' KB';
  return n + ' B';
}

async function applyTuning() {
  const btn = document.getElementById('applyTuneBtn');
  const resEl = document.getElementById('tuneResult');
  btn.disabled = true;
  btn.innerHTML = `<svg class="spin" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 2v4M12 18v4M4.93 4.93l2.83 2.83M16.24 16.24l2.83 2.83M2 12h4M18 12h4M4.93 19.07l2.83-2.83M16.24 7.76l2.83-2.83"/></svg> Применяю...`;

  try {
    const r = await fetch('/api/tuning/apply', { method: 'POST' });
    const d = await r.json();
    if (d.success) {
      showAlert(resEl, '✅ Оптимизации применены! Изменения активны.', 'success');
      loadTuning();
    } else {
      showAlert(resEl, '❌ Ошибка: ' + (d.message || d.error || 'unknown'), 'error');
    }
  } catch {
    showAlert(resEl, '❌ Ошибка соединения', 'error');
  } finally {
    btn.disabled = false;
    btn.innerHTML = `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M13 2L3 14h9l-1 8 10-12h-9l1-8z"/></svg> Применить тюнинг`;
  }
}

// ─── BYPASS (RU direct) ───────────────────────────────
let _bypassState = { enabled: false };
async function loadBypass() {
  try {
    const r = await fetch('/api/bypass');
    const d = await r.json();
    _bypassState = d;
    const badge = document.getElementById('bypassBadge');
    if (d.enabled && d.count > 0) {
      badge.innerHTML = '<span class="dot dot-green"></span> Активен';
    } else if (d.count > 0) {
      badge.innerHTML = '<span class="dot dot-gray"></span> Выключен';
    } else {
      badge.innerHTML = '<span class="dot dot-gray"></span> Не загружен';
    }
    document.getElementById('bypassCount').textContent   = d.count || 0;
    document.getElementById('bypassUpdated').textContent = d.updatedAt ? new Date(d.updatedAt).toLocaleString('ru') : '—';
    document.getElementById('bypassSource').textContent  = d.source || 'для Hysteria2 (UDP)';
    document.getElementById('bypassPreview').textContent = (d.preview || []).join('\n') || '— список пуст —';
    document.getElementById('bypassToggleBtn').textContent = d.enabled ? 'Выключить' : 'Включить';
  } catch {
    showToast('Ошибка загрузки bypass', 'error');
  }
}

async function saveBypass(enable) {
  const raw = document.getElementById('bypassInput').value.trim();
  const resEl = document.getElementById('bypassResult');
  if (!raw) { showAlert(resEl, 'Вставьте JSON или список CIDR', 'error'); return; }

  let payload = { enabled: enable, source: document.getElementById('bypassSourceInput').value.trim() };
  try {
    const parsed = JSON.parse(raw);
    if (Array.isArray(parsed)) payload.cidrs = parsed;
    else payload.json = parsed;
  } catch {
    // not JSON — пробуем как plain list (по строке)
    payload.cidrs = raw.split(/[\s,]+/).map(s => s.trim()).filter(Boolean);
  }

  try {
    const r = await fetch('/api/bypass', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload)
    });
    const d = await r.json();
    if (d.success) {
      showAlert(resEl, `✅ Сохранено: ${d.count} сетей, ${d.enabled ? 'ВКЛ' : 'выкл'}.`, 'success');
      document.getElementById('bypassInput').value = '';
      loadBypass();
    } else {
      showAlert(resEl, 'Ошибка: ' + (d.message || 'unknown'), 'error');
    }
  } catch {
    showAlert(resEl, 'Ошибка соединения', 'error');
  }
}

async function toggleBypass() {
  try {
    const r = await fetch('/api/bypass', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ enabled: !_bypassState.enabled })
    });
    const d = await r.json();
    if (d.success) {
      showToast(d.enabled ? 'Bypass включён' : 'Bypass выключен', 'success');
      loadBypass();
    }
  } catch { showToast('Ошибка', 'error'); }
}

async function clearBypass() {
  if (!confirm('Очистить список bypass и выключить?')) return;
  try {
    const r = await fetch('/api/bypass', { method: 'DELETE' });
    const d = await r.json();
    if (d.success) { showToast('Список очищен', 'success'); loadBypass(); }
  } catch { showToast('Ошибка', 'error'); }
}

// ─── SETTINGS ───────────────────────────────────────────
async function changePassword() {
  const currentPwd = document.getElementById('currentPwd').value;
  const newPwd = document.getElementById('newPwd').value;
  const confirmPwd = document.getElementById('confirmPwd').value;
  const alertEl = document.getElementById('pwdChangeAlert');

  if (!currentPwd || !newPwd || !confirmPwd) { showAlert(alertEl, 'Заполните все поля', 'error'); return; }
  if (newPwd !== confirmPwd) { showAlert(alertEl, 'Новые пароли не совпадают', 'error'); return; }
  if (newPwd.length < 6) { showAlert(alertEl, 'Пароль минимум 6 символов', 'error'); return; }

  try {
    const res = await fetch('/api/config/change-password', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ currentPassword: currentPwd, newPassword: newPwd })
    });
    const data = await res.json();
    if (data.success) {
      showAlert(alertEl, '✅ Пароль изменён', 'success');
      ['currentPwd', 'newPwd', 'confirmPwd'].forEach(id => document.getElementById(id).value = '');
    } else {
      showAlert(alertEl, data.message || 'Ошибка', 'error');
    }
  } catch {
    showAlert(alertEl, 'Ошибка соединения', 'error');
  }
}

// ─── HELPERS ─────────────────────────────────────────────
function openModal(id) { document.getElementById(id).classList.remove('hidden'); }
function closeModal(id) { document.getElementById(id).classList.add('hidden'); }

document.querySelectorAll('.modal-overlay').forEach(overlay => {
  overlay.addEventListener('click', (e) => {
    if (e.target === overlay) overlay.classList.add('hidden');
  });
});

function showAlert(el, message, type = 'error') {
  el.className = `alert alert-${type}`;
  el.textContent = message;
  el.classList.remove('hidden');
}

function copyText(text) {
  if (navigator.clipboard) {
    navigator.clipboard.writeText(text).then(() => showToast('✅ Скопировано!', 'success')).catch(() => fallbackCopy(text));
  } else { fallbackCopy(text); }
}

function fallbackCopy(text) {
  const ta = document.createElement('textarea');
  ta.value = text; ta.style.position = 'fixed'; ta.style.opacity = '0';
  document.body.appendChild(ta); ta.select();
  document.execCommand('copy');
  document.body.removeChild(ta);
  showToast('✅ Скопировано!', 'success');
}

let toastTimer = null, toastFadeTimer = null;
function showToast(message, type = 'info') {
  const toast = document.getElementById('toast');
  if (toastTimer) clearTimeout(toastTimer);
  if (toastFadeTimer) clearTimeout(toastFadeTimer);
  toast.classList.remove('hidden');
  toast.style.opacity = '';
  toast.textContent = message;
  toast.className = `toast toast-${type}`;
  toastTimer = setTimeout(() => {
    toast.style.opacity = '0';
    toastFadeTimer = setTimeout(() => { toast.classList.add('hidden'); toast.style.opacity = ''; }, 220);
  }, 2800);
}

function escapeHtml(str) {
  return String(str)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

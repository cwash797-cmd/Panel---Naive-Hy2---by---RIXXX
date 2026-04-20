/* ═══════════════════════════════════════════════════════════
   Panel Naive + Hysteria2 by RIXXX — Backend
   ═══════════════════════════════════════════════════════════ */

'use strict';

const express = require('express');
const session = require('express-session');
const bcrypt = require('bcryptjs');
const cors = require('cors');
const bodyParser = require('body-parser');
const http = require('http');
const WebSocket = require('ws');
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const yaml = require('js-yaml');

const app = express();
const server = http.createServer(app);
const wss = new WebSocket.Server({ server });

const PORT = process.env.PORT || 3000;
const DATA_DIR = path.join(__dirname, '../data');
const CONFIG_FILE = path.join(DATA_DIR, 'config.json');
const USERS_FILE = path.join(DATA_DIR, 'users.json');
const SECRET_FILE = path.join(DATA_DIR, '.session_secret');

if (!fs.existsSync(DATA_DIR)) fs.mkdirSync(DATA_DIR, { recursive: true });

// ─── Session secret (персистентный, генерится при первом запуске) ───
let SESSION_SECRET;
try {
  SESSION_SECRET = fs.readFileSync(SECRET_FILE, 'utf8').trim();
  if (!SESSION_SECRET || SESSION_SECRET.length < 32) throw new Error('short');
} catch {
  SESSION_SECRET = crypto.randomBytes(48).toString('hex');
  fs.writeFileSync(SECRET_FILE, SESSION_SECRET, { mode: 0o600 });
}

// ─── Storage ────────────────────────────────────────────────
function defaultConfig() {
  return {
    installed: false,
    stack: { naive: false, hy2: false },
    domain: '',
    email: '',
    serverIp: '',
    arch: '',
    naiveUsers: [],
    hy2Users: []
  };
}

function loadConfig() {
  if (!fs.existsSync(CONFIG_FILE)) {
    const cfg = defaultConfig();
    fs.writeFileSync(CONFIG_FILE, JSON.stringify(cfg, null, 2));
    return cfg;
  }
  try {
    const raw = JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8'));
    // Миграция со старого формата (только Naive)
    if (!raw.stack) {
      raw.stack = { naive: !!raw.installed, hy2: false };
      raw.naiveUsers = raw.proxyUsers || raw.naiveUsers || [];
      raw.hy2Users = raw.hy2Users || [];
      delete raw.proxyUsers;
      fs.writeFileSync(CONFIG_FILE, JSON.stringify(raw, null, 2));
    }
    if (!Array.isArray(raw.naiveUsers)) raw.naiveUsers = [];
    if (!Array.isArray(raw.hy2Users)) raw.hy2Users = [];
    return raw;
  } catch (e) {
    console.error('config.json parse error, resetting:', e.message);
    const cfg = defaultConfig();
    fs.writeFileSync(CONFIG_FILE, JSON.stringify(cfg, null, 2));
    return cfg;
  }
}

function saveConfig(cfg) {
  fs.writeFileSync(CONFIG_FILE, JSON.stringify(cfg, null, 2));
}

function loadUsers() {
  if (!fs.existsSync(USERS_FILE)) {
    const users = { admin: { password: bcrypt.hashSync('admin', 10), role: 'admin' } };
    fs.writeFileSync(USERS_FILE, JSON.stringify(users, null, 2), { mode: 0o600 });
    return users;
  }
  return JSON.parse(fs.readFileSync(USERS_FILE, 'utf8'));
}

function saveUsers(users) {
  fs.writeFileSync(USERS_FILE, JSON.stringify(users, null, 2), { mode: 0o600 });
}

// ─── Middleware ─────────────────────────────────────────────
app.use(cors({ origin: true, credentials: true }));
app.use(bodyParser.json({ limit: '256kb' }));
app.use(bodyParser.urlencoded({ extended: true, limit: '256kb' }));
app.use(session({
  name: 'rixxx_sid',
  secret: SESSION_SECRET,
  resave: false,
  saveUninitialized: false,
  cookie: {
    secure: false, // за Nginx-прокси http — cookie передаётся ок
    httpOnly: true,
    sameSite: 'lax',
    maxAge: 24 * 60 * 60 * 1000
  }
}));
app.use(express.static(path.join(__dirname, '../public')));

function requireAuth(req, res, next) {
  if (req.session && req.session.authenticated) return next();
  res.status(401).json({ error: 'Unauthorized' });
}

// ─── Validation helpers ─────────────────────────────────────
function isValidDomain(s) {
  return typeof s === 'string'
    && /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$/i.test(s)
    && s.length <= 253;
}
function isValidEmail(s) {
  return typeof s === 'string' && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(s) && s.length <= 254;
}
function isValidUsername(s) {
  return typeof s === 'string' && /^[A-Za-z0-9_.-]{1,32}$/.test(s);
}
function isValidPassword(s) {
  return typeof s === 'string' && s.length >= 8 && s.length <= 128
    && /^[A-Za-z0-9!@#$%^&*_+\-=.,~]+$/.test(s);
}

// ═══════════════════════════════════════════════════════════
//  AUTH
// ═══════════════════════════════════════════════════════════
app.post('/api/login', (req, res) => {
  const { username, password } = req.body || {};
  if (!username || !password) return res.json({ success: false, message: 'Заполните все поля' });
  const users = loadUsers();
  const user = users[username];
  if (!user) return res.json({ success: false, message: 'Неверный логин или пароль' });
  if (!bcrypt.compareSync(password, user.password)) {
    return res.json({ success: false, message: 'Неверный логин или пароль' });
  }
  req.session.authenticated = true;
  req.session.username = username;
  req.session.role = user.role;
  res.json({ success: true });
});

app.post('/api/logout', (req, res) => {
  req.session.destroy(() => res.json({ success: true }));
});

app.get('/api/me', requireAuth, (req, res) => {
  res.json({ username: req.session.username, role: req.session.role });
});

app.post('/api/config/change-password', requireAuth, (req, res) => {
  const { currentPassword, newPassword } = req.body || {};
  if (!currentPassword || !newPassword) return res.json({ success: false, message: 'Заполните все поля' });
  if (newPassword.length < 6) return res.json({ success: false, message: 'Новый пароль минимум 6 символов' });
  const users = loadUsers();
  const user = users[req.session.username];
  if (!user) return res.json({ success: false, message: 'Пользователь не найден' });
  if (!bcrypt.compareSync(currentPassword, user.password)) {
    return res.json({ success: false, message: 'Текущий пароль неверен' });
  }
  user.password = bcrypt.hashSync(newPassword, 10);
  saveUsers(users);
  res.json({ success: true, message: 'Пароль успешно изменён' });
});

// ═══════════════════════════════════════════════════════════
//  CONFIG / STATUS
// ═══════════════════════════════════════════════════════════
app.get('/api/config', requireAuth, (req, res) => {
  res.json(loadConfig());
});

function checkServiceActive(unit) {
  return new Promise((resolve) => {
    const p = spawn('systemctl', ['is-active', unit]);
    let out = '';
    p.stdout.on('data', d => out += d.toString());
    p.on('close', () => resolve(out.trim() === 'active'));
    p.on('error', () => resolve(false));
  });
}

app.get('/api/status', requireAuth, async (req, res) => {
  const cfg = loadConfig();
  if (!cfg.installed) {
    return res.json({ installed: false, stack: cfg.stack || { naive: false, hy2: false } });
  }
  const [naiveActive, hy2Active] = await Promise.all([
    cfg.stack.naive ? checkServiceActive('caddy') : Promise.resolve(null),
    cfg.stack.hy2 ? checkServiceActive('hysteria-server') : Promise.resolve(null)
  ]);
  res.json({
    installed: true,
    stack: cfg.stack,
    domain: cfg.domain,
    email: cfg.email,
    serverIp: cfg.serverIp,
    arch: cfg.arch,
    naive: cfg.stack.naive ? { active: naiveActive, usersCount: cfg.naiveUsers.length } : null,
    hy2:   cfg.stack.hy2   ? { active: hy2Active,   usersCount: cfg.hy2Users.length }   : null,
  });
});

app.post('/api/service/:kind/:action', requireAuth, (req, res) => {
  const { kind, action } = req.params;
  if (!['start', 'stop', 'restart'].includes(action)) return res.status(400).json({ error: 'bad action' });
  const unit = kind === 'naive' ? 'caddy' : kind === 'hy2' ? 'hysteria-server' : null;
  if (!unit) return res.status(400).json({ error: 'bad kind' });

  const p = spawn('systemctl', [action, unit]);
  p.on('close', (code) => {
    res.json({ success: code === 0, message: code === 0 ? `${unit} ${action} OK` : `${unit} ${action} failed` });
  });
  p.on('error', () => res.json({ success: false, message: 'systemctl недоступен' }));
});

// ═══════════════════════════════════════════════════════════
//  NAIVE USERS
// ═══════════════════════════════════════════════════════════
function writeCaddyfile(cfg) {
  if (!cfg.stack.naive || !cfg.domain) return false;
  const lines = (cfg.naiveUsers || [])
    .map(u => `    basic_auth ${u.username} ${u.password}`)
    .join('\n');
  const content = `{
  order forward_proxy before file_server
}

:443, ${cfg.domain} {
  tls ${cfg.email}

  forward_proxy {
${lines || '    # no users yet'}
    hide_ip
    hide_via
    probe_resistance
  }

  file_server {
    root /var/www/html
  }
}
`;
  try {
    fs.writeFileSync('/etc/caddy/Caddyfile', content, 'utf8');
    return true;
  } catch (e) {
    console.error('Caddyfile write error:', e.message);
    return false;
  }
}

function reloadCaddy() {
  return new Promise((resolve) => {
    const p = spawn('bash', ['-c',
      'caddy reload --config /etc/caddy/Caddyfile 2>/dev/null || systemctl reload caddy 2>/dev/null || systemctl restart caddy 2>/dev/null'
    ]);
    p.on('close', () => resolve());
    p.on('error', () => resolve());
  });
}

app.get('/api/naive/users', requireAuth, (req, res) => {
  const cfg = loadConfig();
  res.json({ users: cfg.naiveUsers || [] });
});

app.post('/api/naive/users', requireAuth, async (req, res) => {
  const { username, password } = req.body || {};
  if (!isValidUsername(username)) return res.json({ success: false, message: 'Логин 1-32 симв. (A-Z, a-z, 0-9, . _ -)' });
  if (!isValidPassword(password)) return res.json({ success: false, message: 'Пароль 8-128 символов (без пробелов)' });

  const cfg = loadConfig();
  if (cfg.naiveUsers.find(u => u.username === username)) {
    return res.json({ success: false, message: 'Пользователь уже существует' });
  }
  cfg.naiveUsers.push({ username, password, createdAt: new Date().toISOString() });
  saveConfig(cfg);

  let reloaded = true;
  if (cfg.installed && cfg.stack.naive) {
    writeCaddyfile(cfg);
    await reloadCaddy();
  }

  res.json({
    success: true,
    link: cfg.domain ? `naive+https://${username}:${password}@${cfg.domain}:443` : null,
    reloaded
  });
});

app.delete('/api/naive/users/:username', requireAuth, async (req, res) => {
  const { username } = req.params;
  const cfg = loadConfig();
  const before = cfg.naiveUsers.length;
  cfg.naiveUsers = cfg.naiveUsers.filter(u => u.username !== username);
  if (cfg.naiveUsers.length === before) return res.json({ success: false, message: 'Не найден' });
  saveConfig(cfg);
  if (cfg.installed && cfg.stack.naive) {
    writeCaddyfile(cfg);
    await reloadCaddy();
  }
  res.json({ success: true });
});

// ═══════════════════════════════════════════════════════════
//  HY2 USERS
// ═══════════════════════════════════════════════════════════
function writeHysteriaConfig(cfg) {
  if (!cfg.stack.hy2 || !cfg.domain) return false;

  const userpass = {};
  (cfg.hy2Users || []).forEach(u => {
    if (u.username && u.password) userpass[u.username] = u.password;
  });
  if (Object.keys(userpass).length === 0) userpass.default = crypto.randomBytes(16).toString('base64url');

  const hyCfgPath = '/etc/hysteria/config.yaml';
  let existing = null;
  try {
    existing = yaml.load(fs.readFileSync(hyCfgPath, 'utf8'));
  } catch {
    existing = null;
  }
  const base = existing || {
    listen: ':443',
    masquerade: { type: 'proxy', proxy: { url: 'https://www.bing.com', rewriteHost: true } },
    ignoreClientBandwidth: true,
    quic: {
      initStreamReceiveWindow: 8388608, maxStreamReceiveWindow: 8388608,
      initConnReceiveWindow: 20971520, maxConnReceiveWindow: 20971520,
      maxIdleTimeout: '30s', keepAlivePeriod: '10s', disablePathMTUDiscovery: false
    }
  };
  base.auth = { type: 'userpass', userpass };

  try {
    fs.writeFileSync(hyCfgPath, yaml.dump(base, { lineWidth: 120 }), 'utf8');
    return true;
  } catch (e) {
    console.error('hysteria config write error:', e.message);
    return false;
  }
}

function reloadHysteria() {
  return new Promise((resolve) => {
    const p = spawn('systemctl', ['restart', 'hysteria-server']);
    p.on('close', () => resolve());
    p.on('error', () => resolve());
  });
}

app.get('/api/hy2/users', requireAuth, (req, res) => {
  const cfg = loadConfig();
  res.json({ users: cfg.hy2Users || [] });
});

app.post('/api/hy2/users', requireAuth, async (req, res) => {
  const { username, password } = req.body || {};
  if (!isValidUsername(username)) return res.json({ success: false, message: 'Логин 1-32 символа' });
  if (!isValidPassword(password)) return res.json({ success: false, message: 'Пароль 8-128 символов' });

  const cfg = loadConfig();
  if (cfg.hy2Users.find(u => u.username === username)) {
    return res.json({ success: false, message: 'Пользователь уже существует' });
  }
  cfg.hy2Users.push({ username, password, createdAt: new Date().toISOString() });
  saveConfig(cfg);

  if (cfg.installed && cfg.stack.hy2) {
    writeHysteriaConfig(cfg);
    await reloadHysteria();
  }
  res.json({
    success: true,
    link: cfg.domain
      ? `hysteria2://${encodeURIComponent(password)}@${cfg.domain}:443?sni=${cfg.domain}#${encodeURIComponent(username)}`
      : null
  });
});

app.delete('/api/hy2/users/:username', requireAuth, async (req, res) => {
  const { username } = req.params;
  const cfg = loadConfig();
  const before = cfg.hy2Users.length;
  cfg.hy2Users = cfg.hy2Users.filter(u => u.username !== username);
  if (cfg.hy2Users.length === before) return res.json({ success: false, message: 'Не найден' });
  saveConfig(cfg);
  if (cfg.installed && cfg.stack.hy2) {
    writeHysteriaConfig(cfg);
    await reloadHysteria();
  }
  res.json({ success: true });
});

// ═══════════════════════════════════════════════════════════
//  SYSCTL TUNING
// ═══════════════════════════════════════════════════════════
app.get('/api/tuning/status', requireAuth, (req, res) => {
  const p = spawn('bash', ['-c',
    'echo cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown); ' +
    'echo qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown); ' +
    'echo rmem_max=$(sysctl -n net.core.rmem_max 2>/dev/null || echo unknown); ' +
    'echo wmem_max=$(sysctl -n net.core.wmem_max 2>/dev/null || echo unknown)'
  ]);
  let out = '';
  p.stdout.on('data', d => out += d.toString());
  p.on('close', () => {
    const parsed = {};
    out.split('\n').forEach(line => {
      const [k, v] = line.split('=');
      if (k && v) parsed[k.trim()] = v.trim();
    });
    res.json({
      cc: parsed.cc || 'unknown',
      qdisc: parsed.qdisc || 'unknown',
      rmem_max: parsed.rmem_max || 'unknown',
      wmem_max: parsed.wmem_max || 'unknown',
      bbrOn: parsed.cc === 'bbr' && parsed.qdisc === 'fq',
      udpBufOk: Number(parsed.rmem_max || 0) >= 16777216
    });
  });
  p.on('error', () => res.json({ error: 'sysctl недоступен' }));
});

app.post('/api/tuning/apply', requireAuth, (req, res) => {
  const scriptPath = path.join(__dirname, '../scripts/sysctl_tune.sh');
  if (!fs.existsSync(scriptPath)) return res.json({ success: false, message: 'script not found' });
  const p = spawn('bash', [scriptPath]);
  let out = '', err = '';
  p.stdout.on('data', d => out += d.toString());
  p.stderr.on('data', d => err += d.toString());
  p.on('close', (code) => {
    res.json({ success: code === 0, output: out, error: err });
  });
  p.on('error', (e) => res.json({ success: false, message: e.message }));
});

// ═══════════════════════════════════════════════════════════
//  INSTALL VIA WEBSOCKET
// ═══════════════════════════════════════════════════════════
wss.on('connection', (ws, req) => {
  // Минимальная защита: проверим session cookie
  const cookie = (req.headers.cookie || '');
  if (!cookie.includes('rixxx_sid=')) {
    ws.send(JSON.stringify({ type: 'error', message: 'unauthorized' }));
    ws.close();
    return;
  }

  ws.on('message', (message) => {
    try {
      const data = JSON.parse(message);
      if (data.type === 'install_naive') return handleInstallNaive(ws, data);
      if (data.type === 'install_hy2')   return handleInstallHy2(ws, data);
      if (data.type === 'install_both')  return handleInstallBoth(ws, data);
    } catch (e) {
      ws.send(JSON.stringify({ type: 'error', message: 'bad message' }));
    }
  });
});

function sendLog(ws, text, step = null, progress = null, level = 'info') {
  if (ws.readyState !== WebSocket.OPEN) return;
  ws.send(JSON.stringify({ type: 'log', text, step, progress, level }));
}

function parseLogLine(line) {
  const stepMap = [
    { p: /STEP:1/,    step: 'update',    progress: 8,  text: '📦 Обновление системы...' },
    { p: /STEP:2/,    step: 'bbr',       progress: 15, text: '⚡ BBR + UDP тюнинг...' },
    { p: /STEP:3/,    step: 'firewall',  progress: 22, text: '🛡 Файрволл...' },
    { p: /STEP:4/,    step: 'dl',        progress: 35, text: '📥 Загрузка бинарника...' },
    { p: /STEP:5/,    step: 'build',     progress: 60, text: '🔨 Сборка / настройка...' },
    { p: /STEP:6/,    step: 'config',    progress: 75, text: '📝 Конфигурация...' },
    { p: /STEP:7/,    step: 'service',   progress: 85, text: '⚙ Systemd сервис...' },
    { p: /STEP:8/,    step: 'start',     progress: 93, text: '🟢 Запуск...' },
    { p: /STEP:DONE/, step: 'done',      progress: 100, text: '✅ Готово!' },
  ];
  for (const s of stepMap) {
    if (s.p.test(line)) return { text: s.text, step: s.step, progress: s.progress, level: 'step' };
  }
  if (/error|ошибка|failed|fail/i.test(line)) return { text: line, level: 'error' };
  if (/warn|⚠/i.test(line)) return { text: line, level: 'warn' };
  if (/✅|✓|OK:/i.test(line)) return { text: line, level: 'success' };
  return { text: line, level: 'info' };
}

function runScript(ws, scriptName, env, onExit) {
  const scriptPath = path.join(__dirname, '../scripts', scriptName);
  if (!fs.existsSync(scriptPath)) {
    sendLog(ws, `❌ Скрипт ${scriptName} не найден!`, null, null, 'error');
    ws.send(JSON.stringify({ type: 'install_error', message: scriptName + ' not found' }));
    return;
  }
  const child = spawn('bash', [scriptPath], { env: { ...process.env, ...env, DEBIAN_FRONTEND: 'noninteractive' } });

  child.stdout.on('data', (data) => {
    data.toString().split('\n').filter(l => l.trim()).forEach(line => {
      const parsed = parseLogLine(line);
      sendLog(ws, parsed.text, parsed.step, parsed.progress, parsed.level);
    });
  });
  child.stderr.on('data', (data) => {
    data.toString().split('\n').filter(l => l.trim()).forEach(line => {
      if (!line.includes('WARNING')) sendLog(ws, line, null, null, 'warn');
    });
  });
  child.on('close', onExit);
  child.on('error', (err) => {
    sendLog(ws, `❌ ${err.message}`, null, null, 'error');
    ws.send(JSON.stringify({ type: 'install_error', message: err.message }));
  });
}

// Helper: вытянуть server_ip в конфиг
function persistServerIp(cfg) {
  const p = spawn('bash', ['-c', "curl -4 -s --connect-timeout 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}'"]);
  let ip = '';
  p.stdout.on('data', d => ip += d.toString().trim());
  p.on('close', () => {
    if (ip) {
      cfg.serverIp = ip;
      cfg.arch = require('os').arch();
      saveConfig(cfg);
    }
  });
}

function handleInstallNaive(ws, data) {
  const { domain, email, login, password } = data;
  if (!isValidDomain(domain)) return ws.send(JSON.stringify({ type: 'install_error', message: 'Неверный домен' }));
  if (!isValidEmail(email)) return ws.send(JSON.stringify({ type: 'install_error', message: 'Неверный email' }));
  if (!isValidUsername(login)) return ws.send(JSON.stringify({ type: 'install_error', message: 'Неверный логин' }));
  if (!isValidPassword(password)) return ws.send(JSON.stringify({ type: 'install_error', message: 'Пароль минимум 8 символов' }));

  const cfg = loadConfig();
  cfg.domain = domain;
  cfg.email = email;
  cfg.stack.naive = true;
  if (!cfg.naiveUsers.find(u => u.username === login)) {
    cfg.naiveUsers.push({ username: login, password, createdAt: new Date().toISOString() });
  }
  saveConfig(cfg);
  persistServerIp(cfg);

  sendLog(ws, '🚀 Запуск установки NaiveProxy...', 'init', 2, 'info');
  runScript(ws, 'install_naiveproxy.sh', {
    NAIVE_DOMAIN: domain, NAIVE_EMAIL: email,
    NAIVE_LOGIN: login, NAIVE_PASSWORD: password
  }, (code) => {
    if (code === 0) {
      cfg.installed = true;
      saveConfig(cfg);
      sendLog(ws, '✅ NaiveProxy готов!', 'done', 100, 'success');
      ws.send(JSON.stringify({
        type: 'install_done',
        links: {
          naive: `naive+https://${login}:${password}@${domain}:443`
        }
      }));
    } else {
      ws.send(JSON.stringify({ type: 'install_error', message: `Exit code: ${code}` }));
    }
  });
}

function handleInstallHy2(ws, data) {
  const { domain, email, password, useCaddyCert } = data;
  if (!isValidDomain(domain)) return ws.send(JSON.stringify({ type: 'install_error', message: 'Неверный домен' }));
  if (!isValidEmail(email)) return ws.send(JSON.stringify({ type: 'install_error', message: 'Неверный email' }));
  if (!isValidPassword(password)) return ws.send(JSON.stringify({ type: 'install_error', message: 'Пароль минимум 8 символов' }));

  const cfg = loadConfig();
  cfg.domain = domain;
  cfg.email = email;
  cfg.stack.hy2 = true;
  if (!cfg.hy2Users.find(u => u.username === 'default')) {
    cfg.hy2Users.push({ username: 'default', password, createdAt: new Date().toISOString() });
  } else {
    cfg.hy2Users.find(u => u.username === 'default').password = password;
  }
  saveConfig(cfg);
  persistServerIp(cfg);

  sendLog(ws, '⚡ Запуск установки Hysteria2...', 'init', 2, 'info');
  runScript(ws, 'install_hysteria.sh', {
    HY_DOMAIN: domain, HY_EMAIL: email, HY_PASSWORD: password,
    USE_CADDY_CERT: useCaddyCert ? '1' : '0'
  }, (code) => {
    if (code === 0) {
      cfg.installed = true;
      saveConfig(cfg);
      sendLog(ws, '✅ Hysteria2 готова!', 'done', 100, 'success');
      ws.send(JSON.stringify({
        type: 'install_done',
        links: {
          hy2: `hysteria2://${encodeURIComponent(password)}@${domain}:443?sni=${domain}#RIXXX`
        }
      }));
    } else {
      ws.send(JSON.stringify({ type: 'install_error', message: `Exit code: ${code}` }));
    }
  });
}

function handleInstallBoth(ws, data) {
  const { domain, email, naiveLogin, naivePassword, hy2Password } = data;
  if (!isValidDomain(domain)) return ws.send(JSON.stringify({ type: 'install_error', message: 'Неверный домен' }));
  if (!isValidEmail(email)) return ws.send(JSON.stringify({ type: 'install_error', message: 'Неверный email' }));
  if (!isValidUsername(naiveLogin)) return ws.send(JSON.stringify({ type: 'install_error', message: 'Неверный Naive логин' }));
  if (!isValidPassword(naivePassword)) return ws.send(JSON.stringify({ type: 'install_error', message: 'Naive пароль 8+ символов' }));
  if (!isValidPassword(hy2Password)) return ws.send(JSON.stringify({ type: 'install_error', message: 'Hy2 пароль 8+ символов' }));

  const cfg = loadConfig();
  cfg.domain = domain;
  cfg.email = email;
  cfg.stack.naive = true;
  cfg.stack.hy2 = true;
  if (!cfg.naiveUsers.find(u => u.username === naiveLogin)) {
    cfg.naiveUsers.push({ username: naiveLogin, password: naivePassword, createdAt: new Date().toISOString() });
  }
  const existDef = cfg.hy2Users.find(u => u.username === 'default');
  if (existDef) existDef.password = hy2Password;
  else cfg.hy2Users.push({ username: 'default', password: hy2Password, createdAt: new Date().toISOString() });
  saveConfig(cfg);
  persistServerIp(cfg);

  sendLog(ws, '🚀 Установка Naive + Hy2 последовательно...', 'init', 2, 'info');

  runScript(ws, 'install_naiveproxy.sh', {
    NAIVE_DOMAIN: domain, NAIVE_EMAIL: email,
    NAIVE_LOGIN: naiveLogin, NAIVE_PASSWORD: naivePassword
  }, (codeNaive) => {
    if (codeNaive !== 0) {
      ws.send(JSON.stringify({ type: 'install_error', message: `Naive failed: ${codeNaive}` }));
      return;
    }
    sendLog(ws, '✅ Naive ок, запускаю Hy2...', null, 50, 'success');
    runScript(ws, 'install_hysteria.sh', {
      HY_DOMAIN: domain, HY_EMAIL: email, HY_PASSWORD: hy2Password,
      USE_CADDY_CERT: '1'
    }, (codeHy) => {
      if (codeHy === 0) {
        cfg.installed = true;
        saveConfig(cfg);
        sendLog(ws, '✅ Оба протокола готовы!', 'done', 100, 'success');
        ws.send(JSON.stringify({
          type: 'install_done',
          links: {
            naive: `naive+https://${naiveLogin}:${naivePassword}@${domain}:443`,
            hy2:   `hysteria2://${encodeURIComponent(hy2Password)}@${domain}:443?sni=${domain}#RIXXX`
          }
        }));
      } else {
        ws.send(JSON.stringify({ type: 'install_error', message: `Hy2 failed: ${codeHy}` }));
      }
    });
  });
}

// ─── SPA fallback ─────────────────────────────────────────
app.get(/^(?!\/api).*/, (req, res) => {
  res.sendFile(path.join(__dirname, '../public/index.html'));
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`\n╔═══════════════════════════════════════════════╗`);
  console.log(`║   Panel Naive + Hysteria2 by RIXXX            ║`);
  console.log(`║   Running on http://0.0.0.0:${PORT}              ║`);
  console.log(`╚═══════════════════════════════════════════════╝\n`);
});

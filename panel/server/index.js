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

    // Миграция: если panelDomain не записан в config, но в Caddyfile есть
    // второй site-блок для поддомена с reverse_proxy на 127.0.0.1 — вытащим его.
    // Это спасает установки, сделанные до того, как install.sh начал писать
    // panelDomain в config.json (коммит 0c0c204 и ранее).
    if (!raw.panelDomain) {
      try {
        const caddyfile = fs.readFileSync('/etc/caddy/Caddyfile', 'utf8');
        // Ищем блок вида: "somesubdomain.example.com {\n  tls ...\n  ...\n  reverse_proxy 127.0.0.1:..."
        const m = caddyfile.match(/\n(\S+)\s*\{\s*\n\s*tls\s+(\S+)\s*\n[^}]*reverse_proxy\s+127\.0\.0\.1/);
        if (m && m[1] && m[1] !== raw.domain && m[1].includes('.')) {
          raw.panelDomain = m[1];
          raw.panelEmail = m[2] || raw.email;
          fs.writeFileSync(CONFIG_FILE, JSON.stringify(raw, null, 2));
          console.log('[migrate] panelDomain восстановлен из Caddyfile:', raw.panelDomain);
        }
      } catch (_) { /* Caddyfile может отсутствовать — ничего страшного */ }
    }

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

// Срок действия пользователя: 0 = бессрочно, иначе число дней (1..3650)
function isValidExpireDays(n) {
  if (n === undefined || n === null || n === '' || n === 0 || n === '0') return true;
  const v = parseInt(n, 10);
  return Number.isFinite(v) && v >= 1 && v <= 3650;
}

// Вычислить дату окончания (ISO) от now + days. days<=0 → null (бессрочно)
function computeExpiresAt(days) {
  const d = parseInt(days, 10);
  if (!Number.isFinite(d) || d <= 0) return null;
  return new Date(Date.now() + d * 86400 * 1000).toISOString();
}

// Истёк ли пользователь?
function isExpired(user) {
  if (!user || !user.expiresAt) return false;
  const t = Date.parse(user.expiresAt);
  if (!Number.isFinite(t)) return false;
  return Date.now() >= t;
}

// Оставшиеся секунды до истечения (для UI)
function remainingSeconds(user) {
  if (!user || !user.expiresAt) return null;
  const t = Date.parse(user.expiresAt);
  if (!Number.isFinite(t)) return null;
  return Math.max(0, Math.floor((t - Date.now()) / 1000));
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
    if (code !== 0) {
      return res.json({ success: false, message: `${unit} ${action} failed (code ${code})` });
    }
    // Даём сервису 1.5с подняться, потом проверяем реальный статус
    setTimeout(() => {
      checkServiceActive(unit).then(active => {
        res.json({
          success: true,
          active,
          message: active
            ? `${unit} ${action} — сервис активен`
            : `${unit} ${action} — команда принята (сервис ещё стартует)`
        });
      }).catch(() => {
        res.json({ success: true, active: null, message: `${unit} ${action} OK` });
      });
    }, 1500);
  });
  p.on('error', () => res.json({ success: false, message: 'systemctl недоступен' }));
});

// ═══════════════════════════════════════════════════════════
//  NAIVE USERS
// ═══════════════════════════════════════════════════════════
function writeCaddyfile(cfg) {
  if (!cfg.stack.naive || !cfg.domain) return false;
  // Фильтруем истёкших пользователей — их basic_auth не попадёт в Caddyfile (подключиться не смогут)
  const lines = (cfg.naiveUsers || [])
    .filter(u => !isExpired(u))
    .map(u => `    basic_auth ${u.username} ${u.password}`)
    .join('\n');

  // КРИТИЧНО: если Hy2 тоже установлен — отключаем HTTP/3 в Caddy,
  // иначе он займёт UDP/443 и Hy2 не запустится.
  const disableH3 = cfg.stack && cfg.stack.hy2;
  const globalBlock = disableH3
    ? `{
  order forward_proxy before file_server
  servers {
    protocols h1 h2
  }
}`
    : `{
  order forward_proxy before file_server
}`;

  // Основной site-блок: домен прокси
  let content = `${globalBlock}

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

  // Второй site-блок: панель на отдельном поддомене (ACCESS_MODE=3).
  // ОБЯЗАТЕЛЬНО сохраняем этот блок при любой перегенерации Caddyfile,
  // иначе после добавления юзеров Naive панель перестанет отвечать по HTTPS.
  // panelDomain/panelEmail записываются install.sh при установке в режиме 3.
  const internalPort = process.env.PORT || 3000;
  if (cfg.panelDomain && cfg.panelDomain !== cfg.domain) {
    const panelEmail = cfg.panelEmail || cfg.email;
    content += `
${cfg.panelDomain} {
  tls ${panelEmail}
  encode gzip
  reverse_proxy 127.0.0.1:${internalPort}
}
`;
  }

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

function enrichUser(u) {
  return {
    ...u,
    expiresAt: u.expiresAt || null,
    remainingSec: remainingSeconds(u),
    expired: isExpired(u)
  };
}

app.get('/api/naive/users', requireAuth, (req, res) => {
  const cfg = loadConfig();
  res.json({ users: (cfg.naiveUsers || []).map(enrichUser) });
});

app.post('/api/naive/users', requireAuth, async (req, res) => {
  const { username, password, expireDays } = req.body || {};
  if (!isValidUsername(username)) return res.json({ success: false, message: 'Логин 1-32 симв. (A-Z, a-z, 0-9, . _ -)' });
  if (!isValidPassword(password)) return res.json({ success: false, message: 'Пароль 8-128 символов (без пробелов)' });
  if (!isValidExpireDays(expireDays)) return res.json({ success: false, message: 'Срок: 1..3650 дней или 0 (бессрочно)' });

  const cfg = loadConfig();
  if (cfg.naiveUsers.find(u => u.username === username)) {
    return res.json({ success: false, message: 'Пользователь уже существует' });
  }
  const expiresAt = computeExpiresAt(expireDays);
  cfg.naiveUsers.push({ username, password, createdAt: new Date().toISOString(), expiresAt });
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

// Продлить/изменить срок: { expireDays: N } (0 = бессрочно, N>0 = now + N дней)
app.patch('/api/naive/users/:username', requireAuth, async (req, res) => {
  const { username } = req.params;
  const { expireDays } = req.body || {};
  if (!isValidExpireDays(expireDays)) return res.json({ success: false, message: 'Срок: 1..3650 дней или 0' });

  const cfg = loadConfig();
  const user = cfg.naiveUsers.find(u => u.username === username);
  if (!user) return res.json({ success: false, message: 'Не найден' });
  user.expiresAt = computeExpiresAt(expireDays);
  saveConfig(cfg);

  if (cfg.installed && cfg.stack.naive) {
    writeCaddyfile(cfg);
    await reloadCaddy();
  }
  res.json({ success: true, expiresAt: user.expiresAt });
});

// ═══════════════════════════════════════════════════════════
//  IP BYPASS (RU direct) — общий список для ACL Hy2
// ═══════════════════════════════════════════════════════════
const BYPASS_FILE    = path.join(DATA_DIR, 'bypass.json');
const HY2_ACL_PATH   = '/etc/hysteria/bypass-ru.acl';

// Список сервисов, которые блокируют иностранные IP — их лучше пускать напрямую.
// Обновляется пользователем через API /api/bypass.
function loadBypass() {
  try {
    if (!fs.existsSync(BYPASS_FILE)) {
      // Дефолт — пусто, т.е. bypass выключен
      const d = { enabled: false, cidrs: [], source: '', updatedAt: null };
      fs.writeFileSync(BYPASS_FILE, JSON.stringify(d, null, 2));
      return d;
    }
    const raw = JSON.parse(fs.readFileSync(BYPASS_FILE, 'utf8'));
    if (!Array.isArray(raw.cidrs)) raw.cidrs = [];
    return raw;
  } catch {
    return { enabled: false, cidrs: [], source: '', updatedAt: null };
  }
}
function saveBypass(b) {
  fs.writeFileSync(BYPASS_FILE, JSON.stringify(b, null, 2));
}

// Применяет ACL bypass к переданному Hysteria-конфигу (in-place).
// Hysteria2 ACL синтаксис: "<action>(<arg>) <target>". Используем direct(0) для IP-сетей.
// Файл: по одной строке; записываем только при наличии активного bypass.
function applyBypassAcl(base, cfg) {
  const b = loadBypass();
  if (!b.enabled || !Array.isArray(b.cidrs) || b.cidrs.length === 0) {
    // выключено — удаляем из конфига acl, если там был наш файл
    if (base.acl && base.acl.file === HY2_ACL_PATH) delete base.acl;
    try { if (fs.existsSync(HY2_ACL_PATH)) fs.unlinkSync(HY2_ACL_PATH); } catch {}
    return;
  }
  // Пишем ACL-файл
  try {
    fs.mkdirSync(path.dirname(HY2_ACL_PATH), { recursive: true });
    const lines = b.cidrs
      .filter(c => /^[0-9a-fA-F:.\/]+$/.test(c))
      .map(c => `direct(${c})`)
      .join('\n');
    fs.writeFileSync(HY2_ACL_PATH, lines + '\n', 'utf8');
    base.acl = { file: HY2_ACL_PATH };
  } catch (e) {
    console.error('[bypass] write acl failed:', e.message);
  }
}

app.get('/api/bypass', requireAuth, (req, res) => {
  const b = loadBypass();
  res.json({
    enabled: !!b.enabled,
    count:   (b.cidrs || []).length,
    source:  b.source || '',
    updatedAt: b.updatedAt || null,
    // первые 50 строк для предпросмотра
    preview: (b.cidrs || []).slice(0, 50)
  });
});

// Загрузка списка: принимает либо { cidrs: ["1.2.3.0/24", ...] },
// либо { json: { "service.ru": ["1.2.3.0/24", ...], ... } } (формат пользовательского файла)
app.post('/api/bypass', requireAuth, async (req, res) => {
  const { cidrs, json, enabled, source } = req.body || {};
  const b = loadBypass();

  let newList = null;
  if (Array.isArray(cidrs)) {
    newList = cidrs;
  } else if (json && typeof json === 'object') {
    const set = new Set();
    Object.values(json).forEach(arr => {
      if (Array.isArray(arr)) arr.forEach(c => { if (typeof c === 'string') set.add(c.trim()); });
    });
    newList = Array.from(set);
  }

  if (newList) {
    // Валидация CIDR — оставляем только корректные
    const re = /^(\d{1,3}\.){3}\d{1,3}\/\d{1,2}$|^[0-9a-fA-F:]+\/\d{1,3}$/;
    b.cidrs = newList.map(s => String(s).trim()).filter(s => re.test(s));
    b.source = typeof source === 'string' ? source.slice(0, 128) : b.source;
    b.updatedAt = new Date().toISOString();
  }
  if (typeof enabled === 'boolean') b.enabled = enabled;

  saveBypass(b);

  // Применяем немедленно, если Hy2 установлен
  const cfg = loadConfig();
  if (cfg.installed && cfg.stack.hy2) {
    writeHysteriaConfig(cfg);
    await reloadHysteria();
  }
  res.json({ success: true, enabled: !!b.enabled, count: b.cidrs.length });
});

app.delete('/api/bypass', requireAuth, async (req, res) => {
  saveBypass({ enabled: false, cidrs: [], source: '', updatedAt: null });
  const cfg = loadConfig();
  if (cfg.installed && cfg.stack.hy2) {
    writeHysteriaConfig(cfg);
    await reloadHysteria();
  }
  res.json({ success: true });
});

// ═══════════════════════════════════════════════════════════
//  HY2 USERS
// ═══════════════════════════════════════════════════════════
function writeHysteriaConfig(cfg) {
  if (!cfg.stack.hy2 || !cfg.domain) return false;

  const userpass = {};
  // Фильтруем истёкших пользователей — их не будет в userpass (подключиться не смогут)
  (cfg.hy2Users || []).forEach(u => {
    if (u.username && u.password && !isExpired(u)) userpass[u.username] = u.password;
  });
  if (Object.keys(userpass).length === 0) {
    userpass.default = crypto.randomBytes(16).toString('base64url');
  }

  const hyCfgPath = '/etc/hysteria/config.yaml';

  // Читаем существующий конфиг и ОБНОВЛЯЕМ только секцию auth.
  // Это критично: TLS/ACME/masquerade/quic секции должны сохраняться!
  let base = null;
  try {
    const raw = fs.readFileSync(hyCfgPath, 'utf8');
    base = yaml.load(raw);
  } catch {
    base = null;
  }

  if (base && typeof base === 'object') {
    // Только обновляем userpass — всё остальное (tls/acme/quic/masquerade) не трогаем
    if (!base.auth) base.auth = { type: 'userpass' };
    base.auth.type = 'userpass';
    base.auth.userpass = userpass;
    // ACL bypass (русские сервисы идут direct, минуя VPN): подставляем, если настроен
    applyBypassAcl(base, cfg);
  } else {
    // Файла нет или повреждён — создаём минимальный.
    // Пытаемся найти сертификат Caddy через find (любой CA, новый или старый путь).
    // Если не нашли — НЕ включаем ACME fallback (чтобы не сжечь LE rate limit 429),
    // оставляем конфиг без TLS — Hy2 не стартует, пока админ вручную не допишет tls.
    console.warn('[writeHysteriaConfig] /etc/hysteria/config.yaml not found — creating minimal config.');
    let tlsBlock = null;
    try {
      const roots = [
        '/var/lib/caddy/.local/share/caddy/certificates',
        '/root/.local/share/caddy/certificates'
      ];
      for (const root of roots) {
        if (!fs.existsSync(root)) continue;
        // find <root> -type f -name "<domain>.crt"
        const result = require('child_process').execSync(
          `find "${root}" -type f -name "${cfg.domain}.crt" 2>/dev/null | head -1`,
          { encoding: 'utf8' }
        ).trim();
        if (result && fs.existsSync(result) && fs.existsSync(result.replace(/\.crt$/, '.key'))) {
          tlsBlock = { cert: result, key: result.replace(/\.crt$/, '.key') };
          console.log('[writeHysteriaConfig] Found Caddy cert:', tlsBlock.cert);
          break;
        }
      }
    } catch (e) { /* ignore */ }

    base = {
      listen: ':443',
      auth: { type: 'userpass', userpass },
      masquerade: { type: 'file', file: { dir: '/var/www/html' } },
      ignoreClientBandwidth: true,
      quic: {
        initStreamReceiveWindow: 8388608, maxStreamReceiveWindow: 8388608,
        initConnReceiveWindow: 20971520, maxConnReceiveWindow: 20971520,
        maxIdleTimeout: '30s', keepAlivePeriod: '10s', disablePathMTUDiscovery: false
      }
    };
    if (tlsBlock) {
      base.tls = tlsBlock;
    } else {
      console.warn('[writeHysteriaConfig] No Caddy cert found. Hysteria2 will NOT start until TLS is configured manually.');
    }
    applyBypassAcl(base, cfg);
  }

  try {
    fs.writeFileSync(hyCfgPath, yaml.dump(base, { lineWidth: 120, quotingType: '"' }), 'utf8');
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
  res.json({ users: (cfg.hy2Users || []).map(enrichUser) });
});

app.post('/api/hy2/users', requireAuth, async (req, res) => {
  const { username, password, expireDays } = req.body || {};
  if (!isValidUsername(username)) return res.json({ success: false, message: 'Логин 1-32 символа' });
  if (!isValidPassword(password)) return res.json({ success: false, message: 'Пароль 8-128 символов' });
  if (!isValidExpireDays(expireDays)) return res.json({ success: false, message: 'Срок: 1..3650 дней или 0 (бессрочно)' });

  const cfg = loadConfig();
  if (cfg.hy2Users.find(u => u.username === username)) {
    return res.json({ success: false, message: 'Пользователь уже существует' });
  }
  const expiresAt = computeExpiresAt(expireDays);
  cfg.hy2Users.push({ username, password, createdAt: new Date().toISOString(), expiresAt });
  saveConfig(cfg);

  if (cfg.installed && cfg.stack.hy2) {
    writeHysteriaConfig(cfg);
    await reloadHysteria();
  }
  res.json({
    success: true,
    link: cfg.domain
      ? `hysteria2://${encodeURIComponent(username)}:${encodeURIComponent(password)}@${cfg.domain}:443?sni=${cfg.domain}&insecure=0#${encodeURIComponent(username)}`
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

// Продлить/изменить срок Hy2: { expireDays: N }
app.patch('/api/hy2/users/:username', requireAuth, async (req, res) => {
  const { username } = req.params;
  const { expireDays } = req.body || {};
  if (!isValidExpireDays(expireDays)) return res.json({ success: false, message: 'Срок: 1..3650 дней или 0' });

  const cfg = loadConfig();
  const user = cfg.hy2Users.find(u => u.username === username);
  if (!user) return res.json({ success: false, message: 'Не найден' });
  user.expiresAt = computeExpiresAt(expireDays);
  saveConfig(cfg);

  if (cfg.installed && cfg.stack.hy2) {
    writeHysteriaConfig(cfg);
    await reloadHysteria();
  }
  res.json({ success: true, expiresAt: user.expiresAt });
});

// ═══════════════════════════════════════════════════════════
//  LOGS / DIAGNOSTICS
// ═══════════════════════════════════════════════════════════
app.get('/api/logs/:kind', requireAuth, (req, res) => {
  const { kind } = req.params;
  const lines = Math.max(10, Math.min(parseInt(req.query.lines || '60', 10) || 60, 500));
  const unitMap = {
    naive: 'caddy',
    hy2: 'hysteria-server',
    panel: 'pm2-root'
  };
  const unit = unitMap[kind];
  if (!unit) return res.status(400).json({ error: 'bad kind' });

  if (kind === 'panel') {
    // PM2 logs (panel сам себя)
    const p = spawn('pm2', ['logs', 'panel-naive-hy2', '--lines', String(lines), '--nostream', '--raw']);
    let out = '';
    p.stdout.on('data', d => out += d.toString());
    p.stderr.on('data', d => out += d.toString());
    p.on('close', () => res.json({ unit: 'pm2', output: out || '(no logs)' }));
    p.on('error', () => res.json({ unit: 'pm2', output: 'pm2 недоступен' }));
    return;
  }

  const p = spawn('journalctl', ['-u', unit, '-n', String(lines), '--no-pager', '--output=cat']);
  let out = '';
  p.stdout.on('data', d => out += d.toString());
  p.on('close', () => res.json({ unit, output: out || '(no logs)' }));
  p.on('error', () => res.json({ unit, output: 'journalctl недоступен' }));
});

// Диагностика портов: что слушает 443/tcp и 443/udp + сертификаты
app.get('/api/diag/ports', requireAuth, (req, res) => {
  const p = spawn('bash', ['-c',
    'echo "=== TCP/443 (Naive/Caddy) ==="; (ss -tlnp 2>/dev/null | grep -E ":443 " || echo "(никто не слушает)"); ' +
    'echo ""; echo "=== UDP/443 (Hysteria2) ==="; (ss -ulnp 2>/dev/null | grep -E ":443 " || echo "(никто не слушает)"); ' +
    'echo ""; echo "=== Статус сервисов ==="; ' +
    'echo "caddy:            $(systemctl is-active caddy 2>/dev/null || echo unknown)"; ' +
    'echo "hysteria-server:  $(systemctl is-active hysteria-server 2>/dev/null || echo unknown)"; ' +
    'echo ""; echo "=== Hysteria TLS ==="; ' +
    'if [ -f /etc/hysteria/config.yaml ]; then ' +
    '  TLS_CERT=$(grep -E "^\\s*cert:" /etc/hysteria/config.yaml 2>/dev/null | head -1 | sed "s/.*cert:\\s*//" | tr -d " "); ' +
    '  TLS_KEY=$(grep -E "^\\s*key:" /etc/hysteria/config.yaml 2>/dev/null | head -1 | sed "s/.*key:\\s*//" | tr -d " "); ' +
    '  ACME_ON=$(grep -c "^acme:" /etc/hysteria/config.yaml 2>/dev/null || echo 0); ' +
    '  if [ -n "$TLS_CERT" ]; then ' +
    '    echo "TLS mode: shared (Caddy cert)"; ' +
    '    echo "cert: $TLS_CERT"; ' +
    '    if [ -f "$TLS_CERT" ]; then echo "  └─ exists ✓ ($(stat -c %s "$TLS_CERT") bytes, perms $(stat -c %a "$TLS_CERT"))"; ' +
    '    else echo "  └─ FILE MISSING ✗ (Hy2 не сможет загрузиться!)"; fi; ' +
    '    echo "key:  $TLS_KEY"; ' +
    '    if [ -f "$TLS_KEY" ]; then echo "  └─ exists ✓ (perms $(stat -c %a "$TLS_KEY"))"; ' +
    '    else echo "  └─ FILE MISSING ✗"; fi; ' +
    '  elif [ "$ACME_ON" -gt 0 ]; then ' +
    '    echo "TLS mode: ACME (Hy2 сам получает cert)"; ' +
    '    echo "(убедитесь что порт 80/tcp свободен или что cert уже получен)"; ' +
    '  else echo "TLS: НЕ НАСТРОЕН в конфиге ✗"; fi; ' +
    'else echo "/etc/hysteria/config.yaml не найден"; fi; ' +
    'echo ""; echo "=== Masquerade ==="; ' +
    'if [ -f /etc/hysteria/config.yaml ]; then ' +
    '  MASQ_TYPE=$(awk "/^masquerade:/{f=1;next} f && /^[^ ]/{f=0} f && /type:/{print \\$2; exit}" /etc/hysteria/config.yaml); ' +
    '  echo "type: ${MASQ_TYPE:-(не задано)}"; ' +
    'fi'
  ]);
  let out = '';
  p.stdout.on('data', d => out += d.toString());
  p.on('close', () => res.json({ output: out }));
  p.on('error', () => res.json({ output: 'команды недоступны' }));
});

// Просмотр активного hysteria config.yaml (с маскировкой паролей)
app.get('/api/diag/hysteria-config', requireAuth, (req, res) => {
  const cfgPath = '/etc/hysteria/config.yaml';
  if (!fs.existsSync(cfgPath)) {
    return res.json({ exists: false, output: '/etc/hysteria/config.yaml не найден' });
  }
  try {
    let raw = fs.readFileSync(cfgPath, 'utf8');
    // Маскируем пароли userpass
    raw = raw.replace(/(\s+)([a-zA-Z0-9_.-]+)(:\s*)"[^"]+"/g,
      (m, sp, user, col) => `${sp}${user}${col}"***masked***"`);
    res.json({ exists: true, output: raw });
  } catch (e) {
    res.json({ exists: false, output: 'Ошибка чтения: ' + e.message });
  }
});

// ═══════════════════════════════════════════════════════════
//  HY2 TLS AUTO-FIX (заменяет acme: на tls: с путями к Caddy cert)
// ═══════════════════════════════════════════════════════════
// Частая проблема: при установке Caddy получил серт от ZeroSSL, install.sh
// искал только по пути Let's Encrypt, не нашёл → прописал acme: в Hy2 конфиге →
// Hy2 попытался получить свой серт LE → HTTP 429 rate limit на неделю.
// Этот endpoint находит фактический серт Caddy через find и переписывает
// секцию TLS Hy2 конфига.
app.post('/api/diag/fix-hy2-tls', requireAuth, async (req, res) => {
  try {
    const cfg = loadConfig();
    if (!cfg.stack || !cfg.stack.hy2) {
      return res.status(400).json({ ok: false, error: 'Hy2 не установлен' });
    }
    const domain = cfg.domain;
    if (!domain) {
      return res.status(400).json({ ok: false, error: 'Домен не задан в config' });
    }

    // Ищем cert по всем возможным путям и CA
    const roots = [
      '/var/lib/caddy/.local/share/caddy/certificates',
      '/root/.local/share/caddy/certificates'
    ];
    let certPath = null, keyPath = null, ca = null;
    for (const root of roots) {
      if (!fs.existsSync(root)) continue;
      try {
        const result = require('child_process').execSync(
          `find "${root}" -type f -name "${domain}.crt" 2>/dev/null | head -1`,
          { encoding: 'utf8' }
        ).trim();
        if (result && fs.existsSync(result)) {
          const k = result.replace(/\.crt$/, '.key');
          if (fs.existsSync(k)) {
            certPath = result;
            keyPath = k;
            ca = path.basename(path.dirname(path.dirname(result)));
            break;
          }
        }
      } catch (e) { /* ignore find errors */ }
    }

    if (!certPath) {
      return res.status(404).json({
        ok: false,
        error: 'Сертификат Caddy не найден на диске',
        hint: 'Caddy должен получить сертификат (проверьте: systemctl status caddy; journalctl -u caddy -n 50)'
      });
    }

    // Ставим права чтоб Hy2 мог читать
    try {
      require('child_process').execSync(
        `chmod -R 755 "${path.dirname(path.dirname(path.dirname(certPath)))}" 2>/dev/null; ` +
        `chmod 644 "${certPath}" 2>/dev/null; ` +
        `chmod 640 "${keyPath}" 2>/dev/null`,
        { encoding: 'utf8' }
      );
    } catch {}

    // Читаем config.yaml
    const hyCfgPath = '/etc/hysteria/config.yaml';
    let hyCfg = {};
    if (fs.existsSync(hyCfgPath)) {
      hyCfg = yaml.load(fs.readFileSync(hyCfgPath, 'utf8')) || {};
    }

    // Убираем acme: секцию, вставляем tls:
    delete hyCfg.acme;
    hyCfg.tls = { cert: certPath, key: keyPath };

    // Пишем обратно
    fs.writeFileSync(hyCfgPath, yaml.dump(hyCfg, { lineWidth: 120, quotingType: '"' }), 'utf8');

    // Сбрасываем счётчик рестартов и перезапускаем Hy2
    const { execSync } = require('child_process');
    try { execSync('systemctl reset-failed hysteria-server 2>/dev/null'); } catch {}
    try { execSync('systemctl restart hysteria-server'); } catch (e) {
      return res.status(500).json({
        ok: false,
        error: 'Конфиг обновлён, но hysteria-server не перезапустился',
        details: e.message,
        certPath, keyPath, ca
      });
    }

    // Проверяем что стартовал
    await new Promise(r => setTimeout(r, 2500));
    let active = false;
    try { active = execSync('systemctl is-active hysteria-server').toString().trim() === 'active'; } catch {}

    res.json({
      ok: active,
      message: active
        ? `Hy2 TLS починен — cert от ${ca}, сервис запущен`
        : `Конфиг обновлён, но сервис не активен. journalctl -u hysteria-server -n 30`,
      certPath, keyPath, ca
    });
  } catch (e) {
    res.status(500).json({ ok: false, error: e.message });
  }
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
          hy2: `hysteria2://default:${encodeURIComponent(password)}@${domain}:443?sni=${domain}&insecure=0#RIXXX`
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
    NAIVE_LOGIN: naiveLogin, NAIVE_PASSWORD: naivePassword,
    WITH_HY2: '1'  // отключит HTTP/3 в Caddy → UDP/443 свободен для Hy2
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
            hy2:   `hysteria2://default:${encodeURIComponent(hy2Password)}@${domain}:443?sni=${domain}&insecure=0#RIXXX`
          }
        }));
      } else {
        ws.send(JSON.stringify({ type: 'install_error', message: `Hy2 failed: ${codeHy}` }));
      }
    });
  });
}

// ═══════════════════════════════════════════════════════════
//  EXPIRE CHECKER — каждые 5 минут фильтрует истёкших и релоадит сервисы
// ═══════════════════════════════════════════════════════════
let _lastExpireSig = '';
async function expireChecker() {
  try {
    const cfg = loadConfig();
    if (!cfg.installed) return;

    // Сигнатура «кто истёк» — чтобы не релоадить без причины
    const sig = JSON.stringify([
      (cfg.naiveUsers || []).filter(isExpired).map(u => u.username).sort(),
      (cfg.hy2Users   || []).filter(isExpired).map(u => u.username).sort()
    ]);
    if (sig === _lastExpireSig) return;
    _lastExpireSig = sig;

    const naiveExpired = (cfg.naiveUsers || []).filter(isExpired).length;
    const hy2Expired   = (cfg.hy2Users   || []).filter(isExpired).length;
    if (naiveExpired === 0 && hy2Expired === 0) return;

    console.log(`[expire-check] naive=${naiveExpired} hy2=${hy2Expired} — обновляю конфиги`);
    if (cfg.stack.naive && naiveExpired > 0) {
      writeCaddyfile(cfg);
      await reloadCaddy();
    }
    if (cfg.stack.hy2 && hy2Expired > 0) {
      writeHysteriaConfig(cfg);
      await reloadHysteria();
    }
  } catch (e) {
    console.error('[expire-check] error:', e.message);
  }
}
setInterval(expireChecker, 5 * 60 * 1000);
setTimeout(expireChecker, 20 * 1000); // первый запуск через 20 сек после старта

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

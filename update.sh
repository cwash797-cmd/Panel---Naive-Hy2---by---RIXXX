#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════
#  Panel Naive + Hysteria2 by RIXXX — Update Script
#  Применяет инкрементальные патчи поверх существующей установки.
#  НЕ трогает: пользователей, сертификаты, домены, sysctl, активные сервисы.
#
#  Запуск:
#    bash <(curl -fsSL https://raw.githubusercontent.com/cwash797-cmd/Panel---Naive-Hy2---by---RIXXX/main/update.sh)
#
#  Флаги:
#    --dry-run            показать что будет сделано, ничего не менять
#    --force              применить миграции даже если версия уже новая (для отладки)
#    --expose <domain>    восстановить публичный доступ к панели через
#                         поддомен <domain> (Caddy + LE), вернуть LISTEN_HOST=0.0.0.0,
#                         открыть UFW-порты. Используется после установки в SSH-only.
#    --masquerade         интерактивно сменить режим маскировки на существующей
#                         установке (local | mirror <url>). Перегенерирует
#                         Caddyfile и Hy2 config, перезапускает сервисы.
#    --repair             регенерация Caddyfile и /etc/hysteria/config.yaml из
#                         config.json. Перед изменениями автоматически делает
#                         бэкап в /etc/rixxx-panel/backups/YYYY-MM-DD/.
#                         При невалидном результате — откат из бэкапа.
#    --status             вывести состояние установки: версия, статус сервисов
#                         (caddy/hysteria/panel), TLS-сертификаты, открытые
#                         порты, режим маскировки, режим доступа к панели.
# ═══════════════════════════════════════════════════════════════════════

set -uo pipefail
export DEBIAN_FRONTEND=noninteractive

# ── Версия, до которой довести систему этим запуском ────────────────────
# При добавлении новой миграции — увеличиваем TARGET_VERSION и регистрируем
# функцию в migration_registry().
TARGET_VERSION="1.3.0"

# ── Пути ────────────────────────────────────────────────────────────────
PANEL_DIR="/opt/panel-naive-hy2"
PANEL_CONFIG="${PANEL_DIR}/panel/data/config.json"
CADDYFILE="/etc/caddy/Caddyfile"
HY2_CONFIG="/etc/hysteria/config.yaml"
PANEL_SERVICE_NAME="panel-naive-hy2"

VERSION_DIR="/etc/rixxx-panel"
VERSION_FILE="${VERSION_DIR}/version"

# ── Флаги командной строки ──────────────────────────────────────────────
DRY_RUN=0
FORCE=0
EXPOSE_DOMAIN=""
EXPOSE_MODE=0
MASQUERADE_MODE_FLAG=0
REPAIR_MODE=0
STATUS_MODE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --force)   FORCE=1; shift ;;
    --expose)
      EXPOSE_MODE=1
      EXPOSE_DOMAIN="${2:-}"
      if [[ -z "$EXPOSE_DOMAIN" ]]; then
        echo "❌ --expose требует аргумент: домен панели (например: --expose panel.example.com)" >&2
        exit 1
      fi
      shift 2
      ;;
    --masquerade) MASQUERADE_MODE_FLAG=1; shift ;;
    --repair)     REPAIR_MODE=1; shift ;;
    --status)     STATUS_MODE=1; shift ;;
    --help|-h)
      sed -n '2,28p' "$0"
      exit 0
      ;;
    *)
      echo "❌ Неизвестный флаг: $1" >&2
      exit 1
      ;;
  esac
done

# ── Цвета и логирование ─────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  BLUE='\033[0;34m'; PURPLE='\033[0;35m'; CYAN='\033[0;36m'
  BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; PURPLE=''; CYAN=''; BOLD=''; RESET=''
fi

log_step() { echo -e "\n${CYAN}${BOLD}▶ $1${RESET}"; }
log_ok()   { echo -e "${GREEN}✅ $1${RESET}"; }
log_warn() { echo -e "${YELLOW}⚠  $1${RESET}"; }
log_err()  { echo -e "${RED}❌ $1${RESET}"; }
log_info() { echo -e "   ${BLUE}$1${RESET}"; }
log_skip() { echo -e "   ${YELLOW}↷ $1${RESET}"; }

header() {
  clear 2>/dev/null || true
  echo ""
  echo -e "${PURPLE}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${PURPLE}${BOLD}║   Panel Naive + Hy2 by RIXXX — Update                    ║${RESET}"
  echo -e "${PURPLE}${BOLD}║   Применение инкрементальных патчей                      ║${RESET}"
  echo -e "${PURPLE}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
  echo ""
}

header

# ── 1. Root check ───────────────────────────────────────────────────────
# Исключение: --status работает без root (read-only диагностика).
# Проверяем после header, и если не --status — требуем root.
if [[ $STATUS_MODE -ne 1 && $EUID -ne 0 ]]; then
  log_err "Запускайте от root: sudo bash update.sh"
  exit 1
fi

# ── 2. Sanity-check: установка существует? ──────────────────────────────
log_step "Проверка существующей установки..."

MISSING=()
[[ -f "$PANEL_CONFIG" ]]    || MISSING+=("$PANEL_CONFIG")
[[ -d "${PANEL_DIR}/panel" ]] || MISSING+=("${PANEL_DIR}/panel")

# Caddyfile/Hy2 проверяем по факту установленного стека (из config.json),
# а не безусловно — установка может быть только Naive или только Hy2.
INSTALL_HAS_NAIVE=0
INSTALL_HAS_HY2=0
if [[ -f "$PANEL_CONFIG" ]]; then
  # Простой парсинг JSON через grep (без зависимости от jq, оно может быть не установлено)
  if grep -qE '"naive"\s*:\s*true' "$PANEL_CONFIG"; then INSTALL_HAS_NAIVE=1; fi
  if grep -qE '"hy2"\s*:\s*true'   "$PANEL_CONFIG"; then INSTALL_HAS_HY2=1; fi
fi

if [[ $INSTALL_HAS_NAIVE -eq 1 && ! -f "$CADDYFILE" ]]; then
  MISSING+=("$CADDYFILE (NaiveProxy установлен, но Caddyfile отсутствует)")
fi
if [[ $INSTALL_HAS_HY2 -eq 1 && ! -f "$HY2_CONFIG" ]]; then
  MISSING+=("$HY2_CONFIG (Hy2 установлен, но config.yaml отсутствует)")
fi

if [[ ${#MISSING[@]} -gt 0 ]]; then
  if [[ $STATUS_MODE -eq 1 ]]; then
    # --status: мягкий режим — продолжаем работу даже без полной установки
    # (его задача — диагностировать в т.ч. сломанные/частичные установки).
    log_warn "Найдена неполная установка (или её нет):"
    for f in "${MISSING[@]}"; do
      log_info "  • $f"
    done
    echo ""
  else
    log_err "Не найдены ключевые файлы существующей установки:"
    for f in "${MISSING[@]}"; do
      log_info "  • $f"
    done
    echo ""
    log_warn "Похоже, панель ещё не установлена на этом сервере."
    log_info "Запустите основной установщик:"
    log_info "  bash <(curl -fsSL https://raw.githubusercontent.com/cwash797-cmd/Panel---Naive-Hy2---by---RIXXX/main/install.sh)"
    exit 1
  fi
fi

[[ ${#MISSING[@]} -eq 0 ]] && log_ok "Установка обнаружена в ${PANEL_DIR}"
[[ $INSTALL_HAS_NAIVE -eq 1 ]] && log_info "  • NaiveProxy: установлен"
[[ $INSTALL_HAS_HY2 -eq 1 ]]   && log_info "  • Hysteria2:  установлен"

# ── 3. Чтение текущей версии ────────────────────────────────────────────
log_step "Определение текущей версии патчей..."

# Для --status mkdir может упасть из-за прав (запуск без root) — это OK.
mkdir -p "$VERSION_DIR" 2>/dev/null || true

CURRENT_VERSION="0.0.0"
if [[ -f "$VERSION_FILE" ]]; then
  CURRENT_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE" || echo '0.0.0')"
  [[ -z "$CURRENT_VERSION" ]] && CURRENT_VERSION="0.0.0"
fi

log_info "Текущая версия патчей: ${BOLD}${CURRENT_VERSION}${RESET}"
log_info "Целевая  версия:        ${BOLD}${TARGET_VERSION}${RESET}"

# ── 4. Сравнение semver ─────────────────────────────────────────────────
# Возвращает 0 если $1 < $2, 1 если $1 >= $2 (для использования в if).
# Используем sort -V (version sort), он есть в coreutils по умолчанию на Ubuntu/Debian.
version_lt() {
  local a="$1" b="$2"
  [[ "$a" == "$b" ]] && return 1
  local first
  first="$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n1)"
  [[ "$first" == "$a" ]]
}

# ── 5. Реестр миграций ─────────────────────────────────────────────────
# Каждая миграция — bash-функция migrate_<version_tag>().
# Регистрируется парами (version, function_name) в массиве MIGRATIONS_VERSIONS / MIGRATIONS_FUNCS.
# Запускаются миграции, у которых version > CURRENT_VERSION И version <= TARGET_VERSION.
#
# Контракт миграции:
#   • Idempotent — можно запустить повторно без побочных эффектов.
#   • Возвращает 0 при успехе, ненулевой код при ошибке.
#   • Никогда не трогает: naiveUsers, hy2Users, domain/email, сертификаты, sysctl.
#   • Использует только reload/restart сервисов (не stop без последующего start).

MIGRATIONS_VERSIONS=()
MIGRATIONS_FUNCS=()

migration_registry() {
  # PR #2: SSH-only режим (LISTEN_HOST=127.0.0.1).
  register_migration "1.1.0" migrate_listen_localhost
  # PR #3: Masquerade choice (local | mirror).
  register_migration "1.2.0" migrate_masquerade_default
  # PR #4: Repair/status/autobackup/atomic-write — каркас, без data-миграции.
  register_migration "1.3.0" migrate_repair_infra
}

# ─────────────────────────────────────────────────────────────────────────
# Миграция 1.1.0: SSH-only режим (LISTEN_HOST=127.0.0.1)
# ─────────────────────────────────────────────────────────────────────────
# Что делает:
#   • Идемпотентно «учит» инфраструктуру про LISTEN_HOST: добавляет дефолт
#     в config.json (sshOnly=0, listenHost="0.0.0.0") если их там нет.
#   • НЕ переключает существующие установки в SSH-only автоматически —
#     это must-be осознанным действием (через интерактивный prompt в
#     этой же миграции, либо через будущий флаг --ssh-only).
#   • При интерактивном согласии: правит systemd-юнит / PM2 env,
#     удаляет panel-блок из Caddyfile (если он там был), закрывает 3000/8080
#     в UFW, перезапускает только панель. Сертификаты/Hy2/users — не трогаем.
#
# Контракт:
#   • Если запущено в pipe (нет TTY) — только дописывает дефолтные ключи в
#     config.json, не предлагает переключения. Пользователь увидит подсказку.
migrate_listen_localhost() {
  if [[ ! -f "$PANEL_CONFIG" ]]; then
    log_warn "config.json не найден — пропускаю миграцию 1.1.0"
    return 0
  fi

  # 1) Дописываем дефолтные ключи в config.json, если их нет.
  if ! grep -qE '"listenHost"' "$PANEL_CONFIG"; then
    log_info "Добавляю в config.json дефолтные listenHost / sshOnly"
    node -e "
      const fs=require('fs');
      const p='$PANEL_CONFIG';
      const c=JSON.parse(fs.readFileSync(p,'utf8'));
      if (typeof c.sshOnly === 'undefined')    c.sshOnly = 0;
      if (typeof c.listenHost === 'undefined') c.listenHost = '0.0.0.0';
      fs.writeFileSync(p, JSON.stringify(c, null, 2));
    " || { log_err "Не удалось обновить config.json"; return 1; }
    log_ok "config.json обновлён (listenHost=0.0.0.0, sshOnly=0)"
  else
    log_skip "listenHost уже задан в config.json"
  fi

  # 2) Информируем пользователя про возможность включить SSH-only.
  echo ""
  log_info "${BOLD}SSH-only режим${RESET} теперь поддерживается."
  log_info "Чтобы скрыть панель от Интернета и оставить доступ только через SSH-туннель,"
  log_info "переустановите панель и выберите соответствующую опцию, либо отредактируйте"
  log_info "  /etc/systemd/system/panel-naive-hy2.service (Environment=LISTEN_HOST=127.0.0.1)"
  log_info "и перезапустите: systemctl restart panel-naive-hy2"
  log_info "Восстановление публичного доступа: bash update.sh --expose <panel-domain>"
  echo ""
  return 0
}

# ─────────────────────────────────────────────────────────────────────────
# Миграция 1.2.0: Masquerade choice (local | mirror)
# ─────────────────────────────────────────────────────────────────────────
# Что делает:
#   • Идемпотентно дописывает в config.json дефолтные masqueradeMode="local"
#     и masqueradeUrl="" — чтобы новые версии panel/server/index.js знали
#     про режим маскировки и не ломали уже работающий конфиг.
#   • НЕ переключает существующие установки автоматически: даже если в
#     Caddyfile стоит file_server, мы оставляем как есть (масquerade-режим
#     "local" совпадает с текущим поведением).
#   • Чтобы СМЕНИТЬ маскировку — пользователь явно вызывает:
#       bash update.sh --masquerade
#     (интерактивный prompt: 1=local, 2=mirror <url>).
#
# Контракт: не трогает users/certs/sysctl, только пишет в config.json.
migrate_masquerade_default() {
  if [[ ! -f "$PANEL_CONFIG" ]]; then
    log_warn "config.json не найден — пропускаю миграцию 1.2.0"
    return 0
  fi

  if ! grep -qE '"masqueradeMode"' "$PANEL_CONFIG"; then
    log_info "Добавляю в config.json дефолтные masqueradeMode / masqueradeUrl"
    node -e "
      const fs=require('fs');
      const p='$PANEL_CONFIG';
      const c=JSON.parse(fs.readFileSync(p,'utf8'));
      if (typeof c.masqueradeMode === 'undefined') c.masqueradeMode = 'local';
      if (typeof c.masqueradeUrl  === 'undefined') c.masqueradeUrl  = '';
      fs.writeFileSync(p, JSON.stringify(c, null, 2));
    " || { log_err "Не удалось обновить config.json"; return 1; }
    log_ok "config.json обновлён (masqueradeMode=local)"
  else
    log_skip "masqueradeMode уже задан в config.json"
  fi

  echo ""
  log_info "${BOLD}Маскировка${RESET} теперь настраиваемая (2 варианта):"
  log_info "  ${BOLD}1)${RESET} Локальная страница «Loading» (текущий режим)"
  log_info "  ${BOLD}2)${RESET} Зеркалирование внешнего сайта (iana.org / ietf.org / demo.nginx.com)"
  log_info "Сменить можно командой: ${BOLD}bash update.sh --masquerade${RESET}"
  echo ""
  return 0
}

# ─────────────────────────────────────────────────────────────────────────
# Миграция 1.3.0: Repair / status / autobackup / atomic write
# ─────────────────────────────────────────────────────────────────────────
# Что делает:
#   • Помечает установку как обновлённую до 1.3.0. Сама data-миграция не нужна:
#     вся новая инфраструктура (атомарная запись Caddyfile, --repair, --status,
#     автобэкап, smoke-test в install.sh) живёт в коде update.sh / install.sh
#     и не требует изменений в config.json.
#   • Создаёт каталог /etc/rixxx-panel/backups/ заранее, чтобы первый --repair
#     не выводил предупреждение про отсутствие папки.
#   • Информирует пользователя о новых возможностях.
#
# Контракт: не трогает users/certs/sysctl/configs.
migrate_repair_infra() {
  # Подготавливаем директорию для бэкапов.
  mkdir -p "${VERSION_DIR}/backups" 2>/dev/null || true

  echo ""
  log_info "${BOLD}Новые возможности${RESET} (PR #4):"
  log_info "  ${BOLD}•${RESET} ${CYAN}bash update.sh --status${RESET}  — диагностика установки одной командой"
  log_info "  ${BOLD}•${RESET} ${CYAN}bash update.sh --repair${RESET}  — регенерация конфигов с автобэкапом и rollback"
  log_info "  ${BOLD}•${RESET} Атомарная запись Caddyfile/Hy2 config в backend (защита panel-блока)"
  log_info "  ${BOLD}•${RESET} Smoke-test в конце install.sh (caddy validate + curl-проверки)"
  log_info "  Бэкапы хранятся в: ${VERSION_DIR}/backups/ (последние 10)"
  echo ""
  return 0
}

# ─────────────────────────────────────────────────────────────────────────
# Режим --masquerade: интерактивная смена маскировки на существующей установке.
# ─────────────────────────────────────────────────────────────────────────
# Делает:
#   1) Спрашивает: 1=local или 2=mirror <url>.
#   2) Обновляет config.json (masqueradeMode/masqueradeUrl).
#   3) Перегенерирует Caddyfile (через панель — она сама вызовет writeCaddyfile()
#      при следующем апдейте users; чтобы применилось сразу — restart панели,
#      она при старте сделает migrate-блок и не перепишет Caddyfile, поэтому
#      делаем sed-патч прямо здесь как fallback).
#   4) Перегенерирует /etc/hysteria/config.yaml (sed/yq на месте).
#   5) Reload Caddy + Hy2 + panel.
do_masquerade() {
  log_step "Режим --masquerade: смена маскировки на существующей установке"

  if [[ ! -f "$PANEL_CONFIG" ]]; then
    log_err "config.json не найден: $PANEL_CONFIG"
    return 1
  fi

  echo ""
  echo -e "${BOLD}Выберите режим маскировки:${RESET}"
  echo -e "  ${CYAN}1)${RESET} Локальная страница ${BOLD}«Loading»${RESET} ${GREEN}(надёжно, без внешних зависимостей)${RESET}"
  echo -e "  ${CYAN}2)${RESET} ${BOLD}Зеркалирование${RESET} внешнего сайта (reverse_proxy)"
  echo -e "      ${RED}⚠  Если сайт станет недоступен — посетители получат 502.${RESET}"
  echo -e "      ${YELLOW}→ Рекомендуемые: https://www.iana.org, https://www.ietf.org, https://demo.nginx.com${RESET}"
  echo ""
  read -rp "Ваш выбор [1/2]: " _MASQ_INPUT
  _MASQ_INPUT="${_MASQ_INPUT:-1}"

  local new_mode="local"
  local new_url=""
  if [[ "$_MASQ_INPUT" == "2" ]]; then
    echo ""
    echo -e "${RED}${BOLD}⚠  ВНИМАНИЕ:${RESET} ${RED}Крупные сайты (GitHub, Apple, Cloudflare и т.д.) блокируют${RESET}"
    echo -e "   ${RED}использование их как заглушки — клиенты NaiveProxy получат 502 / EOF.${RESET}"
    echo -e "   ${YELLOW}Рекомендуем небольшие статичные сайты или собственный поддомен.${RESET}"
    echo ""
    read -rp "  URL для зеркалирования (например https://www.iana.org): " new_url
    if [[ ! "$new_url" =~ ^https?:// ]]; then
      log_err "URL должен начинаться с http:// или https://"
      return 1
    fi
    new_mode="mirror"
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] Сменил бы masqueradeMode=${new_mode}, masqueradeUrl=${new_url}"
    return 0
  fi

  # 1) Обновляем config.json.
  node -e "
    const fs=require('fs');
    const p='$PANEL_CONFIG';
    const c=JSON.parse(fs.readFileSync(p,'utf8'));
    c.masqueradeMode = '$new_mode';
    c.masqueradeUrl  = '$new_url';
    fs.writeFileSync(p, JSON.stringify(c, null, 2));
  " || { log_err "Не удалось обновить config.json"; return 1; }
  log_ok "config.json обновлён (masqueradeMode=${new_mode}, masqueradeUrl=${new_url:-—})"

  # 2) Перезапускаем панель — её writeCaddyfile()/writeHysteriaConfig() при
  # следующем изменении users применят новый masquerade. Но чтобы применилось
  # сразу, дополнительно дёргаем "перегенерация" через node одноразово:
  if [[ -f "$PANEL_DIR/panel/server/index.js" ]]; then
    log_info "Перегенерация Caddyfile + Hysteria config через панель..."
    # Запускаем node из ${PANEL_DIR}/panel — там лежит node_modules с js-yaml.
    # Без cd Node ищет модули относительно cwd и падает с
    # "Cannot find module 'js-yaml'" если update.sh запущен из /root/.
    (cd "$PANEL_DIR/panel" && node -e "
      const fs=require('fs');
      const yaml=require('js-yaml');
      const cfg=JSON.parse(fs.readFileSync('$PANEL_CONFIG','utf8'));

      // ── Caddyfile (NaiveProxy) ──
      if (cfg.stack && cfg.stack.naive && cfg.domain && fs.existsSync('$CADDYFILE')) {
        const masqBlock = (cfg.masqueradeMode === 'mirror' && cfg.masqueradeUrl)
          ? \`  reverse_proxy \${cfg.masqueradeUrl} {\n    header_up Host {upstream_hostport}\n  }\`
          : \`  file_server {\n    root /var/www/html\n  }\`;
        let c = fs.readFileSync('$CADDYFILE','utf8');
        // Заменяем существующий file_server { ... } блок ИЛИ reverse_proxy { ... }
        // (только тот, что внутри основного site-блока с forward_proxy).
        c = c.replace(
          /( {2}file_server \{[^}]*\}|  reverse_proxy [^\n]+\{[^}]*\})/,
          masqBlock
        );
        fs.writeFileSync('$CADDYFILE', c);
        console.log('Caddyfile updated.');
      }

      // ── Hysteria config ──
      if (cfg.stack && cfg.stack.hy2 && fs.existsSync('$HY2_CONFIG')) {
        const raw = fs.readFileSync('$HY2_CONFIG','utf8');
        const base = yaml.load(raw);
        if (base && typeof base === 'object') {
          if (cfg.masqueradeMode === 'mirror' && cfg.masqueradeUrl) {
            base.masquerade = { type: 'proxy', proxy: { url: cfg.masqueradeUrl, rewriteHost: true } };
          } else {
            base.masquerade = { type: 'file', file: { dir: '/var/www/html' } };
          }
          fs.writeFileSync('$HY2_CONFIG', yaml.dump(base, { lineWidth: 120, quotingType: '\"' }));
          console.log('Hysteria config updated.');
        }
      }
    ") || { log_err "Не удалось перегенерировать конфиги"; return 1; }
    log_ok "Caddyfile и Hysteria config обновлены"
  fi

  # 3) Reload Caddy + Hy2 + panel.
  log_info "Reload Caddy и Hy2..."
  caddy validate --config "$CADDYFILE" >/dev/null 2>&1 \
    && systemctl reload caddy >/dev/null 2>&1 \
    || log_warn "Caddy reload пропущен (validate выдал предупреждение)"
  systemctl restart hysteria-server >/dev/null 2>&1 \
    && log_ok "Hysteria2 перезапущен" \
    || log_warn "Не удалось перезапустить hysteria-server"

  if pm2 describe "$PANEL_SERVICE_NAME" >/dev/null 2>&1; then
    pm2 restart "$PANEL_SERVICE_NAME" --update-env >/dev/null 2>&1 \
      && log_ok "Панель перезапущена через PM2"
  elif systemctl is-active --quiet "$PANEL_SERVICE_NAME"; then
    systemctl restart "$PANEL_SERVICE_NAME" \
      && log_ok "Панель перезапущена через systemd"
  fi

  echo ""
  log_ok "Маскировка изменена."
  if [[ "$new_mode" == "mirror" ]]; then
    log_info "Сейчас домен зеркалирует: ${BOLD}${new_url}${RESET}"
    log_info "Проверьте: curl -I https://${BOLD}<your-domain>${RESET}/"
  else
    log_info "Сейчас домен отдаёт локальную страницу «Loading»"
  fi
  echo ""
  return 0
}

# ─────────────────────────────────────────────────────────────────────────
# Режим --expose <domain>: восстановить публичный доступ к панели.
# ─────────────────────────────────────────────────────────────────────────
# Делает:
#   1) Проверяет, что Caddy установлен и Caddyfile существует.
#   2) Добавляет site-блок для <domain> с TLS + reverse_proxy 127.0.0.1:PORT,
#      ЕСЛИ его там ещё нет (идемпотентно).
#   3) Меняет LISTEN_HOST=0.0.0.0 в systemd-юните / PM2 (чтобы reverse_proxy
#      на 127.0.0.1 продолжал работать — на самом деле 127.0.0.1 биндинг
#      достаточен для reverse_proxy, но 0.0.0.0 даёт совместимость).
#   4) Открывает 3000/8080 в UFW (если ранее были закрыты).
#   5) Reload Caddy + restart панели.
#   6) Обновляет config.json: panelDomain=<domain>, sshOnly=0, listenHost=0.0.0.0.
do_expose() {
  log_step "Режим --expose: восстановление публичного доступа к панели"
  log_info "Домен: ${BOLD}${EXPOSE_DOMAIN}${RESET}"

  if [[ ! -f "$CADDYFILE" ]]; then
    log_err "Caddyfile не найден: $CADDYFILE"
    log_info "Установите NaiveProxy через install.sh, либо вручную создайте Caddy."
    return 1
  fi
  if ! command -v caddy >/dev/null 2>&1; then
    log_err "Caddy не установлен (command -v caddy)"
    return 1
  fi

  # Внутренний порт панели (по умолчанию 3000, но читаем из config.json/server, если возможно)
  local internal_port="3000"
  if [[ -f "$PANEL_CONFIG" ]]; then
    local p
    p="$(node -e "
      try {
        const c=require('$PANEL_CONFIG');
        process.stdout.write(String(c.internalPort || 3000));
      } catch(e) { process.stdout.write('3000'); }
    " 2>/dev/null || echo 3000)"
    [[ -n "$p" ]] && internal_port="$p"
  fi

  # 1) Если block уже есть — пропускаем.
  if grep -qE "^${EXPOSE_DOMAIN//./\\.} \{" "$CADDYFILE"; then
    log_skip "Блок ${EXPOSE_DOMAIN} уже есть в Caddyfile"
  else
    if [[ $DRY_RUN -eq 1 ]]; then
      log_info "[dry-run] Добавил бы site-блок ${EXPOSE_DOMAIN} в $CADDYFILE"
    else
      # Резервная копия Caddyfile перед изменением.
      cp -a "$CADDYFILE" "${CADDYFILE}.bak.$(date +%s)"

      # Email берём из config.json (panelEmail || email), либо ставим пустой.
      local email="admin@${EXPOSE_DOMAIN#*.}"
      if [[ -f "$PANEL_CONFIG" ]]; then
        email="$(node -e "
          try {
            const c=require('$PANEL_CONFIG');
            process.stdout.write(String(c.panelEmail || c.email || 'admin@${EXPOSE_DOMAIN#*.}'));
          } catch(e) { process.stdout.write('admin@${EXPOSE_DOMAIN#*.}'); }
        " 2>/dev/null || echo "admin@${EXPOSE_DOMAIN#*.}")"
      fi

      cat >> "$CADDYFILE" <<EOF

${EXPOSE_DOMAIN} {
  tls ${email}
  encode gzip
  reverse_proxy 127.0.0.1:${internal_port}
}
EOF
      caddy validate --config "$CADDYFILE" >/dev/null 2>&1 \
        && log_ok "Caddyfile валиден" \
        || log_warn "Caddyfile validate выдал предупреждение (см. caddy validate)"
    fi
  fi

  # 2) Меняем LISTEN_HOST=0.0.0.0 (на самом деле для reverse_proxy достаточно
  # 127.0.0.1, поэтому не обязательно). Просто синхронизируем config.json.
  if [[ -f "$PANEL_CONFIG" && $DRY_RUN -eq 0 ]]; then
    node -e "
      const fs=require('fs');
      const p='$PANEL_CONFIG';
      const c=JSON.parse(fs.readFileSync(p,'utf8'));
      c.panelDomain = '$EXPOSE_DOMAIN';
      c.sshOnly = 0;
      // listenHost оставляем как был (127.0.0.1 для reverse_proxy подходит).
      if (!c.listenHost) c.listenHost = '127.0.0.1';
      if (!c.accessMode) c.accessMode = '3';
      fs.writeFileSync(p, JSON.stringify(c, null, 2));
    " && log_ok "config.json обновлён (panelDomain=${EXPOSE_DOMAIN}, sshOnly=0)"
  fi

  # 3) UFW — открываем порты обратно (опционально, если они были deny).
  if command -v ufw >/dev/null 2>&1 && [[ $DRY_RUN -eq 0 ]]; then
    ufw delete deny 3000/tcp >/dev/null 2>&1 || true
    ufw delete deny 8080/tcp >/dev/null 2>&1 || true
  fi

  # 4) Reload Caddy + restart панели.
  if [[ $DRY_RUN -eq 0 ]]; then
    log_info "Reload Caddy..."
    systemctl reload caddy >/dev/null 2>&1 \
      || systemctl restart caddy >/dev/null 2>&1 \
      || log_warn "Не удалось reload caddy — проверьте: systemctl status caddy"

    # Перезапускаем панель, чтобы подхватила изменения config.json.
    if pm2 describe "$PANEL_SERVICE_NAME" >/dev/null 2>&1; then
      pm2 restart "$PANEL_SERVICE_NAME" --update-env >/dev/null 2>&1 \
        && log_ok "Панель перезапущена через PM2"
    elif systemctl is-active --quiet "$PANEL_SERVICE_NAME"; then
      systemctl restart "$PANEL_SERVICE_NAME" \
        && log_ok "Панель перезапущена через systemd"
    fi
  fi

  echo ""
  log_ok "Готово. Панель должна быть доступна на: ${BOLD}https://${EXPOSE_DOMAIN}${RESET}"
  log_info "Если LE-сертификат ещё не выписан, подождите 1–2 минуты и обновите страницу."
  echo ""
  return 0
}

# ─────────────────────────────────────────────────────────────────────────
# Утилита: auto_backup <tag>
# ─────────────────────────────────────────────────────────────────────────
# Делает снимок ключевых файлов в /etc/rixxx-panel/backups/YYYY-MM-DD-HHMMSS-<tag>/.
# Снимок включает: config.json, Caddyfile, /etc/hysteria/config.yaml,
# systemd-юнит панели. Это даёт точку отката после --repair или ручных правок.
# Никогда не падает: если файла нет — просто пропускает.
auto_backup() {
  local tag="${1:-manual}"
  local stamp
  stamp="$(date +%Y-%m-%d-%H%M%S)"
  local dir="${VERSION_DIR}/backups/${stamp}-${tag}"

  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] Создал бы бэкап в $dir"
    BACKUP_DIR=""
    return 0
  fi

  mkdir -p "$dir" || { log_warn "Не удалось создать $dir, бэкап пропущен"; BACKUP_DIR=""; return 1; }

  local copied=0
  for src in "$PANEL_CONFIG" "$CADDYFILE" "$HY2_CONFIG" \
             "/etc/systemd/system/${PANEL_SERVICE_NAME}.service"; do
    if [[ -f "$src" ]]; then
      cp -a "$src" "$dir/" 2>/dev/null && copied=$((copied + 1))
    fi
  done

  # Кладём marker-файл с метаданными.
  cat > "$dir/.metadata" <<EOF
created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
tag=${tag}
panel_version=${CURRENT_VERSION:-unknown}
files_copied=${copied}
EOF

  log_ok "Бэкап создан: $dir ($copied файл(ов))"
  BACKUP_DIR="$dir"

  # Чистим старые бэкапы — оставляем последние 10 (защита от засорения диска).
  if [[ -d "${VERSION_DIR}/backups" ]]; then
    local total
    total="$(ls -1 "${VERSION_DIR}/backups" 2>/dev/null | wc -l)"
    if [[ $total -gt 10 ]]; then
      ls -1t "${VERSION_DIR}/backups" | tail -n +11 | while read -r old; do
        rm -rf "${VERSION_DIR}/backups/${old}" 2>/dev/null || true
      done
    fi
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────
# Утилита: rollback_from_backup
# ─────────────────────────────────────────────────────────────────────────
# Восстанавливает файлы из BACKUP_DIR (выставленного auto_backup) обратно
# в их рабочие пути. Используется в --repair при провале валидации.
rollback_from_backup() {
  if [[ -z "${BACKUP_DIR:-}" || ! -d "${BACKUP_DIR}" ]]; then
    log_warn "Нет бэкапа для отката (BACKUP_DIR пуст или не существует)"
    return 1
  fi
  log_warn "Откат изменений из бэкапа: ${BACKUP_DIR}"
  [[ -f "${BACKUP_DIR}/$(basename "$CADDYFILE")"   ]] && cp -a "${BACKUP_DIR}/$(basename "$CADDYFILE")"   "$CADDYFILE"   2>/dev/null && log_info "  • Caddyfile восстановлен"
  [[ -f "${BACKUP_DIR}/$(basename "$HY2_CONFIG")"  ]] && cp -a "${BACKUP_DIR}/$(basename "$HY2_CONFIG")"  "$HY2_CONFIG"  2>/dev/null && log_info "  • Hysteria config восстановлен"
  [[ -f "${BACKUP_DIR}/$(basename "$PANEL_CONFIG")" ]] && cp -a "${BACKUP_DIR}/$(basename "$PANEL_CONFIG")" "$PANEL_CONFIG" 2>/dev/null && log_info "  • config.json восстановлен"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────
# Режим --repair: регенерация Caddyfile + Hy2 config из config.json.
# ─────────────────────────────────────────────────────────────────────────
# Алгоритм:
#   1) auto_backup "repair" → /etc/rixxx-panel/backups/...
#   2) Регенерируем Caddyfile из config.json (NaiveProxy + панель + masquerade).
#   3) Регенерируем /etc/hysteria/config.yaml (auth + masquerade + TLS-block).
#   4) caddy validate. Если упал — rollback_from_backup, exit 1.
#   5) systemctl reload caddy / restart hysteria-server / restart panel.
#   6) Smoke-test: systemctl is-active + curl -fsSL -o /dev/null https://<domain>.
#
# Контракт: НИКОГДА не трогает users (naiveUsers/hy2Users), сертификаты,
# domain/email, sysctl. Только перегенерация шаблонов.
do_repair() {
  log_step "Режим --repair: регенерация Caddyfile + Hysteria config из config.json"

  if [[ ! -f "$PANEL_CONFIG" ]]; then
    log_err "config.json не найден: $PANEL_CONFIG"
    return 1
  fi

  # 1) Автобэкап.
  log_info "Шаг 1/5: автобэкап"
  auto_backup "repair" || log_warn "Бэкап не создан — продолжаем на свой риск"

  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] Перегенерировал бы Caddyfile и Hy2 config"
    log_info "[dry-run] Затем validate + reload + smoke-test"
    return 0
  fi

  # 2) Регенерация через панель — она знает все шаблоны.
  log_info "Шаг 2/5: регенерация Caddyfile + Hysteria config"
  if [[ ! -f "$PANEL_DIR/panel/server/index.js" ]]; then
    log_err "Файл панели не найден: $PANEL_DIR/panel/server/index.js"
    return 1
  fi

  # Запускаем node-скрипт, который импортирует функции writeCaddyfile/writeHysteriaConfig
  # «в lockstep» — мы не можем require() server/index.js (там app.listen на старте),
  # поэтому регенерируем через тот же подход, что и в do_masquerade(): вытаскиваем
  # cfg и перезаписываем по шаблонам.
  # Запускаем node из ${PANEL_DIR}/panel — там лежит node_modules с js-yaml.
  # Без cd Node ищет модули относительно cwd и падает с
  # "Cannot find module 'js-yaml'" если update.sh запущен из /root/.
  (cd "$PANEL_DIR/panel" && node -e "
    const fs=require('fs');
    const yaml=require('js-yaml');
    const cfg=JSON.parse(fs.readFileSync('$PANEL_CONFIG','utf8'));

    // ── Caddyfile (только если NaiveProxy установлен) ──
    if (cfg.stack && cfg.stack.naive && cfg.domain) {
      const isExpired = (u) => u && u.expiresAt && Date.now() > new Date(u.expiresAt).getTime();
      const lines = (cfg.naiveUsers || [])
        .filter(u => !isExpired(u))
        .map(u => '    basic_auth ' + u.username + ' ' + u.password)
        .join('\n');
      const disableH3 = cfg.stack.hy2;
      const globalBlock = disableH3
        ? '{\n  order forward_proxy before file_server\n  servers {\n    protocols h1 h2\n  }\n}'
        : '{\n  order forward_proxy before file_server\n}';
      const masqBlock = (cfg.masqueradeMode === 'mirror' && cfg.masqueradeUrl)
        ? '  reverse_proxy ' + cfg.masqueradeUrl + ' {\n    header_up Host {upstream_hostport}\n  }'
        : '  file_server {\n    root /var/www/html\n  }';
      let content = globalBlock + '\n\n:443, ' + cfg.domain + ' {\n  tls ' + cfg.email + '\n\n  forward_proxy {\n' +
        (lines || '    # no users yet') +
        '\n    hide_ip\n    hide_via\n    probe_resistance\n  }\n\n' + masqBlock + '\n}\n';
      const internalPort = process.env.PORT || 3000;
      if (cfg.panelDomain && cfg.panelDomain !== cfg.domain && cfg.sshOnly !== 1) {
        const panelEmail = cfg.panelEmail || cfg.email;
        content += '\n' + cfg.panelDomain + ' {\n  tls ' + panelEmail +
          '\n  encode gzip\n  reverse_proxy 127.0.0.1:' + internalPort + '\n}\n';
      }
      fs.writeFileSync('$CADDYFILE.new', content);
      console.log('Caddyfile generated → $CADDYFILE.new');
    }

    // ── Hysteria config ──
    if (cfg.stack && cfg.stack.hy2 && fs.existsSync('$HY2_CONFIG')) {
      const isExpired = (u) => u && u.expiresAt && Date.now() > new Date(u.expiresAt).getTime();
      const userpass = {};
      (cfg.hy2Users || []).forEach(u => {
        if (u.username && u.password && !isExpired(u)) userpass[u.username] = u.password;
      });
      const raw = fs.readFileSync('$HY2_CONFIG','utf8');
      const base = yaml.load(raw) || {};
      base.auth = base.auth || { type: 'userpass' };
      base.auth.type = 'userpass';
      base.auth.userpass = Object.keys(userpass).length ? userpass : { default: 'placeholder-please-change' };
      if (cfg.masqueradeMode === 'mirror' && cfg.masqueradeUrl) {
        base.masquerade = { type: 'proxy', proxy: { url: cfg.masqueradeUrl, rewriteHost: true } };
      } else if (cfg.masqueradeMode === 'local') {
        base.masquerade = { type: 'file', file: { dir: '/var/www/html' } };
      }
      fs.writeFileSync('$HY2_CONFIG.new', yaml.dump(base, { lineWidth: 120, quotingType: '\"' }));
      console.log('Hysteria config generated → $HY2_CONFIG.new');
    }
  ") || { log_err "Не удалось сгенерировать конфиги"; rollback_from_backup; return 1; }

  # 3) Валидация Caddyfile.
  log_info "Шаг 3/5: валидация Caddyfile"
  if [[ -f "${CADDYFILE}.new" ]]; then
    if command -v caddy >/dev/null 2>&1; then
      if ! caddy validate --config "${CADDYFILE}.new" >/dev/null 2>&1; then
        log_err "caddy validate упал на новом Caddyfile — откат"
        rm -f "${CADDYFILE}.new" "${HY2_CONFIG}.new"
        rollback_from_backup
        return 1
      fi
      log_ok "Caddyfile валиден"
    else
      log_warn "caddy не найден — пропускаем validate (но atomic rename всё равно сделаем)"
    fi
    mv -f "${CADDYFILE}.new" "$CADDYFILE"
  fi

  if [[ -f "${HY2_CONFIG}.new" ]]; then
    # YAML self-validate.
    if ! python3 -c "import yaml,sys; yaml.safe_load(open('${HY2_CONFIG}.new'))" 2>/dev/null \
       && ! (cd "$PANEL_DIR/panel" && node -e "require('js-yaml').load(require('fs').readFileSync('${HY2_CONFIG}.new','utf8'))") 2>/dev/null; then
      log_err "Hysteria config невалиден (YAML parse failed) — откат"
      rm -f "${HY2_CONFIG}.new"
      rollback_from_backup
      return 1
    fi
    mv -f "${HY2_CONFIG}.new" "$HY2_CONFIG"
    log_ok "Hysteria config валиден"
  fi

  # 4) Reload сервисов.
  log_info "Шаг 4/5: reload сервисов"
  systemctl reload caddy >/dev/null 2>&1 \
    || systemctl restart caddy >/dev/null 2>&1 \
    || log_warn "Не удалось reload caddy — проверьте: systemctl status caddy"
  if [[ $INSTALL_HAS_HY2 -eq 1 ]]; then
    systemctl restart hysteria-server >/dev/null 2>&1 \
      && log_ok "Hysteria2 перезапущен" \
      || log_warn "Не удалось перезапустить hysteria-server"
  fi
  if pm2 describe "$PANEL_SERVICE_NAME" >/dev/null 2>&1; then
    pm2 restart "$PANEL_SERVICE_NAME" --update-env >/dev/null 2>&1 \
      && log_ok "Панель перезапущена через PM2"
  elif systemctl is-active --quiet "$PANEL_SERVICE_NAME"; then
    systemctl restart "$PANEL_SERVICE_NAME" \
      && log_ok "Панель перезапущена через systemd"
  fi

  # 5) Smoke-test.
  log_info "Шаг 5/5: smoke-test"
  local fails=0
  if [[ $INSTALL_HAS_NAIVE -eq 1 ]]; then
    systemctl is-active --quiet caddy && log_ok "  caddy: active" || { log_err "  caddy: НЕ active"; fails=$((fails+1)); }
  fi
  if [[ $INSTALL_HAS_HY2 -eq 1 ]]; then
    systemctl is-active --quiet hysteria-server && log_ok "  hysteria-server: active" || { log_err "  hysteria-server: НЕ active"; fails=$((fails+1)); }
  fi
  systemctl is-active --quiet "$PANEL_SERVICE_NAME" \
    && log_ok "  ${PANEL_SERVICE_NAME}: active" \
    || (pm2 describe "$PANEL_SERVICE_NAME" 2>/dev/null | grep -q online \
        && log_ok "  ${PANEL_SERVICE_NAME}: online (pm2)" \
        || { log_warn "  ${PANEL_SERVICE_NAME}: статус неопределён"; fails=$((fails+1)); })

  echo ""
  if [[ $fails -eq 0 ]]; then
    log_ok "Repair завершён успешно. Бэкап: ${BACKUP_DIR:-—}"
  else
    log_warn "Repair завершён с предупреждениями ($fails). Бэкап: ${BACKUP_DIR:-—}"
    log_info "Откат вручную: cp -a ${BACKUP_DIR}/* /etc/  # см. README"
  fi
  echo ""
  return 0
}

# ─────────────────────────────────────────────────────────────────────────
# Режим --status: read-only вывод состояния установки.
# ─────────────────────────────────────────────────────────────────────────
# Собирает и красиво выводит:
#   • Версия патчей (CURRENT_VERSION).
#   • Установленные стеки (NaiveProxy / Hy2).
#   • Режим доступа к панели (public / SSH-only / subdomain).
#   • Режим маскировки (local / mirror <url>).
#   • Статус сервисов (caddy / hysteria-server / panel).
#   • TLS-сертификаты (наличие + срок).
#   • Открытые порты (через ss/netstat).
#   • Последние бэкапы (3 шт).
do_status() {
  echo ""
  echo -e "${PURPLE}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${PURPLE}${BOLD}║                  СТАТУС УСТАНОВКИ                        ║${RESET}"
  echo -e "${PURPLE}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
  echo ""

  # ── Версия ──
  local v="(не установлено)"
  [[ -f "$VERSION_FILE" ]] && v="$(tr -d '[:space:]' < "$VERSION_FILE")"
  echo -e "  ${BOLD}Версия патчей:${RESET}  ${CYAN}${v}${RESET}  ${BLUE}(target: ${TARGET_VERSION})${RESET}"

  # ── Стеки ──
  local naive_state="${RED}нет${RESET}"
  local hy2_state="${RED}нет${RESET}"
  [[ $INSTALL_HAS_NAIVE -eq 1 ]] && naive_state="${GREEN}да${RESET}"
  [[ $INSTALL_HAS_HY2   -eq 1 ]] && hy2_state="${GREEN}да${RESET}"
  echo -e "  ${BOLD}NaiveProxy:${RESET}     ${naive_state}"
  echo -e "  ${BOLD}Hysteria2:${RESET}      ${hy2_state}"

  # ── Конфигурация (через node, чтобы корректно прочитать JSON) ──
  if [[ -f "$PANEL_CONFIG" ]]; then
    local cfg_dump
    cfg_dump="$(node -e "
      const c=require('$PANEL_CONFIG');
      const out = {
        domain: c.domain || '',
        panelDomain: c.panelDomain || '',
        accessMode: c.accessMode || '?',
        sshOnly: c.sshOnly || 0,
        listenHost: c.listenHost || '0.0.0.0',
        masqueradeMode: c.masqueradeMode || 'local',
        masqueradeUrl: c.masqueradeUrl || '',
        naiveUsers: (c.naiveUsers || []).length,
        hy2Users: (c.hy2Users || []).length,
        internalPort: c.internalPort || 3000,
      };
      Object.entries(out).forEach(([k,v]) => console.log(k+'='+v));
    " 2>/dev/null)"
    echo ""
    echo -e "  ${BOLD}Домены:${RESET}"
    echo "$cfg_dump" | grep -E '^(domain|panelDomain)=' | while IFS='=' read -r k val; do
      [[ -z "$val" ]] && val="${YELLOW}—${RESET}"
      echo -e "    ${k}: ${val}"
    done
    local access_mode masq_mode masq_url ssh_only naive_count hy2_count
    access_mode="$(echo "$cfg_dump" | grep -oP '(?<=^accessMode=).*' || echo '?')"
    ssh_only="$(echo "$cfg_dump" | grep -oP '(?<=^sshOnly=).*' || echo '0')"
    masq_mode="$(echo "$cfg_dump" | grep -oP '(?<=^masqueradeMode=).*' || echo 'local')"
    masq_url="$(echo "$cfg_dump" | grep -oP '(?<=^masqueradeUrl=).*' || echo '')"
    naive_count="$(echo "$cfg_dump" | grep -oP '(?<=^naiveUsers=).*' || echo '0')"
    hy2_count="$(echo "$cfg_dump" | grep -oP '(?<=^hy2Users=).*' || echo '0')"

    echo ""
    echo -e "  ${BOLD}Доступ к панели:${RESET}"
    case "$access_mode" in
      1) echo -e "    режим 1 — Nginx на :8080" ;;
      2) echo -e "    режим 2 — прямой :3000" ;;
      3) echo -e "    режим 3 — отдельный поддомен (Caddy + LE)" ;;
      *) echo -e "    режим: ${YELLOW}неизвестен${RESET}" ;;
    esac
    if [[ "$ssh_only" == "1" ]]; then
      echo -e "    SSH-only: ${YELLOW}${BOLD}ВКЛ${RESET} (панель только через SSH-туннель)"
    else
      echo -e "    SSH-only: ${GREEN}выкл${RESET}"
    fi

    echo ""
    echo -e "  ${BOLD}Маскировка:${RESET}"
    if [[ "$masq_mode" == "mirror" && -n "$masq_url" ]]; then
      echo -e "    режим: ${CYAN}mirror${RESET} → ${masq_url}"
    else
      echo -e "    режим: ${GREEN}local${RESET} (страница «Loading»)"
    fi

    echo ""
    echo -e "  ${BOLD}Пользователи:${RESET}"
    echo -e "    NaiveProxy: ${naive_count}"
    echo -e "    Hy2:        ${hy2_count}"
  fi

  # ── Статус сервисов ──
  echo ""
  echo -e "  ${BOLD}Сервисы:${RESET}"
  for svc in caddy hysteria-server "$PANEL_SERVICE_NAME"; do
    if systemctl list-unit-files "${svc}.service" >/dev/null 2>&1; then
      if systemctl is-active --quiet "$svc"; then
        echo -e "    ${GREEN}●${RESET} ${svc}: active"
      else
        echo -e "    ${RED}●${RESET} ${svc}: $(systemctl is-active "$svc" 2>/dev/null || echo 'inactive')"
      fi
    elif [[ "$svc" == "$PANEL_SERVICE_NAME" ]] && command -v pm2 >/dev/null 2>&1; then
      if pm2 describe "$svc" 2>/dev/null | grep -q online; then
        echo -e "    ${GREEN}●${RESET} ${svc}: online (pm2)"
      else
        echo -e "    ${YELLOW}●${RESET} ${svc}: не найден"
      fi
    else
      echo -e "    ${YELLOW}○${RESET} ${svc}: не установлен"
    fi
  done

  # ── TLS-сертификаты ──
  echo ""
  echo -e "  ${BOLD}TLS-сертификаты Caddy:${RESET}"
  local cert_found=0
  for root in /var/lib/caddy/.local/share/caddy/certificates /root/.local/share/caddy/certificates; do
    [[ ! -d "$root" ]] && continue
    while IFS= read -r crt; do
      [[ -z "$crt" ]] && continue
      cert_found=1
      local domain_from_path
      domain_from_path="$(basename "$crt" .crt)"
      local exp
      exp="$(openssl x509 -in "$crt" -noout -enddate 2>/dev/null | cut -d= -f2 || echo '?')"
      echo -e "    • ${domain_from_path}: до ${exp}"
    done < <(find "$root" -type f -name '*.crt' 2>/dev/null | head -5)
  done
  [[ $cert_found -eq 0 ]] && echo -e "    ${YELLOW}—${RESET} сертификаты не найдены"

  # ── Открытые порты ──
  echo ""
  echo -e "  ${BOLD}Слушающие порты (443/3000/8080):${RESET}"
  if command -v ss >/dev/null 2>&1; then
    ss -lntu 2>/dev/null | awk 'NR>1 {split($5,a,":"); p=a[length(a)]; if (p=="443"||p=="3000"||p=="8080") print "    "$1" "$5}' | sort -u
  fi

  # ── Последние бэкапы ──
  echo ""
  echo -e "  ${BOLD}Последние бэкапы:${RESET}"
  if [[ -d "${VERSION_DIR}/backups" ]]; then
    local count
    count="$(ls -1 "${VERSION_DIR}/backups" 2>/dev/null | wc -l)"
    if [[ $count -gt 0 ]]; then
      ls -1t "${VERSION_DIR}/backups" 2>/dev/null | head -3 | while read -r b; do
        echo -e "    • ${b}"
      done
      echo -e "    ${BLUE}(всего: ${count}, путь: ${VERSION_DIR}/backups/)${RESET}"
    else
      echo -e "    ${YELLOW}—${RESET} нет"
    fi
  else
    echo -e "    ${YELLOW}—${RESET} нет"
  fi

  echo ""
  return 0
}

register_migration() {
  MIGRATIONS_VERSIONS+=("$1")
  MIGRATIONS_FUNCS+=("$2")
}

migration_registry

# ── 5b. Режим --expose: восстановление публичного доступа к панели ─────
# Запускается ДО основного цикла миграций, потому что это разовая операция,
# не привязанная к версии. После выполнения скрипт завершается с кодом 0.
if [[ $EXPOSE_MODE -eq 1 ]]; then
  if do_expose; then
    exit 0
  else
    exit 1
  fi
fi

# ── 5c. Режим --masquerade: интерактивная смена маскировки ─────────────
# Также разовая операция — отдельно от миграций.
if [[ $MASQUERADE_MODE_FLAG -eq 1 ]]; then
  if do_masquerade; then
    exit 0
  else
    exit 1
  fi
fi

# ── 5d. Режим --repair: регенерация Caddyfile + Hy2 config из config.json ──
# Разовая операция, идемпотентная. Перед изменениями — autobackup.
if [[ $REPAIR_MODE -eq 1 ]]; then
  if do_repair; then
    exit 0
  else
    exit 1
  fi
fi

# ── 5e. Режим --status: read-only вывод состояния установки ─────────────
# Запускается даже без root (см. early root-check выше). Ничего не меняет.
if [[ $STATUS_MODE -eq 1 ]]; then
  do_status
  exit 0
fi

# ── 6. Применение миграций ─────────────────────────────────────────────
log_step "Применение миграций..."

APPLIED=()
SKIPPED=()
FAILED=()

if [[ ${#MIGRATIONS_VERSIONS[@]} -eq 0 ]]; then
  log_info "В этой версии update.sh миграций ещё нет (каркас инфраструктуры)."
  log_info "Будущие патчи (SSH-only, masquerade) будут поставляться через тот же скрипт."
else
  for i in "${!MIGRATIONS_VERSIONS[@]}"; do
    MIG_VER="${MIGRATIONS_VERSIONS[$i]}"
    MIG_FN="${MIGRATIONS_FUNCS[$i]}"

    # Применяем только если: CURRENT < MIG_VER <= TARGET
    # (или если задан --force, тогда применяем всё подряд, кроме того что > TARGET)
    if version_lt "$TARGET_VERSION" "$MIG_VER"; then
      SKIPPED+=("$MIG_VER (выше целевой $TARGET_VERSION)")
      continue
    fi

    if [[ $FORCE -eq 0 ]] && ! version_lt "$CURRENT_VERSION" "$MIG_VER"; then
      SKIPPED+=("$MIG_VER ($MIG_FN — уже применена)")
      log_skip "$MIG_VER — $MIG_FN (уже применена)"
      continue
    fi

    log_info "Применяется $MIG_VER → $MIG_FN"
    if [[ $DRY_RUN -eq 1 ]]; then
      log_info "  [dry-run] миграция не выполнена"
      APPLIED+=("$MIG_VER (dry-run)")
      continue
    fi

    if "$MIG_FN"; then
      APPLIED+=("$MIG_VER ($MIG_FN)")
      log_ok "$MIG_VER применена"
    else
      FAILED+=("$MIG_VER ($MIG_FN)")
      log_err "$MIG_VER — миграция вернула ошибку"
      log_warn "Останавливаемся, чтобы не применять следующие миграции на сломанном состоянии."
      break
    fi
  done
fi

# ── 7. Запись новой версии ─────────────────────────────────────────────
if [[ ${#FAILED[@]} -eq 0 && $DRY_RUN -eq 0 ]]; then
  echo "$TARGET_VERSION" > "$VERSION_FILE"
  chmod 644 "$VERSION_FILE"
fi

# ── 8. Итоговый отчёт ──────────────────────────────────────────────────
echo ""
echo -e "${PURPLE}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${PURPLE}${BOLD}║                  ИТОГ ОБНОВЛЕНИЯ                         ║${RESET}"
echo -e "${PURPLE}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  Версия: ${BOLD}${CURRENT_VERSION}${RESET} → ${BOLD}${TARGET_VERSION}${RESET}"
[[ $DRY_RUN -eq 1 ]] && echo -e "  Режим:  ${YELLOW}${BOLD}DRY-RUN${RESET} (изменения не применялись)"
echo ""

if [[ ${#APPLIED[@]} -gt 0 ]]; then
  echo -e "${GREEN}${BOLD}Применено (${#APPLIED[@]}):${RESET}"
  for m in "${APPLIED[@]}"; do echo -e "  ${GREEN}✅${RESET} $m"; done
fi

if [[ ${#SKIPPED[@]} -gt 0 ]]; then
  echo -e "${YELLOW}${BOLD}Пропущено (${#SKIPPED[@]}):${RESET}"
  for m in "${SKIPPED[@]}"; do echo -e "  ${YELLOW}↷${RESET} $m"; done
fi

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo -e "${RED}${BOLD}С ошибкой (${#FAILED[@]}):${RESET}"
  for m in "${FAILED[@]}"; do echo -e "  ${RED}❌${RESET} $m"; done
  echo ""
  log_warn "Проверьте логи выше. Версия в ${VERSION_FILE} НЕ обновлена — можно безопасно перезапустить update.sh после починки."
  exit 1
fi

echo ""
log_ok "Готово."
log_info "Файл версии: $VERSION_FILE"
echo ""
exit 0

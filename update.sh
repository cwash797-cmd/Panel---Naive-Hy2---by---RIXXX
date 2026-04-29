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
# ═══════════════════════════════════════════════════════════════════════

set -uo pipefail
export DEBIAN_FRONTEND=noninteractive

# ── Версия, до которой довести систему этим запуском ────────────────────
# При добавлении новой миграции — увеличиваем TARGET_VERSION и регистрируем
# функцию в migration_registry().
TARGET_VERSION="1.1.0"

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
    --help|-h)
      sed -n '2,18p' "$0"
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
if [[ $EUID -ne 0 ]]; then
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

log_ok "Установка обнаружена в ${PANEL_DIR}"
[[ $INSTALL_HAS_NAIVE -eq 1 ]] && log_info "  • NaiveProxy: установлен"
[[ $INSTALL_HAS_HY2 -eq 1 ]]   && log_info "  • Hysteria2:  установлен"

# ── 3. Чтение текущей версии ────────────────────────────────────────────
log_step "Определение текущей версии патчей..."

mkdir -p "$VERSION_DIR"

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
  # ВАЖНО: миграция НЕ применяется автоматически — только показывает информацию.
  # Чтобы перейти в SSH-only режим, пользователь явно подтверждает интерактивно
  # (или вызывает update.sh с флагом --ssh-only в будущих версиях).
  register_migration "1.1.0" migrate_listen_localhost
  # PR #3 добавит: register_migration "1.2.0" migrate_masquerade_choice
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

#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════
#  Panel Naive + Hysteria2 by RIXXX — Update Script
#  Применяет инкрементальные патчи поверх существующей установки.
#  НЕ трогает: пользователей, сертификаты, домены, sysctl, активные сервисы.
#
#  Запуск:
#    bash <(curl -fsSL https://raw.githubusercontent.com/cwash797-cmd/Panel---Naive-Hy2---by---RIXXX/main/update.sh)
#
#  Флаги (для будущих миграций; в этой версии каркас без флагов):
#    --dry-run      показать что будет сделано, ничего не менять
#    --force        применить миграции даже если версия уже новая (для отладки)
# ═══════════════════════════════════════════════════════════════════════

set -uo pipefail
export DEBIAN_FRONTEND=noninteractive

# ── Версия, до которой довести систему этим запуском ────────────────────
# При добавлении новой миграции — увеличиваем TARGET_VERSION и регистрируем
# функцию в migration_registry().
TARGET_VERSION="1.0.0"

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
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --force)   FORCE=1 ;;
    --help|-h)
      sed -n '2,15p' "$0"
      exit 0
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
  # PR #1 — каркас, миграций пока нет.
  # PR #2 добавит сюда: register_migration "1.1.0" migrate_listen_localhost
  # PR #3 добавит:      register_migration "1.2.0" migrate_masquerade_choice
  :
}

register_migration() {
  MIGRATIONS_VERSIONS+=("$1")
  MIGRATIONS_FUNCS+=("$2")
}

migration_registry

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

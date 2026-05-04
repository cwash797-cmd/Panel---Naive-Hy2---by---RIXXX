#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════
#  Panel Naive + Hysteria2 by RIXXX — Деинсталлятор
#  Полностью удаляет панель, Caddy, Hysteria2, Go, nginx (если ставился)
#  и все связанные конфиги, сертификаты, systemd-юниты, UFW-правила.
#
#  Запуск:
#    bash <(curl -fsSL https://raw.githubusercontent.com/cwash797-cmd/Panel---Naive-Hy2---by---RIXXX/main/uninstall.sh)
#
#  Флаги:
#    --yes / -y         не спрашивать подтверждение (для автоматизации)
#    --keep-nginx       не удалять пакет nginx (только конфиг панели)
#    --keep-go          не удалять Go и кэш сборки (если используется другими)
#    --dry-run          показать что будет удалено, не выполнять реальные действия
#    --help / -h        эта справка
#
#  Что НЕ удаляется (намеренно):
#    • Node.js — может использоваться другими приложениями
#    • PM2 (npm-пакет) — может управлять другими процессами
#    • UFW (пакет) — базовый фаервол системы
#    • Базовые пакеты: curl, wget, git, jq, openssl, ca-certificates
# ═══════════════════════════════════════════════════════════════════════

set -uo pipefail

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

# ── Парсинг флагов ──────────────────────────────────────────────────────
ASSUME_YES=0
KEEP_NGINX=0
KEEP_GO=0
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y)     ASSUME_YES=1; shift ;;
    --keep-nginx) KEEP_NGINX=1; shift ;;
    --keep-go)    KEEP_GO=1; shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    --help|-h)    sed -n '2,22p' "$0"; exit 0 ;;
    *) echo -e "${RED}❌ Неизвестный флаг: $1${RESET}" >&2; exit 1 ;;
  esac
done

# ── Хелперы для dry-run ────────────────────────────────────────────────
# do_run "<описание>" cmd args...  — выполняет команду, или печатает её при --dry-run.
do_run() {
  local desc="$1"; shift
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] $desc"
    return 0
  fi
  "$@" 2>/dev/null || true
}

# ── Заголовок ───────────────────────────────────────────────────────────
clear 2>/dev/null || true
echo ""
echo -e "${RED}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${RED}${BOLD}║   Panel Naive + Hy2 by RIXXX — Деинсталлятор             ║${RESET}"
echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
echo ""

# ── Root check ──────────────────────────────────────────────────────────
if [[ $EUID -ne 0 && $DRY_RUN -eq 0 ]]; then
  log_err "Запускайте от root: sudo bash uninstall.sh"
  exit 1
fi

# ── Что будет удалено — показываем ДО подтверждения ────────────────────
echo -e "${RED}${BOLD}⚠  ВНИМАНИЕ: Это действие необратимо!${RESET}"
echo ""
echo -e "${BOLD}Будут удалены:${RESET}"
echo -e "  • Панель управления и все её данные:   ${BOLD}/opt/panel-naive-hy2${RESET}"
echo -e "  • Caddy + NaiveProxy:                   ${BOLD}/usr/bin/caddy${RESET}, ${BOLD}/etc/caddy${RESET}"
echo -e "  • Hysteria2:                            ${BOLD}/usr/local/bin/hysteria${RESET}, ${BOLD}/etc/hysteria${RESET}"
echo -e "  • Сертификаты Let's Encrypt / ZeroSSL:  ${BOLD}/var/lib/caddy${RESET}, ${BOLD}/root/.local/share/caddy${RESET}"
echo -e "  • Юниты systemd:                        caddy, hysteria-server, panel-naive-hy2,"
echo -e "                                          caddy-cert-watcher.path/.service, pm2-root"
if [[ $KEEP_NGINX -eq 0 ]]; then
echo -e "  • Nginx (если был установлен):          пакет + ${BOLD}/etc/nginx/sites-*/panel-naive-hy2${RESET}"
else
echo -e "  ${YELLOW}• Nginx — пропущен (--keep-nginx), удалю только конфиг панели${RESET}"
fi
if [[ $KEEP_GO -eq 0 ]]; then
echo -e "  • Go и кэш сборки:                      ${BOLD}/usr/local/go${RESET}, ${BOLD}/root/go${RESET}, ${BOLD}/root/.cache/go-build${RESET}"
else
echo -e "  ${YELLOW}• Go — пропущен (--keep-go)${RESET}"
fi
echo -e "  • UFW-правила:                          allow/deny 80/443/8080/3000"
echo -e "  • Сетевой тюнинг:                       ${BOLD}/etc/sysctl.d/99-rixxx-tune.conf${RESET}"
echo -e "  • Версия патчей и автобэкапы:           ${BOLD}/etc/rixxx-panel${RESET}"
echo -e "  • Камуфляжная страница:                 ${BOLD}/var/www/html/index.html${RESET} (если RIXXX-овая)"
echo ""
echo -e "${GREEN}${BOLD}НЕ удаляется (используется системой/другими):${RESET}"
echo -e "  ${GREEN}• Node.js, PM2 (npm-пакет), UFW (пакет)${RESET}"
echo -e "  ${GREEN}• curl, wget, git, openssl, ca-certificates${RESET}"
echo ""

if [[ $DRY_RUN -eq 1 ]]; then
  log_info "${BOLD}РЕЖИМ DRY-RUN — никакие файлы не будут изменены.${RESET}"
  echo ""
fi

# ── Подтверждение ───────────────────────────────────────────────────────
if [[ $ASSUME_YES -ne 1 && $DRY_RUN -eq 0 ]]; then
  if [[ ! -t 0 ]]; then
    log_err "Нет TTY (запуск через pipe). Используйте: bash uninstall.sh --yes"
    exit 1
  fi
  read -rp "Введите 'yes' для подтверждения удаления: " _CONFIRM
  if [[ "$_CONFIRM" != "yes" ]]; then
    log_ok "Отменено пользователем."
    exit 0
  fi
fi

# Счётчик ошибок: при дефолтных параметрах ничего не должно падать,
# но если ufw/systemctl отсутствуют — логируем и продолжаем.
ERR_COUNT=0
err_inc() { ERR_COUNT=$((ERR_COUNT + 1)); }

echo ""

# ── 1. PM2 — остановка панели + удаление startup-юнита ────────────────
log_step "1. Остановка PM2-процессов панели..."
if command -v pm2 >/dev/null 2>&1; then
  do_run "pm2 delete panel-naive-hy2"  pm2 delete panel-naive-hy2
  do_run "pm2 save --force"             pm2 save --force
  # PM2 startup-юнит создаётся install.sh через `pm2 startup systemd`.
  # Без его удаления systemd при ребуте будет пытаться поднять PM2,
  # хотя управлять уже нечем.
  if [[ -f /etc/systemd/system/pm2-root.service ]]; then
    do_run "systemctl stop/disable pm2-root.service"  bash -c "systemctl stop pm2-root.service; systemctl disable pm2-root.service"
    do_run "rm /etc/systemd/system/pm2-root.service"  rm -f /etc/systemd/system/pm2-root.service
    log_ok "PM2 startup-юнит удалён"
  else
    log_skip "pm2-root.service отсутствует — пропускаю"
  fi
  log_ok "PM2-процесс панели удалён"
else
  log_skip "PM2 не установлен — пропускаю"
fi

# ── 2. Systemd сервисы (caddy, hysteria-server, panel-naive-hy2, watcher) ──
log_step "2. Остановка и удаление systemd-сервисов..."
# Полный список юнитов которые создаёт install.sh:
#   • caddy.service              — основной Caddy
#   • hysteria-server.service    — Hysteria2
#   • panel-naive-hy2.service    — fallback systemd-юнит панели (когда PM2 не запустил)
#   • caddy-cert-watcher.path    — отслеживает обновление TLS-сертификата для Hy2
#   • caddy-cert-watcher.service — перезапускает hysteria-server при ротации
SVC_LIST=(
  "caddy"
  "hysteria-server"
  "panel-naive-hy2"
  "caddy-cert-watcher.path"
  "caddy-cert-watcher.service"
)
for svc in "${SVC_LIST[@]}"; do
  if [[ -f "/etc/systemd/system/${svc}" ]] || [[ -f "/etc/systemd/system/${svc}.service" ]] \
     || systemctl list-unit-files 2>/dev/null | grep -q "^${svc}"; then
    do_run "systemctl stop ${svc}"     systemctl stop "${svc}"
    do_run "systemctl disable ${svc}"  systemctl disable "${svc}"
    do_run "rm /etc/systemd/system/${svc}"          rm -f "/etc/systemd/system/${svc}"
    do_run "rm /etc/systemd/system/${svc}.service"  rm -f "/etc/systemd/system/${svc}.service"
    log_info "  ${svc} — остановлен и удалён"
  else
    log_skip "  ${svc} — не установлен"
  fi
done
do_run "systemctl daemon-reload"  systemctl daemon-reload
do_run "systemctl reset-failed"   systemctl reset-failed
log_ok "Systemd-сервисы удалены, daemon-reload выполнен"

# ── 3. Nginx (опционально) ──────────────────────────────────────────────
log_step "3. Удаление конфига Nginx и пакета (если был установлен)..."
# Конфиг панели install.sh кладёт в sites-available + симлинк в sites-enabled.
# Удаляем их в любом случае (даже с --keep-nginx), чтобы не мусорил.
do_run "rm /etc/nginx/sites-available/panel-naive-hy2"  rm -f /etc/nginx/sites-available/panel-naive-hy2
do_run "rm /etc/nginx/sites-enabled/panel-naive-hy2"    rm -f /etc/nginx/sites-enabled/panel-naive-hy2

if [[ $KEEP_NGINX -eq 1 ]]; then
  log_skip "Пакет nginx сохранён (--keep-nginx). Удалён только конфиг панели."
  # Если nginx остаётся — перезапускаем без нашего конфига.
  if systemctl is-active --quiet nginx 2>/dev/null; then
    do_run "systemctl reload nginx"  systemctl reload nginx
  fi
else
  if dpkg -l 2>/dev/null | grep -qE "^ii\s+nginx" || command -v nginx >/dev/null 2>&1; then
    # Останавливаем перед удалением — иначе apt может ругаться.
    do_run "systemctl stop nginx"     systemctl stop nginx
    do_run "systemctl disable nginx"  systemctl disable nginx
    do_run "apt-get purge -y nginx*"  bash -c "DEBIAN_FRONTEND=noninteractive apt-get purge -y 'nginx*' >/dev/null 2>&1"
    do_run "apt-get autoremove -y"    bash -c "DEBIAN_FRONTEND=noninteractive apt-get autoremove -y >/dev/null 2>&1"
    log_ok "Nginx удалён (purge + autoremove)"
  else
    log_skip "Nginx не установлен — пропускаю"
  fi
fi

# ── 4. Бинарники Caddy и Hysteria2 ─────────────────────────────────────
log_step "4. Удаление бинарников Caddy и Hysteria2..."
do_run "rm /usr/bin/caddy"             rm -f /usr/bin/caddy
do_run "rm /usr/local/bin/hysteria"    rm -f /usr/local/bin/hysteria
# На случай если кто-то поставил руками в /usr/local/bin/caddy:
do_run "rm /usr/local/bin/caddy"       rm -f /usr/local/bin/caddy
log_ok "Бинарники удалены"

# ── 5. Конфиги Caddy и Hysteria2 + камуфляжная страница ───────────────
log_step "5. Удаление конфигов..."
do_run "rm -rf /etc/caddy"     rm -rf /etc/caddy
do_run "rm -rf /etc/hysteria"  rm -rf /etc/hysteria

# Камуфляжная страница: удаляем только если это наша.
# Если /var/www/html/index.html модифицирован пользователем — не трогаем папку.
if [[ -f /var/www/html/index.html ]] && grep -q "Loading" /var/www/html/index.html 2>/dev/null \
   && [[ $(wc -l < /var/www/html/index.html 2>/dev/null || echo 0) -lt 50 ]]; then
  do_run "rm /var/www/html/index.html (камуфляж RIXXX)"  rm -f /var/www/html/index.html
  log_info "  Камуфляжная страница RIXXX удалена"
else
  log_skip "  /var/www/html/index.html не наша или модифицирована — не трогаю"
fi
log_ok "Конфиги удалены"

# ── 6. Сертификаты Caddy ────────────────────────────────────────────────
log_step "6. Удаление сертификатов Caddy..."
# Caddy хранит сертификаты в двух возможных местах (зависит от версии):
#   • /var/lib/caddy/.local/share/caddy/  — современная (с user=caddy)
#   • /root/.local/share/caddy/           — legacy (когда запускался от root)
#   • /root/.config/caddy/                — конфиги acme
do_run "rm -rf /var/lib/caddy"           rm -rf /var/lib/caddy
do_run "rm -rf /root/.local/share/caddy" rm -rf /root/.local/share/caddy
do_run "rm -rf /root/.config/caddy"      rm -rf /root/.config/caddy
log_ok "Сертификаты Let's Encrypt / ZeroSSL удалены"

# ── 7. Папка панели ─────────────────────────────────────────────────────
log_step "7. Удаление панели управления..."
# Перед rm -rf проверяем что нет процессов которые держат файлы (PM2 уже убит,
# но на всякий случай).
if command -v lsof >/dev/null 2>&1; then
  PIDS_HOLDING=$(lsof +D /opt/panel-naive-hy2 2>/dev/null | awk 'NR>1 {print $2}' | sort -u | head -10)
  if [[ -n "$PIDS_HOLDING" ]]; then
    log_warn "Процессы держат файлы в /opt/panel-naive-hy2: $PIDS_HOLDING — убиваю"
    for pid in $PIDS_HOLDING; do do_run "kill $pid" kill -TERM "$pid"; done
    sleep 1
  fi
fi
do_run "rm -rf /opt/panel-naive-hy2"  rm -rf /opt/panel-naive-hy2
log_ok "Панель удалена"

# ── 8. Версия патчей и автобэкапы ──────────────────────────────────────
log_step "8. Удаление /etc/rixxx-panel (версия + автобэкапы)..."
do_run "rm -rf /etc/rixxx-panel"  rm -rf /etc/rixxx-panel
log_ok "Версия и автобэкапы удалены"

# ── 9. Go и кэш сборки (опционально) ───────────────────────────────────
log_step "9. Удаление Go и кэша сборки..."
if [[ $KEEP_GO -eq 1 ]]; then
  log_skip "Go сохранён (--keep-go)"
else
  do_run "rm -rf /usr/local/go"          rm -rf /usr/local/go
  do_run "rm -rf /root/go"               rm -rf /root/go
  do_run "rm -rf /root/.cache/go-build"  rm -rf /root/.cache/go-build
  do_run "rm -rf /root/tmp"              rm -rf /root/tmp
  # Убираем GOROOT/GOPATH/PATH-добавки из /root/.profile (install.sh их добавляет).
  if [[ -f /root/.profile ]] && [[ $DRY_RUN -eq 0 ]]; then
    sed -i '/GOROOT\|GOPATH\|\/usr\/local\/go\/bin/d' /root/.profile 2>/dev/null || true
  elif [[ -f /root/.profile ]]; then
    log_info "[dry-run] sed -i ... /root/.profile (убрать GOROOT/GOPATH)"
  fi
  log_ok "Go и кэш удалены, /root/.profile очищен"
fi

# ── 10. UFW-правила ─────────────────────────────────────────────────────
log_step "10. Очистка UFW-правил для портов панели/прокси..."
if command -v ufw >/dev/null 2>&1; then
  # Удаляем все правила которые создаёт install.sh + миграции PR #7/9.
  # `ufw delete` идемпотентен (no-op если правила нет), так что безопасно
  # вызывать для всех вариантов.
  for proto_port in "443/tcp" "443/udp" "80/tcp" "8080/tcp" "3000/tcp"; do
    do_run "ufw delete allow ${proto_port}"  ufw delete allow "${proto_port}"
    do_run "ufw delete deny  ${proto_port}"  ufw delete deny  "${proto_port}"
  done
  do_run "ufw reload"  ufw reload
  log_ok "UFW-правила для 80/443/8080/3000 удалены (22/SSH сохранён)"
else
  log_skip "UFW не установлен — пропускаю"
fi

# ── 11. sysctl тюнинг ───────────────────────────────────────────────────
log_step "11. Удаление sysctl-настроек RIXXX..."
do_run "rm /etc/sysctl.d/99-rixxx-tune.conf"  rm -f /etc/sysctl.d/99-rixxx-tune.conf
do_run "sysctl --system (применить откат)"     bash -c "sysctl --system >/dev/null 2>&1"
log_ok "Sysctl-настройки RIXXX удалены"

# ── 12. Финальная проверка остатков ────────────────────────────────────
log_step "12. Проверка что ничего не осталось..."
LEFTOVERS=()
for path in \
  "/opt/panel-naive-hy2" \
  "/etc/caddy" \
  "/etc/hysteria" \
  "/etc/rixxx-panel" \
  "/usr/bin/caddy" \
  "/usr/local/bin/hysteria" \
  "/etc/systemd/system/caddy.service" \
  "/etc/systemd/system/hysteria-server.service" \
  "/etc/systemd/system/panel-naive-hy2.service" \
  "/etc/systemd/system/caddy-cert-watcher.path" \
  "/etc/systemd/system/caddy-cert-watcher.service" \
  "/etc/sysctl.d/99-rixxx-tune.conf"; do
  if [[ -e "$path" ]]; then
    LEFTOVERS+=("$path")
  fi
done

if [[ ${#LEFTOVERS[@]} -eq 0 ]]; then
  log_ok "Все ключевые пути очищены ✓"
else
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] Эти пути были бы удалены: ${#LEFTOVERS[@]}"
    for p in "${LEFTOVERS[@]}"; do log_info "    • $p"; done
  else
    log_warn "Остались следующие пути (${#LEFTOVERS[@]} шт.) — проверьте вручную:"
    for p in "${LEFTOVERS[@]}"; do log_warn "    • $p"; done
  fi
fi

# Проверка занятых портов — после удаления ни 443 ни 8080 ни 3000 не должны слушать
# (если что-то слушает — значит другой процесс, не наш).
if command -v ss >/dev/null 2>&1; then
  for port in 443 8080 3000; do
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
      log_warn "  Порт ${port} ВСЁ ЕЩЁ слушается (вероятно сторонним процессом — проверьте: ss -tlnp | grep :${port})"
    fi
  done
fi

# ── Финал ───────────────────────────────────────────────────────────────
echo ""
if [[ $DRY_RUN -eq 1 ]]; then
  echo -e "${BLUE}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${BLUE}${BOLD}║   🔍 DRY-RUN завершён — никакие файлы не изменены       ║${RESET}"
  echo -e "${BLUE}${BOLD}║   Запустите без --dry-run для реального удаления.       ║${RESET}"
  echo -e "${BLUE}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
else
  echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${GREEN}${BOLD}║   ✅ Деинсталляция завершена!                            ║${RESET}"
  echo -e "${GREEN}${BOLD}║                                                          ║${RESET}"
  echo -e "${GREEN}${BOLD}║   Сервер чистый. Для переустановки:                      ║${RESET}"
  echo -e "${GREEN}${BOLD}║     bash <(curl -fsSL <REPO_URL>/main/install.sh)        ║${RESET}"
  echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
fi
echo ""

exit 0

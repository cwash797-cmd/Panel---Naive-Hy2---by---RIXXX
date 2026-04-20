#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════
#  Panel Naive + Hysteria2 by RIXXX — Полный установщик
#  Устанавливает: панель управления + NaiveProxy (Caddy) + Hysteria2
#  Запуск:
#    bash <(curl -fsSL https://raw.githubusercontent.com/cwash797-cmd/Panel---Naive-Hy2---by---RIXXX/main/install.sh)
#  Требования: Ubuntu 22.04 / 24.04 / Debian 11+ / root / amd64|arm64|armv7
# ═══════════════════════════════════════════════════════════════════════

set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

REPO_URL="https://github.com/cwash797-cmd/Panel---Naive-Hy2---by---RIXXX"
REPO_BRANCH="${REPO_BRANCH:-main}"
PANEL_DIR="/opt/panel-naive-hy2"
SERVICE_NAME="panel-naive-hy2"
INTERNAL_PORT=3000

# ── Colors ──────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; PURPLE='\033[0;35m'; CYAN='\033[0;36m'
BOLD='\033[1m'; RESET='\033[0m'

header() {
  clear
  echo ""
  echo -e "${PURPLE}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${PURPLE}${BOLD}║   Panel Naive + Hysteria2 by RIXXX — Установщик          ║${RESET}"
  echo -e "${PURPLE}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
  echo ""
}

log_step() { echo -e "\n${CYAN}${BOLD}▶ $1${RESET}"; }
log_ok()   { echo -e "${GREEN}✅ $1${RESET}"; }
log_warn() { echo -e "${YELLOW}⚠  $1${RESET}"; }
log_err()  { echo -e "${RED}❌ $1${RESET}"; }
log_info() { echo -e "   ${BLUE}$1${RESET}"; }

header

# ── Root check ──────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  log_err "Запускайте скрипт от root: sudo bash install.sh"
  exit 1
fi

# ── OS check ────────────────────────────────────────────────────────────
if ! command -v apt-get &>/dev/null; then
  log_err "Поддерживается только Ubuntu/Debian"
  exit 1
fi

# ── Arch detection ──────────────────────────────────────────────────────
MACHINE_ARCH="$(uname -m)"
case "$MACHINE_ARCH" in
  x86_64)  GO_ARCH="amd64";  HY_ARCH="amd64"  ;;
  aarch64) GO_ARCH="arm64";  HY_ARCH="arm64"  ;;
  armv7l)  GO_ARCH="armv6l"; HY_ARCH="arm"    ;;
  *)       log_warn "Неизвестная архитектура ${MACHINE_ARCH}, используем amd64"
           GO_ARCH="amd64";  HY_ARCH="amd64"  ;;
esac
log_info "Архитектура: ${MACHINE_ARCH} → Go:${GO_ARCH} Hy2:${HY_ARCH}"

# ── IP detection ────────────────────────────────────────────────────────
SERVER_IP=$(curl -4 -s --connect-timeout 8 ifconfig.me 2>/dev/null \
  || curl -4 -s --connect-timeout 8 icanhazip.com 2>/dev/null \
  || hostname -I | awk '{print $1}')

echo -e "   ${BLUE}IP сервера: ${BOLD}${SERVER_IP}${RESET}"
echo ""

# ════════════════════════════════════════════════════════════════════════
# РАЗДЕЛ А — ИНТЕРАКТИВНЫЕ НАСТРОЙКИ
# ════════════════════════════════════════════════════════════════════════

# ── A1. Выбор стека ─────────────────────────────────────────────────────
echo -e "${BOLD}Какие протоколы установить?${RESET}"
echo ""
echo -e "  ${CYAN}1)${RESET} ${BOLD}NaiveProxy${RESET} (TCP/443, маскировка под HTTPS)"
echo -e "  ${CYAN}2)${RESET} ${BOLD}Hysteria2${RESET}  (UDP/443, QUIC, максимальная скорость)"
echo -e "  ${CYAN}3)${RESET} ${BOLD}Оба сразу${RESET}    ${GREEN}(рекомендуется — один домен, один сертификат)${RESET}"
echo ""
read -rp "Ваш выбор [1/2/3]: " STACK_MODE
STACK_MODE="${STACK_MODE:-3}"

case "$STACK_MODE" in
  1) INSTALL_NAIVE=1; INSTALL_HY2=0 ;;
  2) INSTALL_NAIVE=0; INSTALL_HY2=1 ;;
  *) INSTALL_NAIVE=1; INSTALL_HY2=1 ;;
esac

# ── A2. Способ доступа к панели ─────────────────────────────────────────
echo ""
echo -e "${BOLD}Способ доступа к панели управления:${RESET}"
echo ""
echo -e "  ${CYAN}1)${RESET} Через Nginx на порту ${BOLD}8080${RESET} ${GREEN}(рекомендуется — порт 3000 не светится)${RESET}"
echo -e "  ${CYAN}2)${RESET} Напрямую на порту ${BOLD}3000${RESET} (проще, но порт виден)"
echo -e "  ${CYAN}3)${RESET} Через Nginx с доменом + HTTPS (максимальная защита)"
echo ""
read -rp "Ваш выбор [1/2/3]: " ACCESS_MODE
ACCESS_MODE="${ACCESS_MODE:-1}"

PANEL_DOMAIN=""
PANEL_EMAIL_SSL=""
if [[ "$ACCESS_MODE" == "3" ]]; then
  echo ""
  read -rp "  Домен для панели (например panel.yourdomain.com): " PANEL_DOMAIN
  read -rp "  Email для Let's Encrypt (SSL панели): " PANEL_EMAIL_SSL
fi

# ── A3. Параметры прокси ────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Параметры прокси:${RESET}"
echo -e "${YELLOW}  ⚠  Убедитесь что A-запись домена указывает на ${SERVER_IP}${RESET}"
echo ""
read -rp "  Домен (например vpn.yourdomain.com): " PROXY_DOMAIN
read -rp "  Email для Let's Encrypt (TLS): " PROXY_EMAIL

# Генерируем credentials
NAIVE_LOGIN=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 16)
NAIVE_PASS=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 24)
HY2_PASS=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 24)

echo ""
echo -e "${GREEN}  ✅ Сгенерированы креды:${RESET}"
[[ $INSTALL_NAIVE -eq 1 ]] && {
  log_info "NaiveProxy → ${NAIVE_LOGIN} : ${NAIVE_PASS}"
}
[[ $INSTALL_HY2 -eq 1 ]] && {
  log_info "Hysteria2  → password: ${HY2_PASS}"
}
echo ""
echo -e "${YELLOW}  ⚠  Запомните эти данные! Они также будут показаны в конце.${RESET}"
echo ""
read -rp "Всё верно? Начать установку? [Enter / Ctrl+C для отмены]: " _CONFIRM

echo ""

# ════════════════════════════════════════════════════════════════════════
# РАЗДЕЛ Б — УСТАНОВКА
# ════════════════════════════════════════════════════════════════════════

TOTAL_STEPS=14
[[ $INSTALL_HY2 -eq 1 ]] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
STEP_NUM=0
next_step() { STEP_NUM=$((STEP_NUM + 1)); log_step "[${STEP_NUM}/${TOTAL_STEPS}] $1"; }

# ── Б1. Фикс apt-locks + обновление ─────────────────────────────────────
next_step "Подготовка системы (фикс apt-lock, needrestart)..."

systemctl stop unattended-upgrades 2>/dev/null || true
systemctl disable unattended-upgrades 2>/dev/null || true
pkill -9 unattended-upgrades 2>/dev/null || true
sleep 1

rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock \
      /var/cache/apt/archives/lock /var/lib/apt/lists/lock 2>/dev/null || true
dpkg --configure -a >/dev/null 2>&1 || true

if [ -f /etc/needrestart/needrestart.conf ]; then
  sed -i "s/#\$nrconf{restart} = 'i';/\$nrconf{restart} = 'a';/" \
    /etc/needrestart/needrestart.conf 2>/dev/null || true
  sed -i "s/\$nrconf{restart} = 'i';/\$nrconf{restart} = 'a';/" \
    /etc/needrestart/needrestart.conf 2>/dev/null || true
  log_info "needrestart → авто-режим"
fi

apt-get update -qq -o DPkg::Lock::Timeout=60 2>/dev/null || true
apt-get install -y -qq \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold" \
  -o DPkg::Lock::Timeout=60 \
  curl wget git openssl ufw ca-certificates jq 2>/dev/null || true

log_ok "Система подготовлена"

# ── Б2. BBR + UDP-буферы ────────────────────────────────────────────────
next_step "Включение BBR и UDP-оптимизации..."

cat > /etc/sysctl.d/99-rixxx-tune.conf << 'SYSCTLEOF'
# by RIXXX — сетевой тюнинг для Naive (TCP) + Hy2 (UDP)
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
# UDP буферы для Hysteria2 (рекомендация apernet)
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.rmem_default=2500000
net.core.wmem_default=2500000
# FastOpen + ipv6
net.ipv4.tcp_fastopen=3
net.ipv6.conf.all.disable_ipv6=0
SYSCTLEOF

sysctl --system >/dev/null 2>&1 || true
log_ok "BBR + UDP оптимизации применены"

# ── Б3. Установка Go (multi-arch) ───────────────────────────────────────
if [[ $INSTALL_NAIVE -eq 1 ]]; then
  next_step "Установка Go (arch: ${GO_ARCH})..."

  rm -rf /usr/local/go

  GO_VERSION=""
  for attempt in 1 2 3; do
    GO_VERSION=$(curl -fsSL --connect-timeout 10 'https://go.dev/VERSION?m=text' 2>/dev/null | head -n1 | tr -d '[:space:]' || true)
    [[ -n "$GO_VERSION" && "$GO_VERSION" == go* ]] && break
    sleep 2
  done
  [[ -z "$GO_VERSION" || "$GO_VERSION" != go* ]] && GO_VERSION="go1.22.5"

  log_info "Загружаем ${GO_VERSION}.linux-${GO_ARCH}..."
  wget -q --show-progress --timeout=180 \
    "https://go.dev/dl/${GO_VERSION}.linux-${GO_ARCH}.tar.gz" \
    -O /tmp/go.tar.gz 2>&1 || {
      log_err "Не удалось загрузить Go!"
      exit 1
    }

  if [[ ! -s /tmp/go.tar.gz ]]; then
    log_err "Файл Go пустой, проверьте интернет"
    exit 1
  fi

  tar -C /usr/local -xzf /tmp/go.tar.gz
  rm -f /tmp/go.tar.gz

  export GOROOT=/usr/local/go
  export GOPATH=/root/go
  export PATH=$GOROOT/bin:$GOPATH/bin:$PATH

  grep -q "/usr/local/go/bin" /root/.profile 2>/dev/null || {
    echo 'export GOROOT=/usr/local/go' >> /root/.profile
    echo 'export GOPATH=/root/go' >> /root/.profile
    echo 'export PATH=$GOROOT/bin:$GOPATH/bin:$PATH' >> /root/.profile
  }

  GO_VER=$(/usr/local/go/bin/go version 2>/dev/null || echo "неизвестно")
  log_ok "Go установлен: ${GO_VER}"

  # ── Б4. Сборка Caddy с naive-плагином ────────────────────────────────
  next_step "Сборка Caddy + naive forward proxy (3-7 минут)..."

  export GOROOT=/usr/local/go
  export GOPATH=/root/go
  export PATH=$GOROOT/bin:$GOPATH/bin:$PATH
  export TMPDIR=/root/tmp
  export GOPROXY=https://proxy.golang.org,direct
  mkdir -p /root/tmp /root/go

  log_info "Установка xcaddy..."
  /usr/local/go/bin/go install \
    github.com/caddyserver/xcaddy/cmd/xcaddy@latest 2>&1 | tail -2

  if [[ ! -f /root/go/bin/xcaddy ]]; then
    log_err "xcaddy не установился! Проверьте интернет."
    exit 1
  fi
  log_info "xcaddy установлен, собираем Caddy..."

  rm -f /root/caddy
  cd /root

  /root/go/bin/xcaddy build \
    --with github.com/caddyserver/forwardproxy@caddy2=github.com/klzgrad/forwardproxy@naive \
    2>&1 | while IFS= read -r line; do
      [[ -n "$line" ]] && echo "    $line"
    done

  if [[ ! -f /root/caddy ]]; then
    log_err "Caddy не собран! Проверьте вывод выше."
    exit 1
  fi

  mv /root/caddy /usr/bin/caddy
  chmod +x /usr/bin/caddy
  setcap 'cap_net_bind_service=+ep' /usr/bin/caddy 2>/dev/null || true

  CADDY_VER=$(/usr/bin/caddy version 2>/dev/null || echo "неизвестно")
  log_ok "Caddy собран: ${CADDY_VER}"

  # ── Б5. Камуфляжная страница + Caddyfile ─────────────────────────────
  next_step "Создание Caddyfile и камуфляжной страницы..."

  mkdir -p /var/www/html /etc/caddy

  cat > /var/www/html/index.html << 'HTMLEOF'
<!DOCTYPE html><html><head><meta charset="utf-8"><title>Loading</title>
<style>body{background:#080808;height:100vh;margin:0;display:flex;flex-direction:column;align-items:center;justify-content:center;font-family:sans-serif}.bar{width:200px;height:3px;background:#151515;overflow:hidden;border-radius:2px;margin-bottom:25px}.fill{height:100%;width:40%;background:#fff;animation:slide 1.4s infinite ease-in-out}@keyframes slide{0%{transform:translateX(-100%)}50%{transform:translateX(50%)}100%{transform:translateX(200%)}}.t{color:#555;font-size:13px;letter-spacing:3px;font-weight:600}</style>
</head><body><div class="bar"><div class="fill"></div></div><div class="t">LOADING CONTENT</div></body></html>
HTMLEOF

  {
    printf '{\n  order forward_proxy before file_server\n}\n\n'
    printf ':443, %s {\n' "${PROXY_DOMAIN}"
    printf '  tls %s\n\n' "${PROXY_EMAIL}"
    printf '  forward_proxy {\n'
    printf '    basic_auth %s %s\n' "${NAIVE_LOGIN}" "${NAIVE_PASS}"
    printf '    hide_ip\n'
    printf '    hide_via\n'
    printf '    probe_resistance\n'
    printf '  }\n\n'
    printf '  file_server {\n'
    printf '    root /var/www/html\n'
    printf '  }\n'
    printf '}\n'
  } > /etc/caddy/Caddyfile

  /usr/bin/caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 \
    && log_ok "Caddyfile валиден" \
    || log_warn "Caddyfile — предупреждение (SSL получим при старте)"

  # ── Б6. Systemd сервис Caddy ─────────────────────────────────────────
  next_step "Systemd сервис Caddy..."

  systemctl stop caddy 2>/dev/null || true
  pkill -x caddy 2>/dev/null || true
  sleep 1

  cat > /etc/systemd/system/caddy.service << 'SVCEOF'
[Unit]
Description=Caddy with NaiveProxy (by RIXXX)
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=root
Group=root
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE
Restart=always
RestartSec=5s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

  systemctl daemon-reload
  systemctl enable caddy >/dev/null 2>&1 || true

  # ── Б7. Запуск Caddy ────────────────────────────────────────────────
  next_step "Запуск Caddy (получение TLS сертификата)..."

  systemctl start caddy 2>&1 || {
    log_warn "systemctl start вернул ошибку, пробуем fallback..."
    pkill -f "caddy run" 2>/dev/null || true
    sleep 1
    nohup /usr/bin/caddy run --config /etc/caddy/Caddyfile \
      > /var/log/caddy.log 2>&1 &
  }

  CADDY_OK=0
  for i in $(seq 1 30); do
    if systemctl is-active --quiet caddy 2>/dev/null || pgrep -x caddy >/dev/null 2>/dev/null; then
      log_ok "Caddy запущен (${i}с)"
      CADDY_OK=1
      break
    fi
    sleep 1
  done

  [[ $CADDY_OK -eq 0 ]] && log_warn "Caddy запускается медленно — проверьте: systemctl status caddy"
fi

# ── Б8. Установка Hysteria2 ─────────────────────────────────────────────
if [[ $INSTALL_HY2 -eq 1 ]]; then
  next_step "Установка Hysteria2 (arch: ${HY_ARCH})..."

  # Получаем последний релиз
  HY_VERSION=$(curl -fsSL --connect-timeout 10 \
    https://api.github.com/repos/apernet/hysteria/releases/latest 2>/dev/null \
    | jq -r '.tag_name' 2>/dev/null || echo "")
  [[ -z "$HY_VERSION" || "$HY_VERSION" == "null" ]] && HY_VERSION="app/v2.5.2"

  log_info "Загружаем Hysteria ${HY_VERSION} (linux-${HY_ARCH})..."
  HY_URL="https://github.com/apernet/hysteria/releases/download/${HY_VERSION}/hysteria-linux-${HY_ARCH}"

  # fallback если jq не получил версию
  wget -q --show-progress --timeout=120 "${HY_URL}" -O /usr/local/bin/hysteria 2>&1 || {
    log_warn "Не удалось скачать ${HY_VERSION}, пробуем fallback app/v2.5.2..."
    wget -q --show-progress --timeout=120 \
      "https://github.com/apernet/hysteria/releases/download/app/v2.5.2/hysteria-linux-${HY_ARCH}" \
      -O /usr/local/bin/hysteria 2>&1 || {
      log_err "Не удалось скачать hysteria!"
      exit 1
    }
  }

  if [[ ! -s /usr/local/bin/hysteria ]]; then
    log_err "hysteria бинарник пустой"
    exit 1
  fi

  chmod +x /usr/local/bin/hysteria
  # Capability чтобы Hy2 мог биндить 443 без root (но запустим от root всё равно)
  setcap 'cap_net_bind_service=+ep' /usr/local/bin/hysteria 2>/dev/null || true

  HY_VER=$(/usr/local/bin/hysteria version 2>&1 | head -n1 || echo "неизвестно")
  log_ok "Hysteria установлена: ${HY_VER}"

  # Конфиг Hy2
  mkdir -p /etc/hysteria

  # Если Caddy установлен — используем его сертификат
  if [[ $INSTALL_NAIVE -eq 1 ]]; then
    HY_TLS_MODE="caddy"
    log_info "Hy2 будет использовать сертификат Caddy (общий домен)"
  else
    HY_TLS_MODE="acme"
    log_info "Hy2 получит собственный ACME-сертификат"
  fi

  cat > /etc/hysteria/config.yaml << HYCFGEOF
# ═══════════════════════════════════════════════
#  Hysteria2 config — by RIXXX
#  https://v2.hysteria.network/
# ═══════════════════════════════════════════════

listen: :443

# Authentication (одиночный пароль по умолчанию; добавляйте пользователей через панель)
auth:
  type: userpass
  userpass:
    default: "${HY2_PASS}"

# Маскировка трафика (выглядит как обычный HTTPS-сайт)
masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true

# TLS
HYCFGEOF

  if [[ "$HY_TLS_MODE" == "caddy" ]]; then
    # Caddy может хранить cert в двух местах — проверяем оба
    CADDY_CERT_BASE_NEW="/var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/${PROXY_DOMAIN}"
    CADDY_CERT_BASE_OLD="/root/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/${PROXY_DOMAIN}"
    CADDY_CERT_DIR=""

    log_info "Ждём сертификат от Caddy (до 90с)..."
    for i in $(seq 1 45); do
      if [[ -f "${CADDY_CERT_BASE_NEW}/${PROXY_DOMAIN}.crt" ]]; then
        CADDY_CERT_DIR="${CADDY_CERT_BASE_NEW}"
        log_ok "Сертификат найден (${i}х2с) — /var/lib/caddy"
        break
      elif [[ -f "${CADDY_CERT_BASE_OLD}/${PROXY_DOMAIN}.crt" ]]; then
        CADDY_CERT_DIR="${CADDY_CERT_BASE_OLD}"
        log_ok "Сертификат найден (${i}х2с) — /root/.local"
        break
      fi
      sleep 2
    done

    if [[ -z "$CADDY_CERT_DIR" ]]; then
      log_warn "Сертификат Caddy не найден за 90с — переключаемся на ACME для Hy2"
      log_info "Это нормально при первом запуске если DNS ещё не прогрессировал."
      log_info "Убедитесь что A-запись домена указывает на ${SERVER_IP}"
      cat >> /etc/hysteria/config.yaml << HYACMEFBEOF
acme:
  domains:
    - ${PROXY_DOMAIN}
  email: ${PROXY_EMAIL}
  ca: letsencrypt
  listenHost: 0.0.0.0
HYACMEFBEOF
    else
      # Даём Hy2 доступ к файлам сертификата
      chmod -R 755 "$(dirname "$CADDY_CERT_DIR")" 2>/dev/null || true
      chmod 644 "${CADDY_CERT_DIR}/${PROXY_DOMAIN}.crt" 2>/dev/null || true
      chmod 640 "${CADDY_CERT_DIR}/${PROXY_DOMAIN}.key" 2>/dev/null || true

      cat >> /etc/hysteria/config.yaml << HYTLSEOF
tls:
  cert: ${CADDY_CERT_DIR}/${PROXY_DOMAIN}.crt
  key:  ${CADDY_CERT_DIR}/${PROXY_DOMAIN}.key
HYTLSEOF

      # Hook: при обновлении сертификата Caddy → рестарт Hy2
      cat > /etc/systemd/system/caddy-cert-watcher.path << 'WATCHEOF'
[Unit]
Description=Watch Caddy cert for changes -> restart hysteria-server

[Path]
PathModified=/var/lib/caddy/.local/share/caddy/certificates

[Install]
WantedBy=multi-user.target
WATCHEOF

      cat > /etc/systemd/system/caddy-cert-watcher.service << 'WATCHSVCEOF'
[Unit]
Description=Restart hysteria-server on Caddy cert change

[Service]
Type=oneshot
ExecStart=/bin/systemctl restart hysteria-server.service
WATCHSVCEOF

      log_ok "caddy-cert-watcher настроен"
    fi

  else
    cat >> /etc/hysteria/config.yaml << HYACMEEOF
acme:
  domains:
    - ${PROXY_DOMAIN}
  email: ${PROXY_EMAIL}
  ca: letsencrypt
  listenHost: 0.0.0.0
HYACMEEOF
  fi

  cat >> /etc/hysteria/config.yaml << 'HYBWEOF'

# Bandwidth (Brutal congestion). Укажите реальную скорость канала, если знаете.
# По умолчанию — ignoreClientBandwidth: true (серверу подходит автоматика)
ignoreClientBandwidth: true

# QUIC tuning
quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s
  keepAlivePeriod: 10s
  disablePathMTUDiscovery: false
HYBWEOF

  # Systemd сервис Hysteria
  # Если Caddy установлен — Hy2 стартует после него (нужен его cert)
  if [[ $INSTALL_NAIVE -eq 1 ]]; then
    HY_UNIT_AFTER="After=network.target network-online.target caddy.service"
    HY_UNIT_WANTS="Wants=caddy.service"
  else
    HY_UNIT_AFTER="After=network.target network-online.target"
    HY_UNIT_WANTS=""
  fi

  cat > /etc/systemd/system/hysteria-server.service << HYSVCEOF
[Unit]
Description=Hysteria2 Server (by RIXXX)
Documentation=https://v2.hysteria.network/
${HY_UNIT_AFTER}
${HY_UNIT_WANTS}
Requires=network-online.target

[Service]
Type=simple
User=root
Group=root
ExecStart=/usr/local/bin/hysteria server --config /etc/hysteria/config.yaml
WorkingDirectory=/etc/hysteria
LimitNOFILE=1048576
LimitNPROC=512
AmbientCapabilities=CAP_NET_BIND_SERVICE
Restart=on-failure
RestartSec=10s
StartLimitIntervalSec=60s
StartLimitBurst=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
HYSVCEOF

  systemctl daemon-reload
  systemctl enable hysteria-server >/dev/null 2>&1 || true
  systemctl enable caddy-cert-watcher.path >/dev/null 2>&1 || true
  systemctl start  caddy-cert-watcher.path >/dev/null 2>&1 || true

  systemctl start hysteria-server 2>&1 || log_warn "hysteria-server start: возможны проблемы, см. journalctl -u hysteria-server"

  HY_OK=0
  for i in $(seq 1 20); do
    HY_STATUS=$(systemctl is-active hysteria-server 2>/dev/null || echo "unknown")
    if [[ "$HY_STATUS" == "active" ]]; then
      log_ok "Hysteria2 запущена (${i}с)"
      HY_OK=1
      break
    elif [[ "$HY_STATUS" == "failed" ]]; then
      log_warn "hysteria-server: failed — диагностика:"
      journalctl -u hysteria-server -n 20 --no-pager 2>/dev/null || true
      log_warn "Попытка рестарта..."
      systemctl reset-failed hysteria-server 2>/dev/null || true
      systemctl start hysteria-server 2>/dev/null || true
      break
    fi
    sleep 1
  done
  [[ $HY_OK -eq 0 ]] && log_warn "Hy2 не стартовала за 20с — команда для диагностики: journalctl -u hysteria-server -n 50 --no-pager"
fi

# ── Б9. Node.js ─────────────────────────────────────────────────────────
next_step "Установка Node.js 20..."

if ! command -v node &>/dev/null || [[ "$(node -v 2>/dev/null | cut -d. -f1 | tr -d 'v')" -lt 18 ]]; then
  log_info "Скачиваем NodeSource..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - 2>&1 | grep -E "^##|^Running|error" || true
  apt-get install -y -qq nodejs \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" 2>/dev/null || true
fi
NODE_VER=$(node -v 2>/dev/null || echo "не найден")
log_ok "Node.js: ${NODE_VER}"

# ── Б10. PM2 ────────────────────────────────────────────────────────────
next_step "Установка PM2..."
npm install -g pm2 --silent 2>&1 | grep -v "^npm warn" | tail -2 || true
PM2_VER=$(pm2 -v 2>/dev/null || echo "ok")
log_ok "PM2: ${PM2_VER}"

# ── Б11. Nginx (если нужно) ─────────────────────────────────────────────
if [[ "$ACCESS_MODE" == "1" || "$ACCESS_MODE" == "3" ]]; then
  next_step "Установка Nginx..."
  apt-get install -y -qq nginx \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" 2>/dev/null || true
  log_ok "Nginx установлен"
fi

# ── Б12. Клонирование панели ────────────────────────────────────────────
next_step "Загрузка панели управления..."

if [[ -d "${PANEL_DIR}/.git" ]]; then
  log_warn "Панель уже установлена — обновляем..."
  cd "${PANEL_DIR}" && git fetch --all && git reset --hard "origin/${REPO_BRANCH}" 2>&1 | tail -2 || true
else
  rm -rf "${PANEL_DIR}"
  git clone -b "${REPO_BRANCH}" "${REPO_URL}" "${PANEL_DIR}" 2>&1 || {
    log_err "Не удалось клонировать репозиторий"
    exit 1
  }
fi

cd "${PANEL_DIR}/panel"
npm install --omit=dev 2>&1 | grep -v "^npm warn" | tail -3 || true
mkdir -p "${PANEL_DIR}/panel/data"

log_ok "Панель загружена в ${PANEL_DIR}"

# ── Запись начального config.json ────────────────────────────────────
if [[ ! -f "${PANEL_DIR}/panel/data/config.json" ]]; then
  NAIVE_USERS_JSON="[]"
  HY2_USERS_JSON="[]"
  CREATED_AT="$(date -u +%FT%TZ)"

  if [[ $INSTALL_NAIVE -eq 1 ]]; then
    NAIVE_USERS_JSON="[{\"username\":\"${NAIVE_LOGIN}\",\"password\":\"${NAIVE_PASS}\",\"createdAt\":\"${CREATED_AT}\"}]"
  fi
  if [[ $INSTALL_HY2 -eq 1 ]]; then
    HY2_USERS_JSON="[{\"username\":\"default\",\"password\":\"${HY2_PASS}\",\"createdAt\":\"${CREATED_AT}\"}]"
  fi

  # Вычисляем boolean-флаги заранее (heredoc не поддерживает $() внутри)
  [[ $INSTALL_NAIVE -eq 1 ]] && STACK_NAIVE="true" || STACK_NAIVE="false"
  [[ $INSTALL_HY2   -eq 1 ]] && STACK_HY2="true"   || STACK_HY2="false"

  cat > "${PANEL_DIR}/panel/data/config.json" << CONFIGEOF
{
  "installed": true,
  "stack": {
    "naive": ${STACK_NAIVE},
    "hy2":   ${STACK_HY2}
  },
  "domain": "${PROXY_DOMAIN}",
  "email": "${PROXY_EMAIL}",
  "serverIp": "${SERVER_IP}",
  "arch": "${MACHINE_ARCH}",
  "adminPassword": "",
  "naiveUsers": ${NAIVE_USERS_JSON},
  "hy2Users":   ${HY2_USERS_JSON}
}
CONFIGEOF
  log_ok "config.json записан"
else
  log_warn "config.json уже существует — не перезаписываем"
fi

# ── Б13. UFW ────────────────────────────────────────────────────────────
next_step "Настройка файрволла UFW..."

ufw allow 22/tcp  >/dev/null 2>&1 || true
ufw allow 80/tcp  >/dev/null 2>&1 || true
ufw allow 443/tcp >/dev/null 2>&1 || true
ufw allow 443/udp >/dev/null 2>&1 || true

if [[ "$ACCESS_MODE" == "1" ]]; then
  ufw allow 8080/tcp >/dev/null 2>&1 || true
  ufw deny  ${INTERNAL_PORT}/tcp >/dev/null 2>&1 || true
elif [[ "$ACCESS_MODE" == "2" ]]; then
  ufw allow ${INTERNAL_PORT}/tcp >/dev/null 2>&1 || true
elif [[ "$ACCESS_MODE" == "3" ]]; then
  ufw deny  ${INTERNAL_PORT}/tcp >/dev/null 2>&1 || true
fi

echo "y" | ufw enable >/dev/null 2>&1 || ufw --force enable >/dev/null 2>&1 || true
log_ok "UFW настроен (22, 80, 443/tcp, 443/udp)"

# ── Б14. Запуск панели ──────────────────────────────────────────────────
next_step "Запуск панели через PM2..."

cd "${PANEL_DIR}/panel"
pm2 delete "${SERVICE_NAME}" 2>/dev/null || true
sleep 1

pm2 start server/index.js \
  --name "${SERVICE_NAME}" \
  --time \
  --restart-delay=3000 \
  2>&1 | tail -3

pm2 save --force >/dev/null 2>&1 || true

PM2_STARTUP=$(pm2 startup systemd -u root --hp /root 2>/dev/null | grep "^sudo" || true)
[[ -n "$PM2_STARTUP" ]] && eval "$PM2_STARTUP" >/dev/null 2>&1 || true

sleep 2

if pm2 describe "${SERVICE_NAME}" 2>/dev/null | grep -q "online"; then
  log_ok "Панель запущена"
else
  log_warn "Проверьте: pm2 status && pm2 logs ${SERVICE_NAME}"
fi

# ── Настройка Nginx ─────────────────────────────────────────────────────
if [[ "$ACCESS_MODE" == "1" ]]; then
  log_info "Настройка Nginx (8080 → 3000)..."
  cat > /etc/nginx/sites-available/panel-naive-hy2 << NGINXEOF
server {
    listen 8080;
    server_name _;
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    location / {
        proxy_pass http://127.0.0.1:${INTERNAL_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 86400;
    }
}
NGINXEOF
  ln -sf /etc/nginx/sites-available/panel-naive-hy2 \
    /etc/nginx/sites-enabled/panel-naive-hy2 2>/dev/null || true
  rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
  nginx -t >/dev/null 2>&1 && systemctl restart nginx && systemctl enable nginx >/dev/null 2>&1 \
    || log_warn "Nginx не запустился, проверьте: nginx -t"
  log_ok "Nginx настроен (8080 → 3000)"

elif [[ "$ACCESS_MODE" == "3" && -n "$PANEL_DOMAIN" ]]; then
  log_info "Настройка Nginx + SSL для ${PANEL_DOMAIN}..."
  apt-get install -y -qq python3-certbot-nginx 2>/dev/null || true

  cat > /etc/nginx/sites-available/panel-naive-hy2 << NGINXEOF
server {
    listen 80;
    server_name ${PANEL_DOMAIN};
    location / {
        proxy_pass http://127.0.0.1:${INTERNAL_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 86400;
    }
}
NGINXEOF
  ln -sf /etc/nginx/sites-available/panel-naive-hy2 \
    /etc/nginx/sites-enabled/panel-naive-hy2 2>/dev/null || true
  rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
  nginx -t >/dev/null 2>&1 && systemctl restart nginx && systemctl enable nginx >/dev/null 2>&1 || true

  certbot --nginx -d "${PANEL_DOMAIN}" \
    --email "${PANEL_EMAIL_SSL:-admin@${PANEL_DOMAIN}}" \
    --agree-tos --non-interactive 2>&1 | tail -4 \
    || log_warn "SSL для панели: проверьте DNS запись"

  log_ok "Nginx + SSL настроен для ${PANEL_DOMAIN}"
fi

# ════════════════════════════════════════════════════════════════════════
# ФИНАЛЬНЫЙ ВЫВОД
# ════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${PURPLE}${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${PURPLE}${BOLD}║   ✅  Установка завершена!                                    ║${RESET}"
echo -e "${PURPLE}${BOLD}╠══════════════════════════════════════════════════════════════╣${RESET}"
echo -e "${PURPLE}${BOLD}║   🌐  ПАНЕЛЬ УПРАВЛЕНИЯ                                       ║${RESET}"

if [[ "$ACCESS_MODE" == "1" ]]; then
  echo -e "${PURPLE}${BOLD}║   ➜   http://${SERVER_IP}:8080${RESET}"
elif [[ "$ACCESS_MODE" == "3" && -n "$PANEL_DOMAIN" ]]; then
  echo -e "${PURPLE}${BOLD}║   ➜   https://${PANEL_DOMAIN}${RESET}"
else
  echo -e "${PURPLE}${BOLD}║   ➜   http://${SERVER_IP}:${INTERNAL_PORT}${RESET}"
fi

echo -e "${PURPLE}${BOLD}║   👤  admin / admin  (⚠ СМЕНИТЕ В НАСТРОЙКАХ!)                ║${RESET}"
echo -e "${PURPLE}${BOLD}╠══════════════════════════════════════════════════════════════╣${RESET}"

if [[ $INSTALL_NAIVE -eq 1 ]]; then
  NAIVE_LINK="naive+https://${NAIVE_LOGIN}:${NAIVE_PASS}@${PROXY_DOMAIN}:443"
  echo -e "${PURPLE}${BOLD}║   🔒  NaiveProxy                                              ║${RESET}"
  echo -e "${PURPLE}${BOLD}║   Домен:  ${PROXY_DOMAIN}${RESET}"
  echo -e "${PURPLE}${BOLD}║   Логин:  ${NAIVE_LOGIN}${RESET}"
  echo -e "${PURPLE}${BOLD}║   Пароль: ${NAIVE_PASS}${RESET}"
  echo -e "${PURPLE}${BOLD}║   Link:${RESET}"
  echo -e "${CYAN}   ${NAIVE_LINK}${RESET}"
fi

if [[ $INSTALL_HY2 -eq 1 ]]; then
  HY2_LINK="hysteria2://${HY2_PASS}@${PROXY_DOMAIN}:443?sni=${PROXY_DOMAIN}#RIXXX"
  echo -e "${PURPLE}${BOLD}║                                                               ║${RESET}"
  echo -e "${PURPLE}${BOLD}║   ⚡  Hysteria2                                               ║${RESET}"
  echo -e "${PURPLE}${BOLD}║   Домен:  ${PROXY_DOMAIN}                                     ║${RESET}"
  echo -e "${PURPLE}${BOLD}║   Пароль: ${HY2_PASS}${RESET}"
  echo -e "${PURPLE}${BOLD}║   Link:${RESET}"
  echo -e "${CYAN}   ${HY2_LINK}${RESET}"
fi

echo -e "${PURPLE}${BOLD}╠══════════════════════════════════════════════════════════════╣${RESET}"
echo -e "${PURPLE}${BOLD}║   📌  Полезные команды:                                       ║${RESET}"
echo -e "${PURPLE}${BOLD}║   pm2 status                    — статус панели              ║${RESET}"
echo -e "${PURPLE}${BOLD}║   pm2 logs ${SERVICE_NAME}     — логи панели              ║${RESET}"
[[ $INSTALL_NAIVE -eq 1 ]] && echo -e "${PURPLE}${BOLD}║   systemctl status caddy        — NaiveProxy                 ║${RESET}"
[[ $INSTALL_HY2 -eq 1 ]] && echo -e "${PURPLE}${BOLD}║   systemctl status hysteria-server — Hysteria2               ║${RESET}"
echo -e "${PURPLE}${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "${GREEN}${BOLD}   Удачи! Telegram: https://t.me/russian_paradice_vpn${RESET}"
echo ""

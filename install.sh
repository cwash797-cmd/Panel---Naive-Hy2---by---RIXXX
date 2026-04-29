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
  log_err "Поддерживается только Ubuntu/Debian (apt-based)"
  log_info "Если у вас CentOS/RHEL/Fedora/Alpine — используйте другую VPS-систему"
  exit 1
fi

# Определяем дистрибутив
OS_ID=""; OS_VER=""; OS_CODENAME=""
if [[ -f /etc/os-release ]]; then
  OS_ID=$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
  OS_VER=$(grep -E '^VERSION_ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
  OS_CODENAME=$(grep -E '^VERSION_CODENAME=' /etc/os-release | cut -d= -f2 | tr -d '"')
fi
log_info "ОС: ${OS_ID:-unknown} ${OS_VER:-?} (${OS_CODENAME:-?})"

# Рекомендуем Ubuntu 22.04/24.04 и Debian 11/12
case "$OS_ID" in
  ubuntu)
    case "$OS_VER" in
      22.04|24.04) : ;;
      20.04) log_warn "Ubuntu 20.04 — работает, но рекомендуется 22.04+ (ядро новее)" ;;
      *) log_warn "Ubuntu $OS_VER — нестандартная версия, могут быть сюрпризы" ;;
    esac ;;
  debian)
    case "$OS_VER" in
      11|12) : ;;
      *) log_warn "Debian $OS_VER — рекомендуется 11 (bullseye) или 12 (bookworm)" ;;
    esac ;;
  *)
    log_warn "Дистрибутив '$OS_ID' официально не тестирован, но если apt работает — попробуем."
    log_info "Поддерживаются: Ubuntu 22.04/24.04, Debian 11/12 (amd64/arm64)."
    ;;
esac

# Проверка версии ядра для BBR (>=4.9)
KERNEL_MAJ=$(uname -r | awk -F. '{print $1}')
KERNEL_MIN=$(uname -r | awk -F. '{print $2}')
if [[ "${KERNEL_MAJ}" -lt 4 ]] || { [[ "${KERNEL_MAJ}" -eq 4 ]] && [[ "${KERNEL_MIN}" -lt 9 ]]; }; then
  log_warn "Ядро $(uname -r) < 4.9 — BBR недоступен, скорость TCP будет хуже"
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
echo -e "  ${CYAN}3)${RESET} На ${BOLD}отдельном поддомене${RESET} + HTTPS (максимальная защита)"
echo -e "      ${YELLOW}→ нужен ОТДЕЛЬНЫЙ поддомен для панели (не тот же, что у прокси)${RESET}"
echo ""
read -rp "Ваш выбор [1/2/3]: " ACCESS_MODE
ACCESS_MODE="${ACCESS_MODE:-1}"

PANEL_DOMAIN=""
PANEL_EMAIL_SSL=""
if [[ "$ACCESS_MODE" == "3" ]]; then
  echo ""
  echo -e "${YELLOW}  ⚠  Это должен быть ДРУГОЙ поддомен, не тот, где NaiveProxy/Hy2.${RESET}"
  echo -e "${YELLOW}     A-запись поддомена должна указывать на ${SERVER_IP}${RESET}"
  echo ""
  read -rp "  Поддомен для панели (например panel.yourdomain.com): " PANEL_DOMAIN
  read -rp "  Email для Let's Encrypt (SSL панели): " PANEL_EMAIL_SSL
fi

# ── A3. Параметры прокси ────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Параметры прокси:${RESET}"
echo -e "${YELLOW}  ⚠  Убедитесь что A-запись домена указывает на ${SERVER_IP}${RESET}"
echo ""
read -rp "  Домен (например vpn.yourdomain.com): " PROXY_DOMAIN
read -rp "  Email для Let's Encrypt (TLS): " PROXY_EMAIL

# Проверка что домен панели (если задан) отличается от домена прокси.
# Оба на 443/tcp (SNI разный) — совпадение сломает Caddy и/или маскировку.
if [[ "$ACCESS_MODE" == "3" && -n "$PANEL_DOMAIN" && "$PANEL_DOMAIN" == "$PROXY_DOMAIN" ]]; then
  log_err "Поддомен панели (${PANEL_DOMAIN}) совпадает с доменом прокси (${PROXY_DOMAIN})!"
  log_info "Они оба слушают 443/tcp через Caddy — это конфликт."
  log_info "Укажите разные поддомены, например vpn.example.com (прокси) и panel.example.com (панель)."
  exit 1
fi

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

TOTAL_STEPS=15
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

  # ВАЖНО: Если Hy2 ставится параллельно — отключаем HTTP/3 в Caddy,
  # иначе Caddy займёт UDP/443 для QUIC и Hy2 не сможет биндиться.
  # Caddyfile — минималистичный (1-в-1 как в рабочем d502280).
  # НЕ добавляем здесь acme_ca/email в глобальный блок — это ломало установку
  # у юзеров (Caddy либо валился на validate, либо отказывался получать cert,
  # если email в global не совпадал с email в site TLS).
  {
    printf '{\n'
    printf '  order forward_proxy before file_server\n'
    if [[ $INSTALL_HY2 -eq 1 ]]; then
      printf '  servers {\n'
      printf '    protocols h1 h2\n'
      printf '  }\n'
    fi
    printf '}\n\n'
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

    # ── Второй site-блок: панель на отдельном поддомене (ACCESS_MODE=3) ──
    # Caddy разрулит по SNI: домен прокси → NaiveProxy, PANEL_DOMAIN → панель.
    # Порт 443/tcp один, оба сайта живут параллельно. UDP/443 свободен для Hy2.
    # reverse_proxy в Caddy сам добавит нужные заголовки (Host, X-Forwarded-*),
    # поэтому дополнительные header_up не нужны (иначе Caddy пишет warn в логах).
    if [[ "$ACCESS_MODE" == "3" && -n "$PANEL_DOMAIN" ]]; then
      printf '\n'
      printf '%s {\n' "${PANEL_DOMAIN}"
      printf '  tls %s\n' "${PANEL_EMAIL_SSL:-${PROXY_EMAIL}}"
      printf '  encode gzip\n'
      printf '  reverse_proxy 127.0.0.1:%s\n' "${INTERNAL_PORT}"
      printf '}\n'
    fi
  } > /etc/caddy/Caddyfile

  /usr/bin/caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 \
    && log_ok "Caddyfile валиден" \
    || log_warn "Caddyfile — предупреждение (SSL получим при старте)"

  # ── Б6. Systemd сервис Caddy ─────────────────────────────────────────
  next_step "Systemd сервис Caddy..."

  systemctl stop caddy 2>/dev/null || true
  pkill -x caddy 2>/dev/null || true
  sleep 1

  # systemd unit для Caddy — 1-в-1 как в рабочем d502280.
  # НЕ добавляем Environment=HOME/XDG_* и не убираем PrivateTmp/ProtectSystem —
  # эти правки ломали Caddy (серт не получается, сервис не стартует).
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

# Маскировка трафика: отдаёт ТУ ЖЕ страницу что Caddy на TCP.
# type:file надёжнее чем proxy:bing.com — нет внешних зависимостей,
# не будет ошибок H3_GENERAL_PROTOCOL_ERROR в логах.
masquerade:
  type: file
  file:
    dir: /var/www/html

# TLS
HYCFGEOF

  if [[ "$HY_TLS_MODE" == "caddy" ]]; then
    # КРИТИЧНО: Caddy может получить сертификат от ЛЮБОГО CA
    # (Let's Encrypt / ZeroSSL / Google Trust). Путь в certificates/ содержит
    # имя CA. Ищем через find по ЛЮБОМУ пути, не только LE.
    CADDY_CERT_ROOTS=(
      "/var/lib/caddy/.local/share/caddy/certificates"
      "/root/.local/share/caddy/certificates"
    )
    CADDY_CERT_DIR=""

    log_info "Ждём сертификат от Caddy (до 150с, любой CA: LE/ZeroSSL/Google)..."
    for i in $(seq 1 75); do
      for ROOT in "${CADDY_CERT_ROOTS[@]}"; do
        [[ -d "$ROOT" ]] || continue
        # Ищем крт-файл для нашего домена в любой папке CA внутри certificates/
        FOUND=$(find "$ROOT" -type f -name "${PROXY_DOMAIN}.crt" 2>/dev/null | head -1)
        if [[ -n "$FOUND" && -f "${FOUND%.crt}.key" ]]; then
          CADDY_CERT_DIR="$(dirname "$FOUND")"
          CA_NAME="$(basename "$(dirname "$CADDY_CERT_DIR")")"
          log_ok "Сертификат найден (${i}х2с) — CA: ${CA_NAME}"
          log_info "  path: ${CADDY_CERT_DIR}"
          break 2
        fi
      done
      sleep 2
    done

    if [[ -z "$CADDY_CERT_DIR" ]]; then
      log_warn "Сертификат Caddy не найден за 150с."
      log_info "Диагностика (выполнит установщик):"
      systemctl status caddy --no-pager -l 2>&1 | tail -15 | sed 's/^/  /'
      journalctl -u caddy -n 20 --no-pager 2>&1 | tail -20 | sed 's/^/  /'
      log_info "Проверьте: ${PROXY_DOMAIN} должен указывать A-записью на ${SERVER_IP}"
      log_warn "⚠ Hy2 НЕ будет использовать собственный ACME (риск rate limit)."
      log_warn "  Вместо этого Hy2 остановлен. Запустите после починки Caddy:"
      log_warn "  systemctl restart caddy ; sleep 30 ; systemctl restart hysteria-server"
      # Вместо fallback ACME (который жжёт LE rate limit!) — отключаем Hy2 TLS секцию,
      # оставляя конфиг без tls/acme — Hy2 не стартует, это лучше чем получить 429 на неделю.
      cat >> /etc/hysteria/config.yaml << HYNOTLSEOF
# ⚠ Сертификат Caddy не был готов на момент установки.
# После того как Caddy получит серт, замените этот комментарий на:
#   tls:
#     cert: /var/lib/caddy/.local/share/caddy/certificates/<CA>/${PROXY_DOMAIN}/${PROXY_DOMAIN}.crt
#     key:  /var/lib/caddy/.local/share/caddy/certificates/<CA>/${PROXY_DOMAIN}/${PROXY_DOMAIN}.key
# и выполните: systemctl restart hysteria-server
HYNOTLSEOF
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
      # Watcher на обе возможные директории (новая /var/lib и legacy /root/.local)
      cat > /etc/systemd/system/caddy-cert-watcher.path << WATCHEOF
[Unit]
Description=Watch Caddy cert for changes -> restart hysteria-server

[Path]
PathModified=${CADDY_CERT_DIR}

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

      systemctl daemon-reload
      systemctl enable caddy-cert-watcher.path >/dev/null 2>&1 || true
      systemctl start  caddy-cert-watcher.path >/dev/null 2>&1 || true
      log_ok "caddy-cert-watcher настроен (${CADDY_CERT_DIR})"
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
# StartLimit* должны быть в [Unit], иначе systemd выдаёт warning
StartLimitIntervalSec=60s
StartLimitBurst=3

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
NGINX_OK=0
if [[ "$ACCESS_MODE" == "1" || "$ACCESS_MODE" == "3" ]]; then
  next_step "Установка Nginx..."

  # apt-get update на всякий случай (старый кеш на свежей VPS)
  apt-get update -qq 2>&1 | tail -2 || true

  # Если уже установлен — не переустанавливаем
  if command -v nginx >/dev/null 2>&1; then
    log_ok "Nginx уже установлен: $(nginx -v 2>&1 | head -1)"
    NGINX_OK=1
  else
    # Чистая установка — НЕ подавляем ошибки, нужен реальный код возврата
    apt-get install -y nginx \
      -o Dpkg::Options::="--force-confdef" \
      -o Dpkg::Options::="--force-confold" 2>&1 | tail -15
    APT_RC=${PIPESTATUS[0]}

    if [[ $APT_RC -eq 0 ]] && command -v nginx >/dev/null 2>&1; then
      log_ok "Nginx установлен: $(nginx -v 2>&1 | head -1)"
      NGINX_OK=1
    else
      log_err "Nginx не установился (exit=$APT_RC). Попробую второй раз через snap/apt с unlock..."
      # Попытка 2: часто на свежей Ubuntu 24 apt-lock от unattended-upgrades
      systemctl stop unattended-upgrades 2>/dev/null || true
      fuser -k /var/lib/dpkg/lock-frontend 2>/dev/null || true
      fuser -k /var/lib/dpkg/lock 2>/dev/null || true
      dpkg --configure -a 2>&1 | tail -5 || true
      sleep 2
      if apt-get install -y nginx 2>&1 | tail -10 && command -v nginx >/dev/null 2>&1; then
        log_ok "Nginx установлен со второй попытки"
        NGINX_OK=1
      else
        log_err "Nginx всё равно не установился. Панель будет доступна только на порту ${INTERNAL_PORT}."
        log_info "  Диагностика: apt-cache policy nginx ; dpkg -l | grep nginx"
        NGINX_OK=0
      fi
    fi
  fi

  # Если Nginx всё-таки провалился — автоматически переключаемся на прямой доступ
  if [[ $NGINX_OK -eq 0 ]]; then
    log_warn "ACCESS_MODE переключён с Nginx на прямой доступ к порту ${INTERNAL_PORT}"
    ACCESS_MODE="2"
  fi
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
  "panelDomain": "${PANEL_DOMAIN}",
  "panelEmail":  "${PANEL_EMAIL_SSL}",
  "accessMode":  "${ACCESS_MODE}",
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

# ── Б13. UFW (базовые порты) ────────────────────────────────────────────
# ВАЖНО: Порты панели (3000/8080) настраиваем ПОСЛЕ запуска Nginx,
# чтобы при провале nginx автоматически открыть 3000.
next_step "Настройка файрволла UFW (базовые порты)..."

ufw allow 22/tcp  >/dev/null 2>&1 || true
ufw allow 80/tcp  >/dev/null 2>&1 || true
ufw allow 443/tcp >/dev/null 2>&1 || true
ufw allow 443/udp >/dev/null 2>&1 || true

echo "y" | ufw enable >/dev/null 2>&1 || ufw --force enable >/dev/null 2>&1 || true
log_ok "UFW: 22, 80, 443/tcp, 443/udp открыты"

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
  log_ok "Панель запущена через PM2"
else
  log_warn "PM2 не запустил панель. Пробуем systemd-fallback..."

  # Fallback: создаём systemd-юнит и запускаем напрямую через Node.js
  cat > /etc/systemd/system/panel-naive-hy2.service << SVCFALLBACKEOF
[Unit]
Description=Panel Naive + Hy2 by RIXXX (fallback)
After=network.target

[Service]
Type=simple
WorkingDirectory=${PANEL_DIR}/panel
ExecStart=/usr/bin/node server/index.js
Restart=always
RestartSec=5
Environment=NODE_ENV=production
Environment=PORT=${INTERNAL_PORT}
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCFALLBACKEOF
  systemctl daemon-reload
  systemctl enable panel-naive-hy2 >/dev/null 2>&1 || true
  systemctl restart panel-naive-hy2 2>&1 || true
  sleep 2
  if systemctl is-active --quiet panel-naive-hy2; then
    log_ok "Панель запущена через systemd (fallback)"
  else
    log_err "Панель не стартовала. Диагностика: journalctl -u panel-naive-hy2 -n 50"
  fi
fi

# Финальная проверка: панель отвечает на порту 3000
sleep 2
if curl -fsS --max-time 5 "http://127.0.0.1:${INTERNAL_PORT}/" >/dev/null 2>&1; then
  log_ok "Панель отвечает на http://127.0.0.1:${INTERNAL_PORT} ✓"
else
  log_warn "Панель НЕ отвечает на порту ${INTERNAL_PORT}!"
  log_info "  pm2 logs ${SERVICE_NAME} --lines 30   — логи через PM2"
  log_info "  journalctl -u panel-naive-hy2 -n 30   — логи через systemd"
  log_info "  cd ${PANEL_DIR}/panel && node server/index.js   — запуск вручную для отладки"
fi

# ── Настройка Nginx ─────────────────────────────────────────────────────
if [[ "$ACCESS_MODE" == "1" ]]; then
  # Двойная защита: если nginx не установлен — не пытаемся его настраивать
  if ! command -v nginx >/dev/null 2>&1; then
    log_err "Nginx не найден (command -v nginx). Пропускаю настройку."
    log_warn "Панель доступна только на порту ${INTERNAL_PORT}."
    ACCESS_MODE="2"
  elif [[ ! -d /etc/nginx/sites-available ]]; then
    log_err "/etc/nginx/sites-available не существует (повреждённая установка?)."
    log_warn "Панель доступна только на порту ${INTERNAL_PORT}."
    ACCESS_MODE="2"
  fi
fi

if [[ "$ACCESS_MODE" == "1" ]]; then
  log_info "Настройка Nginx (8080 → 3000)..."
  # На всякий случай гарантируем директории (на Ubuntu 24 иногда отсутствуют после minimal)
  mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
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

  # Валидация и запуск Nginx с детальным выводом ошибок
  if nginx -t 2>&1 | tee /tmp/nginx-test.log | grep -q "successful"; then
    systemctl restart nginx 2>&1 || log_warn "systemctl restart nginx fail"
    systemctl enable nginx >/dev/null 2>&1 || true
    log_ok "Nginx настроен (8080 → 3000)"
  else
    log_err "Nginx config invalid! Вывод nginx -t:"
    cat /tmp/nginx-test.log
    log_warn "Панель будет доступна напрямую на порту ${INTERNAL_PORT} (3000)"
  fi

  # Финальная проверка что 8080 действительно слушается
  sleep 1
  if ss -tlnp 2>/dev/null | grep -q ':8080 '; then
    log_ok "Порт 8080 слушается ✓"
  else
    log_warn "Порт 8080 НЕ слушается! Проверьте: ss -tlnp | grep 8080"
    log_warn "  Возможно nginx не запущен. Команды: systemctl status nginx; nginx -t"
  fi

elif [[ "$ACCESS_MODE" == "3" && -n "$PANEL_DOMAIN" ]]; then
  # ─ Путь A: NaiveProxy установлен → Caddy уже держит 443/tcp и знает
  #   про PANEL_DOMAIN (site-блок добавлен на шаге Б5). Nginx не нужен,
  #   certbot не нужен — Caddy сам выдаст LE cert для панели.
  #   Если нужно, убираем конфликтующий Nginx-дефолт с :80.
  if [[ $INSTALL_NAIVE -eq 1 ]] && command -v caddy >/dev/null 2>&1; then
    log_info "Панель через Caddy на https://${PANEL_DOMAIN} (NaiveProxy рядом на том же 443)"
    # На всякий случай отключаем дефолтный сайт Nginx, если он ставился кем-то ранее
    # (не в этой установке — чистая Ubuntu 24 Nginx не имеет, но bulletproof)
    if command -v nginx >/dev/null 2>&1; then
      rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
      # Если Nginx был запущен прошлой установкой — останавливаем, 80 оставляем Caddy
      systemctl stop nginx 2>/dev/null || true
      systemctl disable nginx 2>/dev/null || true
    fi

    # Перезагружаем Caddy чтобы он подхватил site-блок для PANEL_DOMAIN
    # и заказал LE cert (TLS-ALPN challenge на 443 — параллельно прокси).
    if caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
      systemctl reload caddy 2>/dev/null || systemctl restart caddy 2>/dev/null || true
      log_info "Caddy перезагружен — ждём LE cert для ${PANEL_DOMAIN} (до 60с)..."

      # Ждём фактического получения серта панели
      PANEL_CERT_OK=0
      for i in $(seq 1 30); do
        if find /root/.local/share/caddy /var/lib/caddy/.local/share/caddy \
             -type f -name "${PANEL_DOMAIN}.crt" 2>/dev/null | grep -q .; then
          PANEL_CERT_OK=1
          log_ok "Сертификат для ${PANEL_DOMAIN} получен (${i}х2с)"
          break
        fi
        sleep 2
      done
      if [[ $PANEL_CERT_OK -eq 0 ]]; then
        log_warn "Сертификат для ${PANEL_DOMAIN} пока не получен."
        log_info "  Проверьте: A-запись ${PANEL_DOMAIN} -> ${SERVER_IP}"
        log_info "  Логи:      journalctl -u caddy -n 40 --no-pager"
        log_info "  Cert придёт в фоне — откройте https://${PANEL_DOMAIN} через пару минут."
      fi
    else
      log_err "Caddyfile невалиден! Панель на домене не поднимется."
      log_info "  caddy validate --config /etc/caddy/Caddyfile"
      ACCESS_MODE="2"
    fi

  # ─ Путь B: NaiveProxy НЕ установлен → Caddy нет, ставим Nginx+certbot.
  #   Тут 443 свободен, classic HTTP-01/ALPN через Nginx работает.
  elif ! command -v nginx >/dev/null 2>&1; then
    log_err "Nginx не установлен — SSL-настройка невозможна. Панель доступна на порту ${INTERNAL_PORT}."
    ACCESS_MODE="2"
  else
    log_info "Настройка Nginx + SSL для ${PANEL_DOMAIN} (без NaiveProxy)..."
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
    apt-get install -y -qq python3-certbot-nginx 2>&1 | tail -3 || log_warn "certbot-nginx не установлен, попробуем без него"

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
fi

# ── Б15. UFW для порта панели (финал — после Nginx) ─────────────────────
# Только сейчас мы знаем финальный ACCESS_MODE (мог смениться при провале Nginx)
log_info "UFW: открываю порт панели согласно режиму доступа..."
if [[ "$ACCESS_MODE" == "1" ]]; then
  # Nginx успешно настроен на 8080 → открываем 8080, закрываем 3000
  ufw allow 8080/tcp >/dev/null 2>&1 || true
  ufw deny  ${INTERNAL_PORT}/tcp >/dev/null 2>&1 || true
  log_ok "UFW: 8080/tcp открыт, ${INTERNAL_PORT}/tcp закрыт"
elif [[ "$ACCESS_MODE" == "2" ]]; then
  # Прямой доступ → открываем 3000
  ufw allow ${INTERNAL_PORT}/tcp >/dev/null 2>&1 || true
  log_ok "UFW: ${INTERNAL_PORT}/tcp открыт (прямой доступ)"
elif [[ "$ACCESS_MODE" == "3" ]]; then
  # Nginx+SSL на домене → открыто только 80/443, 3000 закрыт
  ufw deny  ${INTERNAL_PORT}/tcp >/dev/null 2>&1 || true
  log_ok "UFW: ${INTERNAL_PORT}/tcp закрыт, доступ через домен (443/tcp)"
fi

# ════════════════════════════════════════════════════════════════════════
# ФИНАЛЬНАЯ САМОПРОВЕРКА
# ════════════════════════════════════════════════════════════════════════
next_step "Финальная самопроверка панели..."

# Сначала panel на 3000 (он точно должен слушать внутри)
sleep 2
PANEL_LOCAL_OK=0
if curl -fsS --max-time 5 "http://127.0.0.1:${INTERNAL_PORT}/" >/dev/null 2>&1; then
  log_ok "Панель отвечает на http://127.0.0.1:${INTERNAL_PORT}"
  PANEL_LOCAL_OK=1
else
  log_err "Панель НЕ отвечает на 127.0.0.1:${INTERNAL_PORT}!"
  log_info "  pm2 status ; pm2 logs ${SERVICE_NAME} --lines 40"
fi

# Проверка финальной точки входа в зависимости от ACCESS_MODE
if [[ "$ACCESS_MODE" == "1" ]]; then
  if ss -tlnp 2>/dev/null | grep -q ':8080 '; then
    log_ok "Порт 8080 (Nginx) слушается"
    if curl -fsS --max-time 5 "http://127.0.0.1:8080/" >/dev/null 2>&1; then
      log_ok "Nginx отвечает на :8080 и проксирует на панель ✓"
    else
      log_warn "Nginx слушает :8080 но проксирование не работает. Проверьте: nginx -t; systemctl status nginx"
    fi
  else
    log_err "Порт 8080 НЕ слушается!"
    log_warn "Nginx мог провалиться при запуске. Пробую как fallback открыть прямой доступ к :${INTERNAL_PORT}..."
    ufw allow ${INTERNAL_PORT}/tcp >/dev/null 2>&1 || true
    ACCESS_MODE="2"
  fi
elif [[ "$ACCESS_MODE" == "2" ]]; then
  if ss -tlnp 2>/dev/null | grep -q ":${INTERNAL_PORT} "; then
    log_ok "Порт ${INTERNAL_PORT} слушается, панель доступна напрямую"
  else
    log_err "Порт ${INTERNAL_PORT} НЕ слушается!"
  fi
elif [[ "$ACCESS_MODE" == "3" && -n "$PANEL_DOMAIN" ]]; then
  # Режим 3 через Caddy (если NaiveProxy есть) или Nginx (если нет)
  if [[ $INSTALL_NAIVE -eq 1 ]] && command -v caddy >/dev/null 2>&1; then
    if ss -tlnp 2>/dev/null | grep -q ':443 '; then
      log_ok "Порт 443 (Caddy) слушается — обслуживает прокси и панель по SNI"
    else
      log_err "Порт 443 НЕ слушается! Проверьте: systemctl status caddy"
    fi
    # Пробуем реально достучаться через Host-заголовок
    if curl -fsSk --max-time 8 -H "Host: ${PANEL_DOMAIN}" "https://127.0.0.1/" >/dev/null 2>&1; then
      log_ok "Caddy отвечает на https://${PANEL_DOMAIN} ✓"
    else
      log_warn "Caddy пока не отвечает на https://${PANEL_DOMAIN}."
      log_info "  Возможно, LE cert ещё выписывается. Повторите попытку через 1–2 минуты:"
      log_info "    curl -I https://${PANEL_DOMAIN}/"
    fi
  else
    # Путь B — Nginx
    if ss -tlnp 2>/dev/null | grep -q ':443 '; then
      log_ok "Порт 443 (Nginx) слушается"
    else
      log_err "Порт 443 НЕ слушается! Проверьте: systemctl status nginx"
    fi
  fi
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
  # ВАЖНО: при userpass-авторизации в URI auth = username:password
  # (см. https://v2.hysteria.network/docs/developers/URI-Scheme/)
  HY2_LINK="hysteria2://default:${HY2_PASS}@${PROXY_DOMAIN}:443?sni=${PROXY_DOMAIN}&insecure=0#RIXXX"
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

# ── Запись версии патчей ───────────────────────────────────────────────
# Новая установка сразу считается на актуальной версии — update.sh не будет
# пытаться повторно применять миграции, которые install.sh уже сделал.
# Должно совпадать с TARGET_VERSION в update.sh.
PANEL_PATCH_VERSION="1.0.0"
mkdir -p /etc/rixxx-panel
echo "$PANEL_PATCH_VERSION" > /etc/rixxx-panel/version
chmod 644 /etc/rixxx-panel/version
log_info "Версия патчей: ${PANEL_PATCH_VERSION} (см. /etc/rixxx-panel/version)"
log_info "Для будущих обновлений: bash <(curl -fsSL https://raw.githubusercontent.com/cwash797-cmd/Panel---Naive-Hy2---by---RIXXX/main/update.sh)"
echo ""

echo -e "${GREEN}${BOLD}   Удачи! Telegram: https://t.me/russian_paradice_vpn${RESET}"
echo ""

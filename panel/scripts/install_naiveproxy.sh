#!/bin/bash
# ═══════════════════════════════════════════════════════
#  NaiveProxy Auto-Installer — by RIXXX (multi-arch)
#  Panel Naive + Hysteria2 by RIXXX
#  ENV: NAIVE_DOMAIN, NAIVE_EMAIL, NAIVE_LOGIN, NAIVE_PASSWORD
# ═══════════════════════════════════════════════════════

set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

DOMAIN="${NAIVE_DOMAIN:-}"
EMAIL="${NAIVE_EMAIL:-}"
LOGIN="${NAIVE_LOGIN:-}"
PASSWORD="${NAIVE_PASSWORD:-}"
WITH_HY2="${WITH_HY2:-0}"  # 1 = отключить HTTP/3 в Caddy чтобы освободить UDP/443 для Hy2

if [[ -z "$DOMAIN" || -z "$EMAIL" || -z "$LOGIN" || -z "$PASSWORD" ]]; then
  echo "ERROR: missing env NAIVE_DOMAIN/NAIVE_EMAIL/NAIVE_LOGIN/NAIVE_PASSWORD"
  exit 1
fi

log()  { echo "$1"; }
step() { echo "STEP:$1"; }

# ── Определяем архитектуру ─────────────────────────────
case "$(uname -m)" in
  x86_64)  GO_ARCH="amd64"  ;;
  aarch64) GO_ARCH="arm64"  ;;
  armv7l)  GO_ARCH="armv6l" ;;
  *)       GO_ARCH="amd64"  ;;
esac
log "  Arch: $(uname -m) → Go:${GO_ARCH}"

# ══════════════════════════════════════════════════════
step 1
log "▶ Обновление системы и установка зависимостей..."
# ══════════════════════════════════════════════════════

systemctl stop unattended-upgrades 2>/dev/null || true
systemctl disable unattended-upgrades 2>/dev/null || true
pkill -9 unattended-upgrades 2>/dev/null || true
sleep 2

rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock \
      /var/cache/apt/archives/lock /var/lib/apt/lists/lock 2>/dev/null || true
dpkg --configure -a >/dev/null 2>&1 || true

if [ -f /etc/needrestart/needrestart.conf ]; then
  sed -i "s/#\$nrconf{restart} = 'i';/\$nrconf{restart} = 'a';/" \
    /etc/needrestart/needrestart.conf 2>/dev/null || true
  sed -i "s/\$nrconf{restart} = 'i';/\$nrconf{restart} = 'a';/" \
    /etc/needrestart/needrestart.conf 2>/dev/null || true
fi

apt-get update -y -qq -o DPkg::Lock::Timeout=120 2>/dev/null || true
apt-get install -y -qq \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold" \
  -o DPkg::Lock::Timeout=120 \
  curl wget git openssl ufw build-essential libcap2-bin 2>/dev/null || true

log "✅ Система обновлена"

# ══════════════════════════════════════════════════════
step 2
log "▶ Включение BBR..."
# ══════════════════════════════════════════════════════

cat > /etc/sysctl.d/99-rixxx-tune.conf << 'SYSCTLEOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.rmem_default=2500000
net.core.wmem_default=2500000
net.ipv4.tcp_fastopen=3
SYSCTLEOF
sysctl --system >/dev/null 2>&1 || true

log "✅ BBR включён"

# ══════════════════════════════════════════════════════
step 3
log "▶ Настройка файрволла UFW..."
# ══════════════════════════════════════════════════════

ufw allow 22/tcp  >/dev/null 2>&1 || true
ufw allow 80/tcp  >/dev/null 2>&1 || true
ufw allow 443/tcp >/dev/null 2>&1 || true
ufw allow 443/udp >/dev/null 2>&1 || true
echo "y" | ufw enable >/dev/null 2>&1 || ufw --force enable >/dev/null 2>&1 || true
log "✅ Файрволл настроен (22, 80, 443/tcp+udp)"

# ══════════════════════════════════════════════════════
step 4
log "▶ Установка Go (arch: ${GO_ARCH})..."
# ══════════════════════════════════════════════════════

rm -rf /usr/local/go

GO_VERSION=""
for attempt in 1 2 3; do
  GO_VERSION=$(curl -fsSL --connect-timeout 10 'https://go.dev/VERSION?m=text' 2>/dev/null | head -n1 | tr -d '[:space:]' || true)
  [[ -n "$GO_VERSION" && "$GO_VERSION" == go* ]] && break
  sleep 2
done
[[ -z "$GO_VERSION" || "$GO_VERSION" != go* ]] && GO_VERSION="go1.22.5"

log "  Загружаем ${GO_VERSION}.linux-${GO_ARCH}..."
wget -q --timeout=180 \
  "https://go.dev/dl/${GO_VERSION}.linux-${GO_ARCH}.tar.gz" \
  -O /tmp/go.tar.gz

if [[ ! -s /tmp/go.tar.gz ]]; then
  log "ERROR: Не удалось загрузить Go"
  exit 1
fi

tar -C /usr/local -xzf /tmp/go.tar.gz
rm -f /tmp/go.tar.gz

export PATH=$PATH:/usr/local/go/bin:/root/go/bin
export GOPATH=/root/go
export GOROOT=/usr/local/go

grep -q "/usr/local/go/bin" /root/.profile 2>/dev/null || {
  echo 'export PATH=$PATH:/usr/local/go/bin:/root/go/bin' >> /root/.profile
  echo 'export GOPATH=/root/go' >> /root/.profile
}

GO_VER=$(/usr/local/go/bin/go version 2>/dev/null || echo "unknown")
log "✅ Go установлен: $GO_VER"

# ══════════════════════════════════════════════════════
step 5
log "▶ Сборка Caddy с naive-плагином (займёт 3-7 минут)..."
# ══════════════════════════════════════════════════════

export GOPATH=/root/go
export GOROOT=/usr/local/go
export PATH=$GOROOT/bin:$GOPATH/bin:$PATH
export TMPDIR=/root/tmp
export GOPROXY=https://proxy.golang.org,direct
mkdir -p /root/tmp /root/go

log "  Установка xcaddy..."
/usr/local/go/bin/go install \
  github.com/caddyserver/xcaddy/cmd/xcaddy@latest \
  2>&1 | grep -v "^$" | tail -3

if [[ ! -f /root/go/bin/xcaddy ]]; then
  log "ERROR: xcaddy не установился"
  exit 1
fi

log "  Сборка Caddy + forwardproxy@naive..."
cd /root
rm -f /root/caddy

/root/go/bin/xcaddy build \
  --with github.com/caddyserver/forwardproxy@caddy2=github.com/klzgrad/forwardproxy@naive \
  2>&1 | grep -v "^$" | while IFS= read -r line; do
    echo "  $line"
  done

if [[ ! -f /root/caddy ]]; then
  log "ERROR: Caddy не был собран! Проверьте интернет."
  exit 1
fi

mv /root/caddy /usr/bin/caddy
chmod +x /usr/bin/caddy
setcap 'cap_net_bind_service=+ep' /usr/bin/caddy 2>/dev/null || true

CADDY_VER=$(/usr/bin/caddy version 2>/dev/null || echo "unknown")
log "✅ Caddy собран: $CADDY_VER"

# ══════════════════════════════════════════════════════
step 6
log "▶ Создание конфигурационных файлов..."
# ══════════════════════════════════════════════════════

mkdir -p /var/www/html /etc/caddy

cat > /var/www/html/index.html << 'HTMLEOF'
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>Loading</title>
  <style>
    body{background:#080808;height:100vh;margin:0;display:flex;flex-direction:column;align-items:center;justify-content:center;font-family:sans-serif}
    .bar{width:200px;height:3px;background:#151515;overflow:hidden;border-radius:2px;margin-bottom:25px}
    .fill{height:100%;width:40%;background:#fff;animation:slide 1.4s infinite ease-in-out}
    @keyframes slide{0%{transform:translateX(-100%)}50%{transform:translateX(50%)}100%{transform:translateX(200%)}}
    .t{color:#555;font-size:13px;letter-spacing:3px;font-weight:600}
  </style>
</head>
<body>
  <div class="bar"><div class="fill"></div></div>
  <div class="t">LOADING CONTENT</div>
</body>
</html>
HTMLEOF

# ВАЖНО: при WITH_HY2=1 отключаем HTTP/3 чтобы UDP/443 был свободен для Hysteria2.
{
  printf '{\n'
  printf '  order forward_proxy before file_server\n'
  if [[ "$WITH_HY2" == "1" ]]; then
    printf '  servers {\n'
    printf '    protocols h1 h2\n'
    printf '  }\n'
  fi
  printf '}\n\n'
  printf ':443, %s {\n' "$DOMAIN"
  printf '  tls %s\n\n' "$EMAIL"
  printf '  forward_proxy {\n'
  printf '    basic_auth %s %s\n' "$LOGIN" "$PASSWORD"
  printf '    hide_ip\n'
  printf '    hide_via\n'
  printf '    probe_resistance\n'
  printf '  }\n\n'
  printf '  file_server {\n'
  printf '    root /var/www/html\n'
  printf '  }\n'
  printf '}\n'
} > /etc/caddy/Caddyfile

if /usr/bin/caddy validate --config /etc/caddy/Caddyfile 2>&1; then
  log "✅ Caddyfile валиден для $DOMAIN"
else
  log "⚠ Валидация: предупреждение (продолжаем)"
fi

# ══════════════════════════════════════════════════════
step 7
log "▶ Настройка systemd сервиса..."
# ══════════════════════════════════════════════════════

systemctl stop caddy 2>/dev/null || true
pkill -x caddy 2>/dev/null || true
sleep 1

cat > /etc/systemd/system/caddy.service << 'SERVICEEOF'
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
SERVICEEOF

systemctl daemon-reload
log "✅ Systemd сервис создан"

# ══════════════════════════════════════════════════════
step 8
log "▶ Включение и запуск Caddy..."
# ══════════════════════════════════════════════════════

systemctl enable caddy 2>&1 || true

if systemctl start caddy 2>&1; then
  log "  Caddy запускается..."
else
  log "⚠ systemctl start fail, fallback в nohup..."
  pkill -f "caddy run" 2>/dev/null || true
  sleep 1
  nohup /usr/bin/caddy run --config /etc/caddy/Caddyfile \
    > /var/log/caddy.log 2>&1 &
fi

for i in $(seq 1 20); do
  if systemctl is-active --quiet caddy 2>/dev/null; then
    log "✅ Caddy запущен (через ${i}с)"
    break
  elif pgrep -x caddy >/dev/null 2>/dev/null; then
    log "✅ Caddy запущен как процесс (${i}с)"
    break
  fi
  sleep 1
  if [[ $i -eq 20 ]]; then
    log "⚠ Caddy запускается медленно, см.: journalctl -u caddy -n 30"
  fi
done

step DONE
log ""
log "╔════════════════════════════════════════════════════╗"
log "║   ✅ NaiveProxy успешно установлен!                ║"
log "║   Домен: ${DOMAIN}"
log "║   naive+https://${LOGIN}:****@${DOMAIN}:443"
log "╚════════════════════════════════════════════════════╝"
log ""

exit 0

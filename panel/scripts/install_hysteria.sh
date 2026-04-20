#!/bin/bash
# ═══════════════════════════════════════════════════════
#  Hysteria2 Auto-Installer — by RIXXX (multi-arch)
#  Panel Naive + Hysteria2 by RIXXX
#  ENV: HY_DOMAIN, HY_EMAIL, HY_PASSWORD, USE_CADDY_CERT (0/1)
# ═══════════════════════════════════════════════════════

set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

DOMAIN="${HY_DOMAIN:-}"
EMAIL="${HY_EMAIL:-admin@example.com}"
PASSWORD="${HY_PASSWORD:-}"
USE_CADDY_CERT="${USE_CADDY_CERT:-0}"

if [[ -z "$DOMAIN" || -z "$PASSWORD" ]]; then
  echo "ERROR: missing env HY_DOMAIN / HY_PASSWORD"
  exit 1
fi

log()  { echo "$1"; }
step() { echo "STEP:$1"; }

case "$(uname -m)" in
  x86_64)  HY_ARCH="amd64" ;;
  aarch64) HY_ARCH="arm64" ;;
  armv7l)  HY_ARCH="arm"   ;;
  *)       HY_ARCH="amd64" ;;
esac
log "  Arch: $(uname -m) → Hy2:${HY_ARCH}"

# ══════════════════════════════════════════════════════
step 1
log "▶ Установка зависимостей..."
# ══════════════════════════════════════════════════════

apt-get update -qq -o DPkg::Lock::Timeout=60 2>/dev/null || true
apt-get install -y -qq curl wget jq libcap2-bin ufw ca-certificates 2>/dev/null || true
log "✅ Зависимости готовы"

# ══════════════════════════════════════════════════════
step 2
log "▶ UDP-оптимизации..."
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

log "✅ Сетевой тюнинг применён"

# ══════════════════════════════════════════════════════
step 3
log "▶ Настройка файрволла..."
# ══════════════════════════════════════════════════════

ufw allow 22/tcp  >/dev/null 2>&1 || true
ufw allow 80/tcp  >/dev/null 2>&1 || true
ufw allow 443/tcp >/dev/null 2>&1 || true
ufw allow 443/udp >/dev/null 2>&1 || true
echo "y" | ufw enable >/dev/null 2>&1 || ufw --force enable >/dev/null 2>&1 || true

log "✅ UDP/443 открыт"

# ══════════════════════════════════════════════════════
step 4
log "▶ Загрузка Hysteria2 (arch: ${HY_ARCH})..."
# ══════════════════════════════════════════════════════

HY_VERSION=$(curl -fsSL --connect-timeout 10 \
  https://api.github.com/repos/apernet/hysteria/releases/latest 2>/dev/null \
  | jq -r '.tag_name' 2>/dev/null || echo "")
[[ -z "$HY_VERSION" || "$HY_VERSION" == "null" ]] && HY_VERSION="app/v2.5.2"

log "  Версия: ${HY_VERSION}"
HY_URL="https://github.com/apernet/hysteria/releases/download/${HY_VERSION}/hysteria-linux-${HY_ARCH}"

wget -q --timeout=120 "${HY_URL}" -O /usr/local/bin/hysteria 2>&1 || {
  log "⚠ Не удалось скачать ${HY_VERSION}, fallback → app/v2.5.2"
  wget -q --timeout=120 \
    "https://github.com/apernet/hysteria/releases/download/app/v2.5.2/hysteria-linux-${HY_ARCH}" \
    -O /usr/local/bin/hysteria || {
    log "ERROR: Не удалось скачать hysteria!"
    exit 1
  }
}

if [[ ! -s /usr/local/bin/hysteria ]]; then
  log "ERROR: бинарник hysteria пустой"
  exit 1
fi

chmod +x /usr/local/bin/hysteria
setcap 'cap_net_bind_service=+ep' /usr/local/bin/hysteria 2>/dev/null || true

HY_VER=$(/usr/local/bin/hysteria version 2>&1 | head -n1 || echo "unknown")
log "✅ Hysteria2 установлена: $HY_VER"

# ══════════════════════════════════════════════════════
step 5
log "▶ Создание конфига..."
# ══════════════════════════════════════════════════════

mkdir -p /etc/hysteria

cat > /etc/hysteria/config.yaml << HYCFGEOF
# ═══════════════════════════════════════════════
#  Hysteria2 — by RIXXX
#  https://v2.hysteria.network/
# ═══════════════════════════════════════════════

listen: :443

auth:
  type: userpass
  userpass:
    default: "${PASSWORD}"

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true

HYCFGEOF

if [[ "$USE_CADDY_CERT" == "1" ]]; then
  CADDY_CERT_DIR="/var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/${DOMAIN}"

  log "  Ждём сертификат от Caddy..."
  for i in $(seq 1 30); do
    if [[ -f "${CADDY_CERT_DIR}/${DOMAIN}.crt" ]]; then
      log "✅ Сертификат найден (${i}с)"
      break
    fi
    sleep 2
  done

  cat >> /etc/hysteria/config.yaml << HYTLSEOF
tls:
  cert: ${CADDY_CERT_DIR}/${DOMAIN}.crt
  key: ${CADDY_CERT_DIR}/${DOMAIN}.key
HYTLSEOF

  chmod -R 755 /var/lib/caddy 2>/dev/null || true

  # Watcher на перезагрузку Hy2 при обновлении сертификата
  cat > /etc/systemd/system/caddy-cert-watcher.path << 'WATCHEOF'
[Unit]
Description=Watch Caddy cert for changes -> restart hysteria

[Path]
PathModified=/var/lib/caddy/.local/share/caddy/certificates

[Install]
WantedBy=multi-user.target
WATCHEOF

  cat > /etc/systemd/system/caddy-cert-watcher.service << 'WATCHSVCEOF'
[Unit]
Description=Restart hysteria on Caddy cert change

[Service]
Type=oneshot
ExecStart=/bin/systemctl restart hysteria-server.service
WATCHSVCEOF

  systemctl enable caddy-cert-watcher.path >/dev/null 2>&1 || true
  systemctl start caddy-cert-watcher.path >/dev/null 2>&1 || true

else
  cat >> /etc/hysteria/config.yaml << HYACMEEOF
acme:
  domains:
    - ${DOMAIN}
  email: ${EMAIL}
  ca: letsencrypt
  listenHost: 0.0.0.0
HYACMEEOF
fi

cat >> /etc/hysteria/config.yaml << 'HYBWEOF'

ignoreClientBandwidth: true

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s
  keepAlivePeriod: 10s
  disablePathMTUDiscovery: false
HYBWEOF

log "✅ Конфиг /etc/hysteria/config.yaml создан"

# ══════════════════════════════════════════════════════
step 6
log "▶ Systemd сервис Hysteria..."
# ══════════════════════════════════════════════════════

cat > /etc/systemd/system/hysteria-server.service << 'HYSVCEOF'
[Unit]
Description=Hysteria2 Server (by RIXXX)
Documentation=https://v2.hysteria.network/
After=network.target network-online.target
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
Restart=always
RestartSec=5s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
HYSVCEOF

systemctl daemon-reload
systemctl enable hysteria-server >/dev/null 2>&1 || true

log "✅ Systemd сервис создан"

# ══════════════════════════════════════════════════════
step 7
log "▶ Запуск Hysteria2..."
# ══════════════════════════════════════════════════════

systemctl restart hysteria-server 2>&1 || true

for i in $(seq 1 15); do
  if systemctl is-active --quiet hysteria-server 2>/dev/null; then
    log "✅ Hysteria2 запущена (${i}с)"
    break
  fi
  sleep 1
  if [[ $i -eq 15 ]]; then
    log "⚠ Hy2 запускается медленно, см.: journalctl -u hysteria-server -n 30"
  fi
done

step DONE
log ""
log "╔════════════════════════════════════════════════════╗"
log "║   ✅ Hysteria2 успешно установлен!                 ║"
log "║   Домен: ${DOMAIN}"
log "║   hysteria2://****@${DOMAIN}:443?sni=${DOMAIN}"
log "╚════════════════════════════════════════════════════╝"
log ""

exit 0

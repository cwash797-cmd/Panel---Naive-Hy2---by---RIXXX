#!/bin/bash
# ═══════════════════════════════════════════════════════
#  Сетевой тюнинг (BBR + UDP buffers) — by RIXXX
#  Вызывается из панели кнопкой "Применить оптимизации"
# ═══════════════════════════════════════════════════════

set -uo pipefail

cat > /etc/sysctl.d/99-rixxx-tune.conf << 'SYSCTLEOF'
# by RIXXX — Naive (TCP) + Hy2 (UDP) tuning
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# UDP буферы для Hysteria2
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.rmem_default=2500000
net.core.wmem_default=2500000

# TCP Fast Open
net.ipv4.tcp_fastopen=3

# IPv6
net.ipv6.conf.all.disable_ipv6=0

# Connection tracking
net.netfilter.nf_conntrack_max=1048576
net.netfilter.nf_conntrack_tcp_timeout_established=3600
SYSCTLEOF

if sysctl --system >/dev/null 2>&1; then
  echo "OK: sysctl applied"

  # Проверяем BBR
  CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
  QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
  RMEM=$(sysctl -n net.core.rmem_max 2>/dev/null || echo "unknown")

  echo "congestion_control=${CC}"
  echo "qdisc=${QDISC}"
  echo "rmem_max=${RMEM}"
  exit 0
else
  echo "ERROR: sysctl failed"
  exit 1
fi

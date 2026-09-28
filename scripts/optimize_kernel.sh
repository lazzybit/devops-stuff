#!/bin/sh
#
# optimize_kernel.sh - apply the BBR + fq kernel tuning from the xray_server
# role (references/roles/xray_server/vars/main.yml).
#
# Run as root.

set -eu

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }

cat > /etc/sysctl.d/90-optimization.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
EOF

sysctl -p /etc/sysctl.d/90-optimization.conf

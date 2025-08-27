#!/usr/bin/env bash
set -euo pipefail

IFACE=${1:-wlan0}
IP=${2:-192.168.1.50}
CIDR=${3:-24}
GATEWAY=${4:-192.168.1.1}

echo "[+] Setting static IP ${IP}/${CIDR} on ${IFACE}"
sudo ip addr flush dev "$IFACE" || true
sudo ip addr add "${IP}/${CIDR}" dev "$IFACE"
sudo ip link set "$IFACE" up
sudo ip route replace default via "$GATEWAY"
echo "[+] Current IPs on ${IFACE}:"
ip addr show dev "$IFACE" | grep inet || true


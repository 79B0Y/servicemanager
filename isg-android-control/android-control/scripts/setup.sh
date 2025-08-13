#!/usr/bin/env bash
set -euo pipefail

echo "[+] Installing dependencies (Ubuntu/Proot)"
if command -v sudo >/dev/null 2>&1; then
  SUDO=sudo
else
  SUDO=""
fi
${SUDO} apt-get update
${SUDO} apt-get install -y adb mosquitto-clients redis-server python3-pip python3-venv

echo "[+] Creating virtualenv .venv"
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
echo "[+] Ensure scripts are executable"
chmod +x scripts/isg-android-control scripts/set_static_ip.sh scripts/install_termux_boot.sh || true

echo "[+] Done. Activate with: source .venv/bin/activate"

#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

SERVICE_ID="hass"
SERVICE_DIR="/data/data/com.termux/files/home/servicemanager/$SERVICE_ID"
LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/install.log"
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
HASS_VERSION="${HASS_VERSION:-2025.5.3}"

mkdir -p "$LOG_DIR"

mqtt_report() {
  local topic="$1"
  local payload="$2"
  mosquitto_pub -F "$SERVICE_DIR/configuration.yaml" -t "$topic" -m "$payload" || true
  echo "[MQTT] $topic -> $payload" >> "$LOG_FILE"
}

log() {
  echo "[$(date +%F %T)] $*" | tee -a "$LOG_FILE"
}

log "📦 Starting Home Assistant install: $HASS_VERSION"
mqtt_report "isg/install/$SERVICE_ID/status" '{"status":"installing"}'

proot-distro login "$PROOT_DISTRO" -- bash <<EOF
set -e

if [ -d /root/homeassistant ]; then
  echo "[INFO] Existing installation found, uninstalling..."
  exit 99
fi

apt update && apt install -y ffmpeg libturbojpeg
python3 -m venv /root/homeassistant
source /root/homeassistant/bin/activate
pip install --upgrade pip
pip install numpy mutagen pillow aiohttp_fast_zlib
pip install aiohttp==3.10.8 attrs==23.2.0 PyTurboJPEG
pip install homeassistant==${HASS_VERSION}

# 首次启动测试（后台启动）
hass &
PID=\$!

TRIES=0
while (( TRIES < 90 )); do
  if nc -z 127.0.0.1 8123; then
    echo "[INFO] Home Assistant started successfully."
    break
  fi
  sleep 10
  TRIES=\$((TRIES+1))
done

if (( TRIES >= 90 )); then
  echo "[ERROR] HA startup timed out."
  kill -9 \$PID || true
  exit 1
fi

kill -9 \$PID

# 压缩优化库
pip install zlib-ng isal --no-binary :all:

# 配置补丁
CONFIG="/root/.homeassistant/configuration.yaml"
grep -q '^logger:' "\$CONFIG" || echo -e '\nlogger:\n  default: critical' >> "\$CONFIG"
grep -q 'use_x_frame_options:' "\$CONFIG" || echo -e '\nhttp:\n  use_x_frame_options: false' >> "\$CONFIG"

VERSION=\$(hass --version)
echo "[INFO] Installed Home Assistant version: \$VERSION"
EOF

if [ \$? -eq 99 ]; then
  bash "$SERVICE_DIR/uninstall.sh"
  exec bash "$SERVICE_DIR/install.sh"
elif [ \$? -ne 0 ]; then
  mqtt_report "isg/install/$SERVICE_ID/status" '{"status":"failed","message":"Installation failed inside container."}'
  exit 1
fi

mqtt_report "isg/install/$SERVICE_ID/status" "\$(cat <<EOP
{
  \"service\": \"$SERVICE_ID\",
  \"status\": \"success\",
  \"version\": \"$HASS_VERSION\",
  \"log\": \"$LOG_FILE\",
  \"timestamp\": $(date +%s)
}
EOP
)"

log "✅ Install complete: Home Assistant $HASS_VERSION"
exit 0

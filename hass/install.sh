#!/data/data/com.termux/files/usr/bin/bash

# install.sh - Install Home Assistant into proot Ubuntu container and report via MQTT
# Path: /data/data/com.termux/files/home/servicemanager/hass/install.sh

SERVICE_ID="hass"
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
HASS_VERSION="${HASS_VERSION:-2025.5.3}"
BACKUP_DIR="/sdcard/isgbackup/$SERVICE_ID"
LOG_DIR="$BACKUP_DIR/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/install.log"
MAX_LINES=100

CONFIG_PATH="/data/data/com.termux/files/home/servicemanager/configuration.yaml"
MQTT_TOPIC="isg/install/$SERVICE_ID/status"

exec > >(tee -a "$LOG_FILE") 2>&1
# Trim to last 100 lines
tail -n $MAX_LINES "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"

echo "[INFO] Installing Home Assistant v$HASS_VERSION..."

# Load MQTT config
if ! python3 -c "import yaml" 2>/dev/null; then
  echo "[WARN] PyYAML not installed, using default MQTT config"
  MQTT_HOST="127.0.0.1"
  MQTT_PORT=1883
  MQTT_USERNAME=""
  MQTT_PASSWORD=""
else
  eval $(python3 -c "
import yaml
with open('$CONFIG_PATH') as f:
    mqtt = yaml.safe_load(f).get('mqtt', {})
    for k in ('host', 'port', 'username', 'password'):
        v = mqtt.get(k, '')
        print(f'MQTT_{k.upper()}=\"{v}\"')")
fi

mqtt_report() {
  local status=$1
  local extra=$2
  mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USERNAME" -P "$MQTT_PASSWORD" \
    -t "$MQTT_TOPIC" -m "{\"service\":\"$SERVICE_ID\",\"status\":\"$status\",$extra\"timestamp\":$(date +%s)}" -r -q 1 >/dev/null 2>&1
}

mqtt_report installing ""

proot-distro login "$PROOT_DISTRO" -- bash <<EOF
set -e

apt update && apt install -y ffmpeg libturbojpeg

python3 -m venv /root/homeassistant
source /root/homeassistant/bin/activate
pip install --upgrade pip
pip install numpy pillow mutagen aiohttp==3.10.8 attrs==23.2.0 PyTurboJPEG
pip install homeassistant==${HASS_VERSION}

nohup bash -c 'source /root/homeassistant/bin/activate && hass' > /root/hass_runtime.log 2>&1 &
for i in \$(seq 1 90); do
  sleep 60
  nc -z 127.0.0.1 8123 && break
done || exit 1

pkill -f hass || true

source /root/homeassistant/bin/activate
pip install zlib-ng isal --no-binary :all:

grep -q '^logger:' /root/.homeassistant/configuration.yaml || echo -e '\nlogger:\n  default: critical' >> /root/.homeassistant/configuration.yaml
grep -q 'use_x_frame_options:' /root/.homeassistant/configuration.yaml || echo -e '\nhttp:\n  use_x_frame_options: false' >> /root/.homeassistant/configuration.yaml
EOF

if [[ $? -eq 0 ]]; then
  VERSION_STR=$(proot-distro login "$PROOT_DISTRO" -- bash -c "source /root/homeassistant/bin/activate && hass --version")
  echo "[OK] Installation succeeded. Version: $VERSION_STR"
  mqtt_report success "\"version\":\"$VERSION_STR\",\"log\":\"$LOG_FILE\"," 
else
  echo "[ERROR] Installation failed"
  mqtt_report failed "\"error\":\"install_failed\",\"message\":\"Installation process failed.\",\"log\":\"$LOG_FILE\"," 
  exit 1
fi

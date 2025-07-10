#!/data/data/com.termux/files/usr/bin/bash

# update.sh - Upgrade or downgrade Home Assistant to specified version
# Path: /data/data/com.termux/files/home/servicemanager/hass/update.sh

SERVICE_ID="hass"
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
BACKUP_DIR="/sdcard/isgbackup/$SERVICE_ID"
LOG_DIR="$BACKUP_DIR/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/update.log"
MAX_LINES=100

CONFIG_PATH="/data/data/com.termux/files/home/servicemanager/configuration.yaml"
TARGET_VERSION="${1:-$TARGET_VERSION}"

if [[ -z "$TARGET_VERSION" ]]; then
  echo "[USAGE] bash update.sh <version>"
  echo "        or export TARGET_VERSION=<version> && bash update.sh"
  echo "[ERROR] TARGET_VERSION not provided."
  exit 1
fi

exec > >(tee -a "$LOG_FILE") 2>&1

# Trim log to latest 100 lines
tail -n $MAX_LINES "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"

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

MQTT_TOPIC="isg/update/$SERVICE_ID/status"

mqtt_report() {
  local status=$1
  local extra=$2
  mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USERNAME" -P "$MQTT_PASSWORD" \
    -t "$MQTT_TOPIC" -m "{\"service\":\"$SERVICE_ID\",\"status\":\"$status\",\"version\":\"$TARGET_VERSION\",$extra\"timestamp\":$(date +%s)}" -r -q 1 >/dev/null 2>&1
}

mqtt_report updating "\"log\":\"$LOG_FILE\"," 

# Stop service
bash ./stop.sh

# Install target version
proot-distro login "$PROOT_DISTRO" -- bash -c "\
  source /root/homeassistant/bin/activate && \
  pip install --upgrade --no-cache-dir homeassistant==$TARGET_VERSION"

if [[ $? -ne 0 ]]; then
  echo "[ERROR] pip install failed"
  mqtt_report failed "\"error\":\"pip_failed\",\"message\":\"Failed to install Home Assistant version $TARGET_VERSION.\",\"log\":\"$LOG_FILE\"," 
  exit 1
fi

# Restart service
bash ./start.sh

mqtt_report success "\"log\":\"$LOG_FILE\","

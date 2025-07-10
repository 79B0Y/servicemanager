#!/data/data/com.termux/files/usr/bin/bash

# stop.sh - Stop Home Assistant and report status via MQTT
# Path: /data/data/com.termux/files/home/servicemanager/hass/stop.sh

SERVICE_ID="hass"
LSVDIR="/data/data/com.termux/files/usr/var/service"
CONFIG_PATH="/data/data/com.termux/files/home/servicemanager/configuration.yaml"
BACKUP_DIR="/sdcard/isgbackup/$SERVICE_ID"
LOG_FILE="$BACKUP_DIR/stop_$(date +%Y%m%d-%H%M%S).log"
STOP_LOG="$BACKUP_DIR/hass_stoptime.log"
MQTT_TOPIC="isg/run/$SERVICE_ID/status"
MAX_TRIES=30
DISABLED_FLAG=".disabled"

mkdir -p "$BACKUP_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "[INFO] Stopping Home Assistant..."

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
  local payload="{\"status\":\"$status\"}"
  mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USERNAME" -P "$MQTT_PASSWORD" \
    -t "$MQTT_TOPIC" -m "$payload" -r -q 1 >/dev/null 2>&1
}

mqtt_report stoping

echo d > "$LSVDIR/$SERVICE_ID/supervise/control"
echo "[INFO] Stop signal sent, waiting for confirmation..."

for ((i=0; i<MAX_TRIES; i++)); do
  sleep 10
  if ! bash ./status.sh --quiet >/dev/null; then
    touch "$DISABLED_FLAG"
    mqtt_report stopped
    echo "[OK] Home Assistant stopped"
    echo "[INFO] Stop log: $STOP_LOG"
    exit 0
  fi
done

echo "[ERROR] Failed to stop Home Assistant"
mqtt_report failed
exit 1

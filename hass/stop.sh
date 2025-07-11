#!/data/data/com.termux/files/usr/bin/bash
# stop.sh  v1.4  —  Home Assistant stop (hard-coded control fallback)
set -Eeuo pipefail
trap 'echo "[ERROR] line $LINENO: command failed." | tee -a "$LOG_FILE"' ERR

SERVICE_ID="hass"
SERVICE_DIR="/data/data/com.termux/files/home/servicemanager/$SERVICE_ID"
CONFIG_FILE="/data/data/com.termux/files/home/servicemanager/configuration.yaml"
LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/stop.log"
DISABLED_FLAG="$SERVICE_DIR/.disabled"
MAX_TRIES=30
CONTROL_FILE="/data/data/com.termux/files/usr/var/service/hass/supervise/control"

mkdir -p "$LOG_DIR"

load_mqtt_conf() {
  MQTT_HOST=$(grep -Po '^[[:space:]]*host:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1)
  MQTT_PORT=$(grep -Po '^[[:space:]]*port:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1)
  MQTT_USER=$(grep -Po '^[[:space:]]*username:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1)
  MQTT_PASS=$(grep -Po '^[[:space:]]*password:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1)
}

mqtt_report() {
  local topic="$1" payload="$2"
  load_mqtt_conf
  mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload" || true
  echo "[MQTT] $topic -> $payload" >> "$LOG_FILE"
}

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }

log "🛑 stop.sh invoked — CTRL file: $CONTROL_FILE"
mqtt_report "isg/run/$SERVICE_ID/status" '{"status":"stoping"}'

# 1) send stop signal
if [ -e "$CONTROL_FILE" ]; then
  echo d > "$CONTROL_FILE"
  log "Sent 'd' to $CONTROL_FILE"
else
  log "⚠️ control file not found; fallback to pkill"
  pkill -f '[h]omeassistant' || true
fi

# 2) wait for exit
TRIES=0
while (( TRIES < MAX_TRIES )); do
  if ! bash "$SERVICE_DIR/status.sh" --quiet; then break; fi
  sleep 5; TRIES=$((TRIES+1))
done

if bash "$SERVICE_DIR/status.sh" --quiet; then
  log "❌ Service still running after $((MAX_TRIES*5)) seconds"
  mqtt_report "isg/run/$SERVICE_ID/status" '{"status":"failed","message":"Still running after stop."}'
  exit 1
fi

touch "$DISABLED_FLAG"
log "✅ Stopped. .disabled created."
mqtt_report "isg/run/$SERVICE_ID/status" '{"status":"stoped","message":"Service stopped and .disabled set."}'
exit 0

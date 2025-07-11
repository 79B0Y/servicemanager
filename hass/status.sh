#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

SERVICE_ID="hass"
SERVICE_DIR="/data/data/com.termux/files/home/servicemanager/$SERVICE_ID"
CONFIG_FILE="/data/data/com.termux/files/home/servicemanager/configuration.yaml"
LOG_FILE="$SERVICE_DIR/logs/status.log"
PORT=8123

mkdir -p "$(dirname "$LOG_FILE")"

# ------------ MQTT config helper ------------
load_mqtt_conf() {
  MQTT_HOST=$(grep -E "^[[:space:]]*host:" "$CONFIG_FILE" | awk '{print $2}')
  MQTT_PORT=$(grep -E "^[[:space:]]*port:" "$CONFIG_FILE" | awk '{print $2}')
  MQTT_USER=$(grep -E "^[[:space:]]*username:" "$CONFIG_FILE" | awk '{print $2}')
  MQTT_PASS=$(grep -E "^[[:space:]]*password:" "$CONFIG_FILE" | awk '{print $2}')
}

mqtt_report() {
  local topic="$1"; shift
  local payload="$1"
  load_mqtt_conf
  mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload" || true
  echo "[MQTT] $topic -> $payload" >> "$LOG_FILE"
}

log() {
  echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"
}

PID=$(pgrep -f '[h]omeassistant' || true)
RUNTIME=""

if [ -n "$PID" ]; then
  RUNTIME=$(ps -o etime= -p "$PID" | xargs)
  if nc -z 127.0.0.1 $PORT >/dev/null 2>&1; then
    STATUS="running"
    EXIT=0
  else
    STATUS="starting"
    EXIT=2
  fi
else
  STATUS="stopped"
  EXIT=1
fi

case "${1:-}" in
  --json)
    echo "{\"status\":\"$STATUS\",\"pid\":\"$PID\",\"runtime\":\"$RUNTIME\"}"
    exit $EXIT
    ;;
  --quiet)
    exit $EXIT
    ;;
  *)
    ;;
esac

TS=$(date +%s)
if [ "$STATUS" = "running" ]; then
  mqtt_report "isg/status/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"running\",\"pid\":$PID,\"runtime\":\"$RUNTIME\",\"port\":true,\"timestamp\":$TS}"
  log "✅ Home Assistant running (PID=$PID, uptime=$RUNTIME)"
elif [ "$STATUS" = "starting" ]; then
  mqtt_report "isg/status/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"starting\",\"pid\":$PID,\"runtime\":\"$RUNTIME\",\"port\":false,\"timestamp\":$TS}"
  log "⏳ Home Assistant starting (PID=$PID)"
else
  mqtt_report "isg/status/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"stopped\",\"message\":\"Home Assistant not running\",\"timestamp\":$TS}"
  log "🛑 Home Assistant not running"
fi

exit $EXIT

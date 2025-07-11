#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

SERVICE_ID="hass"
SERVICE_DIR="/data/data/com.termux/files/home/servicemanager/$SERVICE_ID"
LOG_FILE="$SERVICE_DIR/logs/status.log"
PORT=8123

mkdir -p "$(dirname "$LOG_FILE")"

MQTT_TOPIC="isg/status/$SERVICE_ID/status"

mqtt_report() {
  local topic="$1"
  local payload="$2"
  mosquitto_pub -F "$SERVICE_DIR/configuration.yaml" -t "$topic" -m "$payload" || true
  echo "[MQTT] $topic -> $payload" >> "$LOG_FILE"
}

log() {
  echo "[$(date +%F %T)] $*" | tee -a "$LOG_FILE"
}

PID=$(pgrep -f '[h]omeassistant' || true)

if [ -n "$PID" ]; then
  RUNTIME=$(ps -o etime= -p "$PID" | xargs)
  if nc -z 127.0.0.1 $PORT >/dev/null 2>&1; then
    STATUS="running"
    EXIT_CODE=0
  else
    STATUS="starting"
    EXIT_CODE=2
  fi
else
  STATUS="stopped"
  EXIT_CODE=1
fi

# 处理输出选项
if [[ "${1:-}" == "--json" ]]; then
  echo "{\"status\":\"$STATUS\",\"pid\":\"$PID\",\"runtime\":\"$RUNTIME\"}"
  exit $EXIT_CODE
elif [[ "${1:-}" == "--quiet" ]]; then
  exit $EXIT_CODE
fi

# 默认输出 + MQTT 上报
TIMESTAMP=$(date +%s)
if [ "$STATUS" = "running" ]; then
  mqtt_report "$MQTT_TOPIC" "{\"service\":\"$SERVICE_ID\",\"status\":\"running\",\"pid\":$PID,\"runtime\":\"$RUNTIME\",\"port\":true,\"timestamp\":$TIMESTAMP}"
  log "✅ Home Assistant is running (PID=$PID, uptime=$RUNTIME)"
elif [ "$STATUS" = "starting" ]; then
  mqtt_report "$MQTT_TOPIC" "{\"service\":\"$SERVICE_ID\",\"status\":\"starting\",\"pid\":$PID,\"runtime\":\"$RUNTIME\",\"port\":false,\"timestamp\":$TIMESTAMP}"
  log "⏳ Home Assistant process exists but port not ready (PID=$PID)"
else
  mqtt_report "$MQTT_TOPIC" "{\"service\":\"$SERVICE_ID\",\"status\":\"stopped\",\"message\":\"Home Assistant is not running.\",\"timestamp\":$TIMESTAMP}"
  log "🛑 Home Assistant is not running."
fi

exit $EXIT_CODE

#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

SERVICE_ID="hass"
SERVICE_DIR="/data/data/com.termux/files/home/servicemanager/$SERVICE_ID"
LOG_FILE="$SERVICE_DIR/logs/stop.log"
LSVDIR="/data/data/com.termux/files/usr/var/lib/runsv"
DISABLED_FLAG="$SERVICE_DIR/.disabled"
MAX_TRIES=30

mkdir -p "$(dirname "$LOG_FILE")"

mqtt_report() {
  local topic="$1"
  local payload="$2"
  mosquitto_pub -F "$SERVICE_DIR/configuration.yaml" -t "$topic" -m "$payload" || true
  echo "[MQTT] $topic -> $payload" >> "$LOG_FILE"
}

log() {
  echo "[$(date +%F %T)] $*" | tee -a "$LOG_FILE"
}

log "🛑 Sending stop signal to Home Assistant"
echo d > "$LSVDIR/$SERVICE_ID/supervise/control" || true
mqtt_report "isg/run/$SERVICE_ID/status" '{"status": "stoping"}'

TRIES=0
while (( TRIES < MAX_TRIES )); do
  if bash "$SERVICE_DIR/status.sh" --quiet; then
    sleep 10
  else
    break
  fi
  TRIES=$((TRIES+1))
done

if bash "$SERVICE_DIR/status.sh" --quiet; then
  mqtt_report "isg/run/$SERVICE_ID/status" '{"status": "failed", "message": "Service is still running after stop attempt."}'
  log "❌ Failed to stop Home Assistant."
  exit 1
else
  touch "$DISABLED_FLAG"
  mqtt_report "isg/run/$SERVICE_ID/status" '{"status": "stoped", "message": "Service stopped and .disabled flag set."}'
  log "✅ Service stopped and .disabled created."
  exit 0
fi

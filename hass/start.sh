#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

SERVICE_ID="hass"
SERVICE_DIR="/data/data/com.termux/files/home/servicemanager/$SERVICE_ID"
LOG_FILE="$SERVICE_DIR/logs/start.log"
LSVDIR="/data/data/com.termux/files/usr/var/lib/runsv"
MAX_TRIES=30
DISABLED_FLAG="$SERVICE_DIR/.disabled"

mkdir -p "$(dirname "$LOG_FILE")"

mqtt_report() {
  local topic="$1"
  local payload="$2"
  mosquitto_pub -F "$SERVICE_DIR/configuration.yaml" -t "$topic" -m "$payload" || true
  echo "[MQTT] $topic -> $payload" >> "$LOG_FILE"
}

log() {
  echo "[$(date +%F\ %T)] $*" | tee -a "$LOG_FILE"
}

log "🚀 Starting Home Assistant via isgservicemonitor"
mqtt_report "isg/run/$SERVICE_ID/status" '{"status": "starting"}'

# 移除 disabled 标志
if [ -f "$DISABLED_FLAG" ]; then
  rm -f "$DISABLED_FLAG"
  log "🧹 Removed .disabled flag before starting."
fi

# 启动服务
echo u > "$LSVDIR/$SERVICE_ID/supervise/control" || true

# 状态检测
TRIES=0
while (( TRIES < MAX_TRIES )); do
  if bash "$SERVICE_DIR/status.sh" --quiet; then
    mqtt_report "isg/run/$SERVICE_ID/status" '{"status": "running"}'
    log "✅ Service is running."
    exit 0
  fi
  sleep 10
  TRIES=$((TRIES+1))
done

# 恢复 .disabled
log "❌ Service failed to start. Restoring .disabled flag."
touch "$DISABLED_FLAG"
mqtt_report "isg/run/$SERVICE_ID/status" '{"status": "failed", "message": "Service failed to reach running state."}'
exit 1

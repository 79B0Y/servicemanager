#!/data/data/com.termux/files/usr/bin/bash
# start.sh  —  Start Home Assistant with fixed control path & MQTT conf
set -Eeuo pipefail

SERVICE_ID="hass"
SERVICE_DIR="/data/data/com.termux/files/home/servicemanager/$SERVICE_ID"
CONFIG_FILE="/data/data/com.termux/files/home/servicemanager/configuration.yaml"
LOG_FILE="$SERVICE_DIR/logs/start.log"
DISABLED_FLAG="$SERVICE_DIR/.disabled"
MAX_TRIES=30
CONTROL_FILE="/data/data/com.termux/files/usr/var/service/hass/supervise/control"

mkdir -p "$(dirname "$LOG_FILE")"

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

log() {
  echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"
}

log "🚀 Starting Home Assistant"
mqtt_report "isg/run/$SERVICE_ID/status" '{"status":"starting"}'

# 移除 .disabled
if [ -f "$DISABLED_FLAG" ]; then
  rm -f "$DISABLED_FLAG"
  log "🧹 .disabled flag removed."
fi

# 启动服务
if [ -e "$CONTROL_FILE" ]; then
  echo u > "$CONTROL_FILE"
  log "Sent 'u' to $CONTROL_FILE"
else
  log "⚠️ control file not found; cannot start"
  mqtt_report "isg/run/$SERVICE_ID/status" '{"status":"failed","message":"supervise control file not found"}'
  exit 1
fi

# 等待服务进入 running
TRIES=0
while (( TRIES < MAX_TRIES )); do
  if bash "$SERVICE_DIR/status.sh" --quiet; then
    mqtt_report "isg/run/$SERVICE_ID/status" '{"status":"running"}'
    log "✅ Service is running."
    exit 0
  fi
  sleep 5; TRIES=$((TRIES+1))
done

# 启动失败：恢复 .disabled
log "❌ Service failed to start in time. Restoring .disabled."
touch "$DISABLED_FLAG"
mqtt_report "isg/run/$SERVICE_ID/status" '{"status":"failed","message":"Service failed to reach running state."}'
exit 1

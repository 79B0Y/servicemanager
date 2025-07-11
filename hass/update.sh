#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

SERVICE_ID="hass"
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
SERVICE_DIR="/data/data/com.termux/files/home/servicemanager/$SERVICE_ID"
CONFIG_FILE="/data/data/com.termux/files/home/servicemanager/configuration.yaml"
LOG_FILE="$SERVICE_DIR/logs/update.log"
VERSION_FILE="$SERVICE_DIR/VERSION"
START_TIME=$(date +%s)

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

if [ -z "${TARGET_VERSION:-}" ]; then
  echo "[ERROR] TARGET_VERSION not set. Abort."
  mqtt_report "isg/update/$SERVICE_ID/status" '{"status":"failed","message":"Missing TARGET_VERSION."}'
  exit 1
fi

log "⬆️ Starting update of Home Assistant to version $TARGET_VERSION"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"timestamp\":$(date +%s)}"

# 执行升级操作
proot-distro login "$PROOT_DISTRO" -- bash -c "
  source /root/homeassistant/bin/activate
  python -m ensurepip --upgrade 2>&1 | tee /tmp/update_step_ensurepip.log
  pip install --upgrade pip 2>&1 | tee /tmp/update_step_pip.log
  pip install --upgrade \"homeassistant==$TARGET_VERSION\" 2>&1 | tee /tmp/update_step_ha.log
  hass --version > /tmp/hass_version.txt
"

# 上报每步日志内容到 MQTT
for step in ensurepip pip ha; do
  LOG_PATH="/data/data/com.termux/files/usr/tmp/update_step_${step}.log"
  [ -f "$LOG_PATH" ] && tail -n 100 "$LOG_PATH" | mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "isg/update/$SERVICE_ID/status/$step" -l || true
  cat "$LOG_PATH" >> "$LOG_FILE" 2>/dev/null || true
  rm -f "$LOG_PATH"
done

# 验证版本是否一致
UPDATED_VERSION=$(proot-distro login "$PROOT_DISTRO" -- bash -c "cat /tmp/hass_version.txt" | head -n1 | tr -d '\r')
if [ "$UPDATED_VERSION" != "$TARGET_VERSION" ]; then
  log "❌ Version mismatch: expected $TARGET_VERSION but got $UPDATED_VERSION"
  mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"Version mismatch after update. Got $UPDATED_VERSION\"}"
  exit 1
fi

# 重启服务
bash "$SERVICE_DIR/stop.sh"
sleep 5
bash "$SERVICE_DIR/start.sh"

# 等待最长 300 秒检测是否启动成功
MAX_WAIT=300
INTERVAL=5
WAITED=0
log "⏳ Waiting for Home Assistant to start..."
while [ "$WAITED" -lt "$MAX_WAIT" ]; do
  if bash "$SERVICE_DIR/status.sh" --quiet; then
    log "✅ Service is running after ${WAITED}s"
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    mqtt_report "isg/update/$SERVICE_ID/status" "$(cat <<EOF
{
  "service": "$SERVICE_ID",
  "status": "success",
  "version": "$TARGET_VERSION",
  "duration": $DURATION,
  "timestamp": $END_TIME
}
EOF
)"
    exit 0
  fi
  sleep "$INTERVAL"
  WAITED=$((WAITED + INTERVAL))
done

log "❌ Timeout: service not running after ${MAX_WAIT}s"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"Timeout waiting for service start.\",\"timestamp\":$(date +%s)}"
exit 1

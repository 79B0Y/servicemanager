#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

SERVICE_ID="hass"
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
HA_DIR="${HA_DIR:-/root/.homeassistant}"
BACKUP_DIR="${BACKUP_DIR:-/sdcard/isgbackup/$SERVICE_ID}"
CUSTOM_BACKUP_FILE="${RESTORE_FILE:-}"  # 可选：外部指定备份文件路径
SERVICE_DIR="/data/data/com.termux/files/home/servicemanager/$SERVICE_ID"
CONFIG_FILE="/data/data/com.termux/files/home/servicemanager/configuration.yaml"
LOG_FILE="$SERVICE_DIR/logs/restore.log"

mkdir -p "$(dirname "$LOG_FILE")"

START_TIME=$(date +%s)

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

# ----------- 确定恢复文件 --------------
if [ -n "$CUSTOM_BACKUP_FILE" ]; then
  RESTORE_FILE="$CUSTOM_BACKUP_FILE"
else
  RESTORE_FILE=$(ls -1t "$BACKUP_DIR"/homeassistant_backup_*.tar.gz 2>/dev/null | head -n1 || true)
  if [ -z "$RESTORE_FILE" ]; then
    RESTORE_FILE="$BACKUP_DIR/homeassistant_original.tar.gz"
  fi
fi

log "♻️ Starting restore from: $RESTORE_FILE"
mqtt_report "isg/restore/$SERVICE_ID/status" '{"status":"running"}'

if [ -z "$RESTORE_FILE" ] || [ ! -f "$RESTORE_FILE" ]; then
  log "❌ Restore file not found. Abort."
  mqtt_report "isg/restore/$SERVICE_ID/status" '{"status":"failed","message":"Restore file not found."}'
  exit 1
fi

BASENAME=$(basename -- "$RESTORE_FILE")
EXT="${BASENAME##*.}"
EXT_LOWER=$(echo "$EXT" | tr '[:upper:]' '[:lower:]')
TEMP_DIR="/data/data/com.termux/files/usr/tmp/restore_temp"

if [[ "$BASENAME" != *.tar.gz ]]; then
  if [[ "$EXT_LOWER" == "zip" ]]; then
    log "📦 Detected zip file, converting to tar.gz..."
    rm -rf "$TEMP_DIR" && mkdir -p "$TEMP_DIR"
    unzip -q "$RESTORE_FILE" -d "$TEMP_DIR"
    RESTORE_FILE="$BACKUP_DIR/homeassistant_converted_$(date +%s).tar.gz"
    tar -czf "$RESTORE_FILE" -C "$TEMP_DIR" .
    log "✅ Converted zip to: $RESTORE_FILE"
  else
    log "❌ Unsupported file format: $EXT"
    mqtt_report "isg/restore/$SERVICE_ID/status" '{"status":"failed","message":"Unsupported file format."}'
    exit 1
  fi
fi

# ----------- 执行恢复 --------------
if proot-distro login "$PROOT_DISTRO" -- bash -c "rm -rf \"$HA_DIR\" && mkdir -p \"$HA_DIR\" && tar -xzf \"$RESTORE_FILE\" -C \"$(dirname $HA_DIR)\""; then
  log "✅ Restore completed, restarting service..."
  mqtt_report "isg/restore/$SERVICE_ID/status" '{"status":"restarting"}'
  bash "$SERVICE_DIR/stop.sh"
  sleep 5
  bash "$SERVICE_DIR/start.sh"
  sleep 5
  if bash "$SERVICE_DIR/status.sh" --quiet; then
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    SIZE_KB=$(du -k "$RESTORE_FILE" | awk '{print $1}')
    mqtt_report "isg/restore/$SERVICE_ID/status" "$(cat <<EOF
{
  "service": "$SERVICE_ID",
  "status": "success",
  "file": "$RESTORE_FILE",
  "size_kb": $SIZE_KB,
  "duration": $DURATION,
  "log": "$LOG_FILE",
  "timestamp": $END_TIME
}
EOF
)"
    log "✅ Restore + restart complete: $RESTORE_FILE ($SIZE_KB KB, ${DURATION}s)"
  else
    log "❌ Restore succeeded but service did not start."
    mqtt_report "isg/restore/$SERVICE_ID/status" '{"status":"failed","message":"Service not running after restore."}'
    exit 1
  fi
else
  mqtt_report "isg/restore/$SERVICE_ID/status" '{"status":"failed","message":"Restore failed inside proot."}'
  log "❌ Restore failed inside proot"
  exit 1
fi

exit 0

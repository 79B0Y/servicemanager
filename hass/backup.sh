#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

SERVICE_ID="hass"
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
HA_DIR="${HA_DIR:-/root/.homeassistant}"
BACKUP_DIR="${BACKUP_DIR:-/sdcard/isgbackup/$SERVICE_ID}"
KEEP_BACKUPS="${KEEP_BACKUPS:-3}"
SERVICE_DIR="/data/data/com.termux/files/home/servicemanager/$SERVICE_ID"
CONFIG_FILE="/data/data/com.termux/files/home/servicemanager/configuration.yaml"
LOG_FILE="$SERVICE_DIR/logs/backup.log"
TS=$(date +%Y%m%d-%H%M%S)
DST="$BACKUP_DIR/homeassistant_backup_${TS}.tar.gz"
START_TIME=$(date +%s)

mkdir -p "$BACKUP_DIR"
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

log "📦 Starting backup: $DST"
mqtt_report "isg/backup/$SERVICE_ID/status" '{"status":"backuping"}'

if ! bash "$SERVICE_DIR/status.sh" --quiet; then
  log "❌ Home Assistant not running. Abort."
  mqtt_report "isg/backup/$SERVICE_ID/status" '{"status":"failed","message":"Service not running."}'
  exit 1
fi

if proot-distro login "$PROOT_DISTRO" -- bash -c "tar -czf \"$DST\" -C \"$(dirname $HA_DIR)\" \"$(basename $HA_DIR)\""; then
  END_TIME=$(date +%s)
  SIZE_KB=$(du -k "$DST" | awk '{print $1}')
  DURATION=$((END_TIME - START_TIME))
  mqtt_report "isg/backup/$SERVICE_ID/status" "$(cat <<EOF
{
  "service": "$SERVICE_ID",
  "status": "success",
  "file": "$DST",
  "size_kb": $SIZE_KB,
  "duration": $DURATION,
  "log": "$LOG_FILE",
  "timestamp": $END_TIME
}
EOF
)"
  log "✅ Backup complete: $DST ($SIZE_KB KB, ${DURATION}s)"
else
  mqtt_report "isg/backup/$SERVICE_ID/status" '{"status":"failed","message":"Tar failed inside container."}'
  log "❌ tar command failed in proot"
  exit 1
fi

# 清理旧备份
log "🧹 Checking old backups..."
ls -1t "$BACKUP_DIR"/homeassistant_backup_*.tar.gz 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)) | while read -r old; do
  log "🗑️ Removing old backup: $old"
  rm -f "$old"
done

exit 0

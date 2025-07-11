#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

SERVICE_ID="hass"
SERVICE_DIR="/data/data/com.termux/files/home/servicemanager/$SERVICE_ID"
LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/backup.log"
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
HA_DIR="/root/.homeassistant"
BACKUP_DIR="${BACKUP_DIR:-/sdcard/isgbackup/$SERVICE_ID}"
KEEP_BACKUPS="${KEEP_BACKUPS:-3}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_FILE="$BACKUP_DIR/homeassistant_backup_${TIMESTAMP}.tar.gz"

mkdir -p "$LOG_DIR" "$BACKUP_DIR"

mqtt_report() {
  local topic="$1"
  local payload="$2"
  mosquitto_pub -F "$SERVICE_DIR/configuration.yaml" -t "$topic" -m "$payload" || true
  echo "[MQTT] $topic -> $payload" >> "$LOG_FILE"
}

log() {
  echo "[$(date +%F\ %T)] $*" | tee -a "$LOG_FILE"
}

log "🔍 Checking Home Assistant running state..."
if ! bash "$SERVICE_DIR/status.sh" --quiet; then
  log "⚠️ Home Assistant is not running. Abort backup."
  mqtt_report "isg/backup/$SERVICE_ID/status" '{"status":"failed","message":"Home Assistant not running."}'
  exit 1
fi

mqtt_report "isg/status/$SERVICE_ID/status" '{"status":"running"}'
log "📦 Starting backup..."
mqtt_report "isg/backup/$SERVICE_ID/status" '{"status":"backuping"}'

START=$(date +%s)
proot-distro login "$PROOT_DISTRO" -- bash -c "tar -czf \"$BACKUP_FILE\" -C /root .homeassistant"
END=$(date +%s)

if [ ! -f "$BACKUP_FILE" ]; then
  log "❌ Backup failed: file not created"
  mqtt_report "isg/backup/$SERVICE_ID/status" '{"status":"failed","message":"Backup file creation failed."}'
  exit 1
fi

SIZE_KB=$(du -k "$BACKUP_FILE" | cut -f1)
DURATION=$((END - START))

mqtt_report "isg/backup/$SERVICE_ID/status" "$(cat <<EOF
{
  \"service\": \"$SERVICE_ID\",
  \"status\": \"success\",
  \"file\": \"$BACKUP_FILE\",
  \"size_kb\": $SIZE_KB,
  \"duration\": $DURATION,
  \"log\": \"$LOG_FILE\",
  \"timestamp\": $(date +%s)
}
EOF
)"

log "✅ Backup complete: $BACKUP_FILE ($SIZE_KB KB, $DURATION s)"

# 自动清理旧备份
log "🧹 Cleaning old backups..."
ls -tp "$BACKUP_DIR"/homeassistant_backup_*.tar.gz 2>/dev/null | grep -v '/$' | tail -n +$((KEEP_BACKUPS + 1)) | xargs -r rm -f
log "🧽 Cleanup done."

exit 0

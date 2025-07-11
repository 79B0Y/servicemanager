#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

SERVICE_ID="hass"
SERVICE_DIR="/data/data/com.termux/files/home/servicemanager/$SERVICE_ID"
LOG_FILE="$SERVICE_DIR/logs/restore.log"
BACKUP_DIR="${BACKUP_DIR:-/sdcard/isgbackup/$SERVICE_ID}"
RESTORE_FILE="${RESTORE_FILE:-}"  # 可选外部传入
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"

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

log "🧪 Start restore process"
mqtt_report "isg/restore/$SERVICE_ID/status" '{"status":"running"}'
mqtt_report "isg/restore/$SERVICE_ID/status" '{"status":"restoring"}'

# Step 1: 备份当前数据
log "📦 Backing up current data..."
bash "$SERVICE_DIR/backup.sh" || log "⚠️ Backup failed before restore, continuing..."

# Step 2: 确定还原文件
if [ -z "$RESTORE_FILE" ]; then
  RESTORE_FILE=$(ls -t "$BACKUP_DIR"/homeassistant_backup_*.tar.gz 2>/dev/null | head -n 1 || true)
fi

if [ ! -f "$RESTORE_FILE" ]; then
  log "❌ No backup file found to restore."
  mqtt_report "isg/restore/$SERVICE_ID/status" '{"status":"failed","message":"No backup file found."}'
  exit 1
fi

EXT="${RESTORE_FILE##*.}"
if [ "$EXT" != "gz" ]; then
  log "📦 Detected non-tar.gz format, attempting to re-compress"
  TMP_DIR="/tmp/restore_$SERVICE_ID"
  rm -rf "$TMP_DIR" && mkdir -p "$TMP_DIR"
  unzip "$RESTORE_FILE" -d "$TMP_DIR"
  RESTORE_FILE="$BACKUP_DIR/recompressed_$(date +%s).tar.gz"
  tar -czf "$RESTORE_FILE" -C "$TMP_DIR" .
  rm -rf "$TMP_DIR"
fi

log "🛑 Stopping service before restore..."
bash "$SERVICE_DIR/stop.sh" || log "⚠️ Stop failed, continuing..."

log "🧹 Cleaning old config..."
proot-distro login "$PROOT_DISTRO" -- rm -rf /root/.homeassistant

log "📦 Restoring from $RESTORE_FILE..."
proot-distro login "$PROOT_DISTRO" -- tar -xzf "$RESTORE_FILE" -C /root

log "🚀 Restarting service..."
bash "$SERVICE_DIR/start.sh"

mqtt_report "isg/restore/$SERVICE_ID/status" "$(cat <<EOF
{
  \"service\": \"$SERVICE_ID\",
  \"status\": \"success\",
  \"file\": \"$RESTORE_FILE\",
  \"log\": \"$LOG_FILE\",
  \"timestamp\": $(date +%s)
}
EOF
)"

log "✅ Restore completed"
exit 0

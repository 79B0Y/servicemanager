#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Zigbee2MQTT 备份脚本
# 版本: v1.1.0
# 功能: 备份 Zigbee2MQTT 配置和数据
# =============================================================================

set -euo pipefail

# 加载统一路径定义
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common_paths.sh" || {
    echo "Error: Cannot load common paths"
    exit 1
}

# 设置脚本特定的日志文件
LOG_FILE="$LOG_FILE_BACKUP"

# 确保必要目录存在
ensure_directories

TS=$(date +%Y%m%d-%H%M%S)
DST="$BACKUP_DIR/zigbee2mqtt_backup_${TS}.tar.gz"
START_TIME=$(date +%s)

log "starting zigbee2mqtt backup process"
mqtt_report "isg/backup/$SERVICE_ID/status" "{\"status\":\"backuping\",\"message\":\"starting backup process\",\"timestamp\":$(date +%s)}"

# -----------------------------------------------------------------------------
# 检查服务是否在运行（备份时强制要求服务运行）
# -----------------------------------------------------------------------------
if ! bash "$SERVICE_DIR/status.sh" --quiet; then
    log "zigbee2mqtt not running, backup skipped"
    mqtt_report "isg/backup/$SERVICE_ID/status" "{\"status\":\"skipped\",\"message\":\"service not running - backup skipped\",\"timestamp\":$(date +%s)}"
    exit 0
fi

log "zigbee2mqtt is running, proceeding with backup"

# -----------------------------------------------------------------------------
# 执行备份
# -----------------------------------------------------------------------------
log "creating archive: $DST"
mqtt_report "isg/backup/$SERVICE_ID/status" "{\"status\":\"backuping\",\"message\":\"creating archive\",\"timestamp\":$(date +%s)}"

if proot-distro login "$PROOT_DISTRO" -- bash -c "tar -czf \"$DST\" -C \"$(dirname $Z2M_DATA_DIR)\" \"$(basename $Z2M_DATA_DIR)\""; then
    END_TIME=$(date +%s)
    SIZE_KB=$(du -k "$DST" | awk '{print $1}')
    DURATION=$((END_TIME - START_TIME))
    
    log "backup completed: $DST ($SIZE_KB KB, ${DURATION}s)"
    mqtt_report "isg/backup/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"success\",\"file\":\"$DST\",\"size_kb\":$SIZE_KB,\"duration\":$DURATION,\"message\":\"backup completed successfully\",\"timestamp\":$END_TIME}"
else
    log "tar command failed in proot container"
    mqtt_report "isg/backup/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"tar command failed inside container\",\"timestamp\":$(date +%s)}"
    exit 1
fi

# -----------------------------------------------------------------------------
# 清理旧备份 - 保留最近的指定数量
# -----------------------------------------------------------------------------
log "cleaning old backups (keeping latest $KEEP_BACKUPS)"
OLD_BACKUPS=$(ls -1t "$BACKUP_DIR"/zigbee2mqtt_backup_*.tar.gz 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)) || true)

if [ -n "$OLD_BACKUPS" ]; then
    echo "$OLD_BACKUPS" | while read -r old_file; do
        if [ -f "$old_file" ]; then
            log "removing old backup: $(basename "$old_file")"
            rm -f "$old_file"
        fi
    done
    REMOVED_COUNT=$(echo "$OLD_BACKUPS" | wc -l)
    log "removed $REMOVED_COUNT old backup(s)"
else
    log "no old backups to remove"
fi

# 显示当前备份文件列表
CURRENT_BACKUPS=$(ls -1t "$BACKUP_DIR"/zigbee2mqtt_backup_*.tar.gz 2>/dev/null | wc -l || echo 0)
log "total backup files: $CURRENT_BACKUPS"

exit 0

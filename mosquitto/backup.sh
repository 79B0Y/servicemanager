#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Mosquitto 备份脚本
# 版本: v1.0.1
# 功能: 备份 Mosquitto 配置和数据
# 修复: MQTT上报时机控制，增强备份验证
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
DST="$BACKUP_DIR/mosquitto_backup_${TS}.tar.gz"
START_TIME=$(date +%s)

log "starting mosquitto backup process"

# -----------------------------------------------------------------------------
# 检查服务是否在运行（备份时强制要求服务运行）
# -----------------------------------------------------------------------------
SERVICE_RUNNING=false
if bash "$SERVICE_DIR/status.sh" --quiet 2>/dev/null; then
    SERVICE_RUNNING=true
    log "mosquitto is running, proceeding with backup"
    
    # 服务运行中，可以安全上报MQTT
    mqtt_report "isg/backup/$SERVICE_ID/status" \
        "{\"status\":\"backuping\",\"message\":\"starting backup process\",\"timestamp\":$(date +%s)}" \
        2 2>/dev/null || log "MQTT report failed during backup start"
else
    log "mosquitto not running, backup skipped"
    
    # 服务未运行时，不上报MQTT（因为MQTT服务不可用）
    # 仅记录到日志
    echo "[$(date '+%F %T')] [INFO] Backup skipped - service not running" >> "$LOG_FILE"
    exit 0
fi

# -----------------------------------------------------------------------------
# 创建临时备份目录
# -----------------------------------------------------------------------------
TEMP_BACKUP_DIR="$TEMP_DIR/backup_$TS"
mkdir -p "$TEMP_BACKUP_DIR"

log "creating temporary backup directory: $TEMP_BACKUP_DIR"

# 上报备份进度（服务运行中，安全上报）
mqtt_report "isg/backup/$SERVICE_ID/status" \
    "{\"status\":\"backuping\",\"message\":\"preparing backup files\",\"timestamp\":$(date +%s)}" \
    1 2>/dev/null || log "MQTT progress report failed"

# -----------------------------------------------------------------------------
# 备份配置文件
# -----------------------------------------------------------------------------
FILES_BACKED_UP=0

if [ -f "$MOSQUITTO_CONF_FILE" ]; then
    cp "$MOSQUITTO_CONF_FILE" "$TEMP_BACKUP_DIR/mosquitto.conf"
    log "backed up configuration file"
    FILES_BACKED_UP=$((FILES_BACKED_UP + 1))
else
    log "warning: configuration file not found"
fi

# 备份密码文件
if [ -f "$MOSQUITTO_PASSWD_FILE" ]; then
    cp "$MOSQUITTO_PASSWD_FILE" "$TEMP_BACKUP_DIR/passwd"
    log "backed up password file"
    FILES_BACKED_UP=$((FILES_BACKED_UP + 1))
else
    log "warning: password file not found"
fi

# -----------------------------------------------------------------------------
# 备份持久化数据
# -----------------------------------------------------------------------------
PERSISTENCE_DIR="$TERMUX_VAR_DIR/lib/mosquitto"
PERSISTENCE_SIZE=0

if [ -d "$PERSISTENCE_DIR" ]; then
    mkdir -p "$TEMP_BACKUP_DIR/persistence"
    
    # 计算持久化数据大小
    PERSISTENCE_SIZE=$(du -sk "$PERSISTENCE_DIR" 2>/dev/null | cut -f1 || echo "0")
    
    if [ "$(ls -A "$PERSISTENCE_DIR" 2>/dev/null | wc -l)" -gt 0 ]; then
        cp -r "$PERSISTENCE_DIR"/* "$TEMP_BACKUP_DIR/persistence/" 2>/dev/null || true
        log "backed up persistence data (${PERSISTENCE_SIZE}KB)"
        FILES_BACKED_UP=$((FILES_BACKED_UP + 1))
    else
        log "info: persistence directory is empty"
    fi
else
    log "info: no persistence data found"
fi

# -----------------------------------------------------------------------------
# 备份日志文件（最近的）
# -----------------------------------------------------------------------------
if [ -d "$MOSQUITTO_LOG_DIR" ]; then
    mkdir -p "$TEMP_BACKUP_DIR/logs"
    
    # 只备份最近3天的日志和当前日志
    find "$MOSQUITTO_LOG_DIR" -name "*.log" -mtime -3 -exec cp {} "$TEMP_BACKUP_DIR/logs/" \; 2>/dev/null || true
    
    # 确保当前日志文件被包含
    if [ -f "$MOSQUITTO_LOG_DIR/mosquitto.log" ]; then
        cp "$MOSQUITTO_LOG_DIR/mosquitto.log" "$TEMP_BACKUP_DIR/logs/" 2>/dev/null || true
    fi
    
    local log_count=$(ls -1 "$TEMP_BACKUP_DIR/logs/" 2>/dev/null | wc -l || echo "0")
    if [ "$log_count" -gt 0 ]; then
        log "backed up recent log files ($log_count files)"
        FILES_BACKED_UP=$((FILES_BACKED_UP + 1))
    fi
fi

# -----------------------------------------------------------------------------
# 备份serviceupdate.json中的配置部分
# -----------------------------------------------------------------------------
if [ -f "$SERVICEUPDATE_FILE" ]; then
    local serviceupdate_config=$(jq -c ".services[] | select(.id==\"$SERVICE_ID\") | .config" "$SERVICEUPDATE_FILE" 2>/dev/null)
    if [ "$serviceupdate_config" != "null" ] && [ -n "$serviceupdate_config" ]; then
        echo "$serviceupdate_config" > "$TEMP_BACKUP_DIR/serviceupdate_config.json"
        log "backed up serviceupdate.json configuration"
        FILES_BACKED_UP=$((FILES_BACKED_UP + 1))
    fi
fi

# -----------------------------------------------------------------------------
# 创建备份信息文件
# -----------------------------------------------------------------------------
cat > "$TEMP_BACKUP_DIR/backup_info.txt" << EOF
Mosquitto Backup Information
============================
Backup Date: $(date)
Mosquitto Version: $(get_current_version)
Service Status: $(bash "$SERVICE_DIR/status.sh" --json 2>/dev/null || echo "unknown")
Backup Script Version: $(get_script_version)
Files Backed Up: $FILES_BACKED_UP
Persistence Size: ${PERSISTENCE_SIZE}KB

Files Included:
- mosquitto.conf: $([ -f "$TEMP_BACKUP_DIR/mosquitto.conf" ] && echo "Yes" || echo "No")
- passwd: $([ -f "$TEMP_BACKUP_DIR/passwd" ] && echo "Yes" || echo "No")
- persistence/: $([ -d "$TEMP_BACKUP_DIR/persistence" ] && echo "Yes" || echo "No")
- logs/: $([ -d "$TEMP_BACKUP_DIR/logs" ] && echo "Yes" || echo "No")
- serviceupdate_config.json: $([ -f "$TEMP_BACKUP_DIR/serviceupdate_config.json" ] && echo "Yes" || echo "No")

Configuration Summary:
$(get_config_info 2>/dev/null || echo "Configuration not available")

IPv4 Listening Status:
$(netstat -tulnp 2>/dev/null | grep "0.0.0.0:1883" && echo "Active" || echo "Not Active")

ServiceUpdate Config:
$([ -f "$SERVICEUPDATE_FILE" ] && jq -c ".services[] | select(.id==\"$SERVICE_ID\") | .config" "$SERVICEUPDATE_FILE" 2>/dev/null || echo "Not available")
EOF

log "created backup information file with $FILES_BACKED_UP components"

# -----------------------------------------------------------------------------
# 执行压缩
# -----------------------------------------------------------------------------
log "creating archive: $DST"

# 上报压缩进度
mqtt_report "isg/backup/$SERVICE_ID/status" \
    "{\"status\":\"backuping\",\"message\":\"creating archive\",\"files_count\":$FILES_BACKED_UP,\"timestamp\":$(date +%s)}" \
    1 2>/dev/null || log "MQTT archive progress report failed"

if tar -czf "$DST" -C "$TEMP_DIR" "backup_$TS"; then
    END_TIME=$(date +%s)
    SIZE_KB=$(du -k "$DST" | awk '{print $1}')
    DURATION=$((END_TIME - START_TIME))
    
    log "backup completed: $DST ($SIZE_KB KB, ${DURATION}s, $FILES_BACKED_UP files)"
    
    # 验证备份文件完整性
    if tar -tzf "$DST" >/dev/null 2>&1; then
        log "backup file integrity verified"
        
        # 上报成功状态
        mqtt_report "isg/backup/$SERVICE_ID/status" \
            "{\"service\":\"$SERVICE_ID\",\"status\":\"success\",\"file\":\"$(basename "$DST")\",\"size_kb\":$SIZE_KB,\"duration\":$DURATION,\"files_count\":$FILES_BACKED_UP,\"persistence_size_kb\":$PERSISTENCE_SIZE,\"message\":\"backup completed successfully\",\"timestamp\":$END_TIME}" \
            3 2>/dev/null || log "MQTT success report failed"
    else
        log "backup file integrity check failed"
        rm -f "$DST"
        rm -rf "$TEMP_BACKUP_DIR"
        
        mqtt_report "isg/backup/$SERVICE_ID/status" \
            "{\"status\":\"failed\",\"message\":\"backup file integrity check failed\",\"timestamp\":$(date +%s)}" \
            1 2>/dev/null || log "MQTT failure report failed"
        exit 1
    fi
else
    log "tar command failed"
    
    mqtt_report "isg/backup/$SERVICE_ID/status" \
        "{\"status\":\"failed\",\"message\":\"tar command failed\",\"timestamp\":$(date +%s)}" \
        1 2>/dev/null || log "MQTT failure report failed"
    
    rm -rf "$TEMP_BACKUP_DIR"
    exit 1
fi

# -----------------------------------------------------------------------------
# 清理临时目录
# -----------------------------------------------------------------------------
rm -rf "$TEMP_BACKUP_DIR"

# -----------------------------------------------------------------------------
# 清理旧备份 - 保留最近的指定数量
# -----------------------------------------------------------------------------
log "cleaning old backups (keeping latest $KEEP_BACKUPS)"
OLD_BACKUPS=$(ls -1t "$BACKUP_DIR"/mosquitto_backup_*.tar.gz 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)) || true)

REMOVED_COUNT=0
if [ -n "$OLD_BACKUPS" ]; then
    echo "$OLD_BACKUPS" | while read -r old_file; do
        if [ -f "$old_file" ]; then
            log "removing old backup: $(basename "$old_file")"
            rm -f "$old_file"
            REMOVED_COUNT=$((REMOVED_COUNT + 1))
        fi
    done
    
    if [ $REMOVED_COUNT -gt 0 ]; then
        log "removed $REMOVED_COUNT old backup(s)"
    fi
else
    log "no old backups to remove"
fi

# 显示当前备份文件列表
CURRENT_BACKUPS=$(ls -1t "$BACKUP_DIR"/mosquitto_backup_*.tar.gz 2>/dev/null | wc -l || echo 0)
log "total backup files: $CURRENT_BACKUPS"

log "mosquitto backup process completed successfully"
exit 0
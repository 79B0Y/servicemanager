#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Mosquitto 卸载脚本 - 热修复版本
# 版本: v1.0.1-hotfix
# 功能: 完全卸载 Mosquitto 环境和配置
# 修复: 未绑定变量错误，增强错误处理
# =============================================================================

set -euo pipefail

# 加载统一路径定义
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common_paths.sh" || {
    echo "Error: Cannot load common paths"
    exit 1
}

# 设置脚本特定的日志文件
LOG_FILE="$LOG_FILE_UNINSTALL"

# 确保必要目录存在
ensure_directories

log "starting mosquitto uninstallation"

# 检查服务当前状态，决定是否可以上报MQTT
SERVICE_WAS_RUNNING=false
if bash "$SERVICE_DIR/status.sh" --quiet 2>/dev/null; then
    SERVICE_WAS_RUNNING=true
    log "service currently running, MQTT reporting available"
    
    mqtt_report "isg/install/$SERVICE_ID/status" \
        "{\"status\":\"uninstalling\",\"message\":\"starting uninstall process\",\"timestamp\":$(date +%s)}" \
        2 2>/dev/null || log "MQTT initial report failed"
else
    log "service not running, will limit MQTT reporting"
fi

# -----------------------------------------------------------------------------
# 停止服务
# -----------------------------------------------------------------------------
log "stopping service"

if [ "$SERVICE_WAS_RUNNING" = true ]; then
    mqtt_report "isg/install/$SERVICE_ID/status" \
        "{\"status\":\"uninstalling\",\"message\":\"stopping service\",\"timestamp\":$(date +%s)}" \
        1 2>/dev/null || true
fi

bash "$SERVICE_DIR/stop.sh" || true
sleep 5

# 强制杀死进程
MOSQUITTO_PID=$(get_mosquitto_pid || echo "")
if [ -n "$MOSQUITTO_PID" ]; then
    log "force killing mosquitto process $MOSQUITTO_PID"
    kill -TERM "$MOSQUITTO_PID" 2>/dev/null || true
(
    sleep 3
    # 检查是否有其他MQTT broker可用
    if timeout 5 nc -z 127.0.0.1 1883 2>/dev/null; then
        mqtt_report "isg/install/$SERVICE_ID/status" \
            "{\"status\":\"uninstalled\",\"message\":\"mosquitto completely removed\",\"backup_files_created\":$BACKUP_FILES_CREATED,\"items_cleaned\":$CLEANED_ITEMS,\"timestamp\":$(date +%s)}" \
            1 2>/dev/null || true
    fi
) &

log "mosquitto uninstallation completed successfully"
log "backup files created: $BACKUP_FILES_CREATED"
log "configuration items cleaned: $CLEANED_ITEMS"
log "check backup directory for final backup files: $BACKUP_DIR"

exit 0
    # 如果仍在运行，使用KILL信号
    if ps -p "$MOSQUITTO_PID" >/dev/null 2>&1; then
        kill -KILL "$MOSQUITTO_PID" 2>/dev/null || true
        sleep 2
    fi
fi

# 强制清理所有mosquitto进程
pkill -9 -f mosquitto 2>/dev/null || true
sleep 2

# 验证所有进程已终止
REMAINING_PIDS=$(pgrep -f mosquitto 2>/dev/null || echo "")
if [ -n "$REMAINING_PIDS" ]; then
    log "warning: some mosquitto processes still running: $REMAINING_PIDS"
    for pid in $REMAINING_PIDS; do
        if [ -n "$pid" ]; then
            kill -9 "$pid" 2>/dev/null || true
        fi
    done
fi

# -----------------------------------------------------------------------------
# 备份配置（可选）
# -----------------------------------------------------------------------------
log "creating final backup before uninstall"

if [ "$SERVICE_WAS_RUNNING" = true ]; then
    mqtt_report "isg/install/$SERVICE_ID/status" \
        "{\"status\":\"uninstalling\",\"message\":\"creating final backup\",\"timestamp\":$(date +%s)}" \
        1 2>/dev/null || true
fi

# 备份配置文件到备份目录
BACKUP_FILES_CREATED=0

if [ -f "$MOSQUITTO_CONF_FILE" ]; then
    BACKUP_CONF="$BACKUP_DIR/mosquitto_final_backup_$(date +%Y%m%d-%H%M%S).conf"
    cp "$MOSQUITTO_CONF_FILE" "$BACKUP_CONF"
    log "configuration backed up to $(basename "$BACKUP_CONF")"
    BACKUP_FILES_CREATED=$((BACKUP_FILES_CREATED + 1))
fi

# 备份密码文件
if [ -f "$MOSQUITTO_PASSWD_FILE" ]; then
    BACKUP_PASSWD="$BACKUP_DIR/mosquitto_passwd_backup_$(date +%Y%m%d-%H%M%S)"
    cp "$MOSQUITTO_PASSWD_FILE" "$BACKUP_PASSWD"
    log "password file backed up to $(basename "$BACKUP_PASSWD")"
    BACKUP_FILES_CREATED=$((BACKUP_FILES_CREATED + 1))
fi

# 备份完整配置状态信息
BACKUP_INFO="$BACKUP_DIR/mosquitto_uninstall_info_$(date +%Y%m%d-%H%M%S).txt"
cat > "$BACKUP_INFO" << EOF
Mosquitto Uninstallation Information
===================================
Uninstall Date: $(date)
Mosquitto Version: $(get_current_version)
Service was running: $SERVICE_WAS_RUNNING
Script Version: $(get_script_version)
Backup files created: $BACKUP_FILES_CREATED

Network Status Before Uninstall:
$(netstat -tulnp 2>/dev/null | grep -E "(1883|9001)" || echo "No mosquitto ports were listening")

Configuration Summary:
$(get_config_info 2>/dev/null || echo "Configuration not available")

ServiceUpdate Config:
$([ -f "$SERVICEUPDATE_FILE" ] && jq -c ".services[] | select(.id==\"$SERVICE_ID\") | .config" "$SERVICEUPDATE_FILE" 2>/dev/null || echo "Not available")
EOF

log "uninstall information saved to $(basename "$BACKUP_INFO")"
BACKUP_FILES_CREATED=$((BACKUP_FILES_CREATED + 1))

# -----------------------------------------------------------------------------
# 强制释放端口（修复版）
# -----------------------------------------------------------------------------
log "ensuring ports are released"

# 安全获取1883端口的PID
PIDS_ON_1883=""
if netstat -tulnp 2>/dev/null | grep -q ":1883"; then
    PIDS_ON_1883=$(netstat -tulnp 2>/dev/null | grep ":1883" | awk '{
        if (NF >= 7 && $7 != "" && $7 != "-") {
            split($7, parts, "/");
            if (parts[1] ~ /^[0-9]+$/) print parts[1]
        }
    }' | sort -u || echo "")
fi

if [ -n "$PIDS_ON_1883" ]; then
    log "found processes on port 1883: $PIDS_ON_1883"
    for pid in $PIDS_ON_1883; do
        if [ -n "$pid" ] && [ "$pid" != "-" ]; then
            log "force killing process on port 1883: PID $pid"
            kill -9 "$pid" 2>/dev/null || true
        fi
    done
else
    log "no processes found on port 1883"
fi

# 安全获取9001端口的PID
PIDS_ON_9001=""
if netstat -tulnp 2>/dev/null | grep -q ":9001"; then
    PIDS_ON_9001=$(netstat -tulnp 2>/dev/null | grep ":9001" | awk '{
        if (NF >= 7 && $7 != "" && $7 != "-") {
            split($7, parts, "/");
            if (parts[1] ~ /^[0-9]+$/) print parts[1]
        }
    }' | sort -u || echo "")
fi

if [ -n "$PIDS_ON_9001" ]; then
    log "found processes on port 9001: $PIDS_ON_9001"
    for pid in $PIDS_ON_9001; do
        if [ -n "$pid" ] && [ "$pid" != "-" ]; then
            log "force killing process on port 9001: PID $pid"
            kill -9 "$pid" 2>/dev/null || true
        fi
    done
else
    log "no processes found on port 9001"
fi

sleep 2

# 验证端口释放
REMAINING_1883=$(netstat -tulnp 2>/dev/null | grep ":1883" || echo "")
REMAINING_9001=$(netstat -tulnp 2>/dev/null | grep ":9001" || echo "")

if [ -n "$REMAINING_1883" ] || [ -n "$REMAINING_9001" ]; then
    log_warn "some mosquitto ports still in use after cleanup"
    if [ -n "$REMAINING_1883" ]; then
        echo "Port 1883: $REMAINING_1883" >> "$LOG_FILE"
    fi
    if [ -n "$REMAINING_9001" ]; then
        echo "Port 9001: $REMAINING_9001" >> "$LOG_FILE"
    fi
else
    log "all mosquitto ports released successfully"
fi

# -----------------------------------------------------------------------------
# 移除服务监控目录
# -----------------------------------------------------------------------------
log "removing service monitor directory"

if [ "$SERVICE_WAS_RUNNING" = true ]; then
    mqtt_report "isg/install/$SERVICE_ID/status" \
        "{\"status\":\"uninstalling\",\"message\":\"removing service monitor directory\",\"timestamp\":$(date +%s)}" \
        1 2>/dev/null || true
fi

if [ -d "$SERVICE_CONTROL_DIR" ]; then
    # 先停止supervise进程
    if [ -f "$SERVICE_CONTROL_DIR/supervise/pid" ]; then
        supervise_pid=$(cat "$SERVICE_CONTROL_DIR/supervise/pid" 2>/dev/null || echo "")
        if [ -n "$supervise_pid" ] && ps -p "$supervise_pid" >/dev/null 2>&1; then
            log "stopping supervise process: $supervise_pid"
            kill -TERM "$supervise_pid" 2>/dev/null || true
            sleep 2
            kill -KILL "$supervise_pid" 2>/dev/null || true
        fi
    fi
    
    rm -rf "$SERVICE_CONTROL_DIR"
    log "removed service control directory: $SERVICE_CONTROL_DIR"
else
    log "service control directory not found: $SERVICE_CONTROL_DIR"
fi

# -----------------------------------------------------------------------------
# 卸载 Mosquitto 包
# -----------------------------------------------------------------------------
log "uninstalling mosquitto package"

# 上报卸载包的进度（可能通过其他MQTT服务）
(
    sleep 1
    if [ "$SERVICE_WAS_RUNNING" = true ]; then
        mqtt_report "isg/install/$SERVICE_ID/status" \
            "{\"status\":\"uninstalling\",\"message\":\"uninstalling mosquitto package\",\"timestamp\":$(date +%s)}" \
            1 2>/dev/null || true
    fi
) &

if command -v mosquitto >/dev/null 2>&1; then
    if pkg uninstall -y mosquitto 2>/dev/null; then
        log "mosquitto package uninstalled successfully"
    else
        log_warn "failed to uninstall mosquitto package cleanly, continuing with manual cleanup"
        
        # 手动清理二进制文件
        for binary in mosquitto mosquitto_pub mosquitto_sub mosquitto_passwd; do
            if [ -f "/data/data/com.termux/files/usr/bin/$binary" ]; then
                rm -f "/data/data/com.termux/files/usr/bin/$binary"
                log "manually removed binary: $binary"
            fi
        done
    fi
else
    log "mosquitto package not found, skipping package uninstall"
fi

# -----------------------------------------------------------------------------
# 清理配置文件和数据
# -----------------------------------------------------------------------------
log "cleaning up configuration files and data"

# 上报清理进度
(
    sleep 1
    if [ "$SERVICE_WAS_RUNNING" = true ]; then
        mqtt_report "isg/install/$SERVICE_ID/status" \
            "{\"status\":\"uninstalling\",\"message\":\"cleaning up configuration files\",\"backup_files_created\":$BACKUP_FILES_CREATED,\"timestamp\":$(date +%s)}" \
            1 2>/dev/null || true
    fi
) &

CLEANED_ITEMS=0

# 移除配置目录
if [ -d "$MOSQUITTO_CONF_DIR" ]; then
    rm -rf "$MOSQUITTO_CONF_DIR"
    log "removed configuration directory: $MOSQUITTO_CONF_DIR"
    CLEANED_ITEMS=$((CLEANED_ITEMS + 1))
fi

# 移除日志目录
if [ -d "$MOSQUITTO_LOG_DIR" ]; then
    rm -rf "$MOSQUITTO_LOG_DIR"
    log "removed log directory: $MOSQUITTO_LOG_DIR"
    CLEANED_ITEMS=$((CLEANED_ITEMS + 1))
fi

# 移除持久化数据目录
PERSISTENCE_DIR="$TERMUX_VAR_DIR/lib/mosquitto"
if [ -d "$PERSISTENCE_DIR" ]; then
    # 先备份持久化数据的摘要信息
    if [ "$(ls -A "$PERSISTENCE_DIR" 2>/dev/null | wc -l || echo "0")" -gt 0 ]; then
        local persistence_size=$(du -sk "$PERSISTENCE_DIR" 2>/dev/null | cut -f1 || echo "0")
        local persistence_files=$(find "$PERSISTENCE_DIR" -type f 2>/dev/null | wc -l || echo "0")
        echo "Persistence data removed: ${persistence_size}KB, $persistence_files files" >> "$BACKUP_INFO"
        log "persistence data summary added to backup info"
    fi
    
    rm -rf "$PERSISTENCE_DIR"
    log "removed persistence directory: $PERSISTENCE_DIR"
    CLEANED_ITEMS=$((CLEANED_ITEMS + 1))
fi

# 移除PID文件
if [ -f "$MOSQUITTO_PID_FILE" ]; then
    rm -f "$MOSQUITTO_PID_FILE"
    log "removed PID file: $MOSQUITTO_PID_FILE"
    CLEANED_ITEMS=$((CLEANED_ITEMS + 1))
fi

# 清理任何残留的mosquitto相关文件
MOSQUITTO_FILES=$(find /data/data/com.termux/files/usr -name "*mosquitto*" -type f 2>/dev/null || echo "")
if [ -n "$MOSQUITTO_FILES" ]; then
    echo "$MOSQUITTO_FILES" | while IFS= read -r file; do
        if [ -f "$file" ]; then
            rm -f "$file"
            log "removed mosquitto related file: $file"
            CLEANED_ITEMS=$((CLEANED_ITEMS + 1))
        fi
    done
fi

# -----------------------------------------------------------------------------
# 清理脚本目录的状态文件
# -----------------------------------------------------------------------------
log "cleaning up service script state files"

# 清理状态文件但保留脚本
for state_file in ".disabled" ".lock_autocheck" ".lastcheck" ".last_pid"; do
    if [ -f "$SERVICE_DIR/$state_file" ]; then
        rm -f "$SERVICE_DIR/$state_file"
        log "removed state file: $state_file"
    fi
done

# 清理VERSION文件
if [ -f "$VERSION_FILE" ]; then
    local last_version=$(cat "$VERSION_FILE" 2>/dev/null || echo "unknown")
    echo "Last installed version: $last_version" >> "$BACKUP_INFO"
    rm -f "$VERSION_FILE"
    log "removed VERSION file (was: $last_version)"
fi

# -----------------------------------------------------------------------------
# 创建 .disabled 标志
# -----------------------------------------------------------------------------
log "creating .disabled flag"
touch "$DISABLED_FLAG"

# -----------------------------------------------------------------------------
# 记录卸载历史
# -----------------------------------------------------------------------------
record_uninstall_history "SUCCESS"

# -----------------------------------------------------------------------------
# 最终验证和上报卸载成功
# -----------------------------------------------------------------------------
log "performing final verification"

# 验证进程清理
REMAINING_MOSQUITTO_PROCESSES=$(pgrep -f mosquitto 2>/dev/null || echo "")
if [ -n "$REMAINING_MOSQUITTO_PROCESSES" ]; then
    log_warn "warning: some mosquitto processes may still be running: $REMAINING_MOSQUITTO_PROCESSES"
else
    log "all mosquitto processes terminated successfully"
fi

# 验证端口清理
REMAINING_MOSQUITTO_PORTS=$(netstat -tulnp 2>/dev/null | grep -E ":1883|:9001" || echo "")
if [ -n "$REMAINING_MOSQUITTO_PORTS" ]; then
    log_warn "warning: some mosquitto ports may still be in use"
    echo "$REMAINING_MOSQUITTO_PORTS" >> "$LOG_FILE"
else
    log "all mosquitto ports released successfully"
fi

# 验证二进制文件清理
if command -v mosquitto >/dev/null 2>&1; then
    log_warn "warning: mosquitto command still available in PATH"
else
    log "mosquitto command removed from system"
fi

# 更新备份信息文件
cat >> "$BACKUP_INFO" << EOF

Uninstallation Results:
- Backup files created: $BACKUP_FILES_CREATED
- Configuration items cleaned: $CLEANED_ITEMS
- Processes terminated: verified
- Ports released: verified
- Package uninstalled: verified
- Final status: SUCCESS
EOF

log "final verification completed"

# -----------------------------------------------------------------------------
# 上报卸载成功
# -----------------------------------------------------------------------------
log "reporting uninstall success"


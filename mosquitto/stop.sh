#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Mosquitto 停止脚本
# 版本: v1.0.1
# 功能: 通过 isgservicemonitor 停止 Mosquitto 服务
# 修复: MQTT上报时机控制，优雅停止流程
# =============================================================================

set -euo pipefail

# 加载统一路径定义
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common_paths.sh" || {
    echo "Error: Cannot load common paths"
    exit 1
}

# 设置脚本特定的日志文件
LOG_FILE="$LOG_FILE_STOP"

# 确保必要目录存在
ensure_directories

log "stopping mosquitto service"

# 在停止前先尝试上报状态（如果服务运行中）
if bash "$SERVICE_DIR/status.sh" --quiet 2>/dev/null; then
    mqtt_report "isg/run/$SERVICE_ID/status" \
        "{\"service\":\"$SERVICE_ID\",\"status\":\"stopping\",\"message\":\"stopping service\",\"timestamp\":$(date +%s)}" \
        1 2>/dev/null || log "MQTT report failed during stop initiation"
fi

# -----------------------------------------------------------------------------
# 发送停止信号
# -----------------------------------------------------------------------------
if [ -e "$CONTROL_FILE" ]; then
    echo d > "$CONTROL_FILE"
    log "sent 'd' command to $CONTROL_FILE"
    
    # 创建 down 文件禁用自启动
    touch "$DOWN_FILE"
    log "created down file to disable auto-start"
else
    log "control file not found; fallback to direct process termination"
    
    # 直接终止进程
    MOSQUITTO_PID=$(get_mosquitto_pid || true)
    if [ -n "$MOSQUITTO_PID" ]; then
        log "found mosquitto PID: $MOSQUITTO_PID, sending TERM signal"
        kill -TERM "$MOSQUITTO_PID" 2>/dev/null || true
        sleep 2
        
        # 如果仍在运行，发送KILL信号
        if ps -p "$MOSQUITTO_PID" >/dev/null 2>&1; then
            log "process still running, sending KILL signal"
            kill -KILL "$MOSQUITTO_PID" 2>/dev/null || true
        fi
    else
        log "no mosquitto process found"
    fi
    
    # 创建 down 文件
    touch "$DOWN_FILE"
fi

# -----------------------------------------------------------------------------
# 等待服务停止
# -----------------------------------------------------------------------------
log "waiting for service to stop completely"

TRIES=0
MAX_TRIES_STOP=20
STOP_INTERVAL=3
SERVICE_STOPPED=false

while (( TRIES < MAX_TRIES_STOP )); do
    # 检查进程是否仍在运行
    if MOSQUITTO_PID=$(get_mosquitto_pid 2>/dev/null); then
        log "service still running (PID: $MOSQUITTO_PID), waiting... (attempt $((TRIES+1))/$MAX_TRIES_STOP)"
        
        # 如果超过一半时间仍在运行，发送更强的信号
        if [ $TRIES -gt $((MAX_TRIES_STOP / 2)) ]; then
            log "sending additional TERM signal to PID: $MOSQUITTO_PID"
            kill -TERM "$MOSQUITTO_PID" 2>/dev/null || true
        fi
        
        sleep "$STOP_INTERVAL"
        TRIES=$((TRIES+1))
    else
        log "mosquitto process terminated successfully"
        SERVICE_STOPPED=true
        break
    fi
done

# -----------------------------------------------------------------------------
# 验证停止状态和端口释放
# -----------------------------------------------------------------------------
if [ "$SERVICE_STOPPED" = true ]; then
    # 额外验证端口是否释放
    WAIT_PORT_RELEASE=5
    while [ $WAIT_PORT_RELEASE -gt 0 ]; do
        if netstat -tulnp 2>/dev/null | grep -q ":1883"; then
            log "waiting for port 1883 to be released..."
            sleep 1
            WAIT_PORT_RELEASE=$((WAIT_PORT_RELEASE - 1))
        else
            log "port 1883 released successfully"
            break
        fi
    done
    
    # 创建 .disabled 标志
    touch "$DISABLED_FLAG"
    log "service stopped completely and .disabled flag created"
    
    # 上报成功停止状态（尝试使用其他MQTT服务）
    (
        sleep 1
        mqtt_report "isg/run/$SERVICE_ID/status" \
            "{\"service\":\"$SERVICE_ID\",\"status\":\"success\",\"message\":\"service stopped and disabled\",\"port_released\":true,\"timestamp\":$(date +%s)}" \
            1 2>/dev/null || true
    ) &
    
    exit 0
else
    # 停止失败，进行强制清理
    log "service failed to stop gracefully, performing force cleanup"
    
    # 强制杀死所有相关进程
    pkill -9 -f mosquitto 2>/dev/null || true
    sleep 2
    
    # 检查是否还有残留进程
    if REMAINING_PID=$(get_mosquitto_pid 2>/dev/null); then
        log "warning: mosquitto process still exists after force kill (PID: $REMAINING_PID)"
        kill -9 "$REMAINING_PID" 2>/dev/null || true
    fi
    
    # 强制释放端口（如果可能）
    local pids_on_port=$(netstat -tulnp 2>/dev/null | grep ":1883" | awk '{print $7}' | cut -d'/' -f1 | grep -v '^-$' || true)
    if [ -n "$pids_on_port" ]; then
        for pid in $pids_on_port; do
            log "force killing process on port 1883: PID $pid"
            kill -9 "$pid" 2>/dev/null || true
        done
    fi
    
    # 创建标志文件
    touch "$DISABLED_FLAG"
    touch "$DOWN_FILE"
    
    log "force cleanup completed, but stop timeout occurred"
    
    # 上报超时状态
    (
        sleep 1
        mqtt_report "isg/run/$SERVICE_ID/status" \
            "{\"service\":\"$SERVICE_ID\",\"status\":\"failed\",\"message\":\"service stop timeout, force cleanup performed\",\"timeout\":$((MAX_TRIES_STOP * STOP_INTERVAL)),\"timestamp\":$(date +%s)}" \
            1 2>/dev/null || true
    ) &
    
    exit 1
fi
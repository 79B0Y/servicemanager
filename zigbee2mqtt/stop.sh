#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Zigbee2MQTT 停止脚本
# 版本: v1.1.0
# 功能: 通过 isgservicemonitor 停止 Zigbee2MQTT 服务
# =============================================================================

set -euo pipefail
trap 'echo "[ERROR] line $LINENO: command failed." | tee -a "$LOG_FILE"' ERR

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

log "stopping zigbee2mqtt service"
mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"stopping\",\"message\":\"stopping service\",\"timestamp\":$(date +%s)}"

# -----------------------------------------------------------------------------
# 发送停止信号
# -----------------------------------------------------------------------------
if [ -e "$CONTROL_FILE" ]; then
    echo d > "$CONTROL_FILE"
    log "sent 'd' command to $CONTROL_FILE"
    
    # 创建 down 文件禁用自启动
    touch "$DOWN_FILE"
    log "created down file to disable auto-start"
    mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"stopping\",\"message\":\"created down file to disable auto-start\",\"timestamp\":$(date +%s)}"
else
    log "control file not found; fallback to kill process"
    Z2M_PID=$(get_z2m_pid || true)
    if [ -n "$Z2M_PID" ]; then
        kill "$Z2M_PID" 2>/dev/null || true
        log "sent TERM signal to PID $Z2M_PID"
    else
        log "no zigbee2mqtt process found"
    fi
fi

# -----------------------------------------------------------------------------
# 等待服务停止
# -----------------------------------------------------------------------------
log "waiting for service to stop"
mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"stopping\",\"message\":\"waiting for service to stop\",\"timestamp\":$(date +%s)}"

TRIES=0
while (( TRIES < MAX_TRIES )); do
    if ! bash "$SERVICE_DIR/status.sh" --quiet; then
        break
    fi
    sleep 5
    TRIES=$((TRIES+1))
done

# -----------------------------------------------------------------------------
# 检查停止结果
# -----------------------------------------------------------------------------
if bash "$SERVICE_DIR/status.sh" --quiet; then
    log "service still running after $((MAX_TRIES*5)) seconds"
    mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"failed\",\"message\":\"service still running after stop timeout\",\"timeout\":$((MAX_TRIES*5)),\"timestamp\":$(date +%s)}"
    exit 1
fi

# -----------------------------------------------------------------------------
# 创建 .disabled 标志
# -----------------------------------------------------------------------------
touch "$DISABLED_FLAG"
log "service stopped and .disabled flag created"
mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"success\",\"message\":\"service stopped and disabled\",\"timestamp\":$(date +%s)}"

exit 0

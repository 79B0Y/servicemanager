#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Mosquitto 启动脚本
# 版本: v1.0.0
# 功能: 通过 isgservicemonitor 启动 Mosquitto 服务
# =============================================================================

set -euo pipefail

# 加载统一路径定义
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common_paths.sh" || {
    echo "Error: Cannot load common paths"
    exit 1
}

# 设置脚本特定的日志文件
LOG_FILE="$LOG_FILE_START"

# 确保必要目录存在
ensure_directories

log "starting mosquitto service"
mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"starting\",\"message\":\"starting service\",\"timestamp\":$(date +%s)}"

# -----------------------------------------------------------------------------
# 移除 .disabled 和 down 文件
# -----------------------------------------------------------------------------
if [ -f "$DISABLED_FLAG" ]; then
    rm -f "$DISABLED_FLAG"
    log "removed .disabled flag"
fi

if [ -f "$DOWN_FILE" ]; then
    rm -f "$DOWN_FILE"
    log "removed down file to enable auto-start"
    mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"starting\",\"message\":\"removed down file to enable auto-start\",\"timestamp\":$(date +%s)}"
fi

# -----------------------------------------------------------------------------
# 启动服务
# -----------------------------------------------------------------------------
if [ -e "$CONTROL_FILE" ]; then
    echo u > "$CONTROL_FILE"
    log "sent 'u' command to $CONTROL_FILE"
else
    log "control file not found; cannot start service"
    mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"failed\",\"message\":\"supervise control file not found\",\"timestamp\":$(date +%s)}"
    exit 1
fi

# -----------------------------------------------------------------------------
# 等待服务进入 running 状态
# -----------------------------------------------------------------------------
log "waiting for service ready"
mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"starting\",\"message\":\"waiting for service ready\",\"timestamp\":$(date +%s)}"

TRIES=0
while (( TRIES < MAX_TRIES )); do
    if bash "$SERVICE_DIR/status.sh" --quiet; then
        log "service started successfully"
        mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"success\",\"message\":\"service started successfully\",\"timestamp\":$(date +%s)}"
        exit 0
    fi
    sleep 5
    TRIES=$((TRIES+1))
done

# -----------------------------------------------------------------------------
# 启动失败：恢复 .disabled
# -----------------------------------------------------------------------------
log "service failed to start in time, restoring .disabled"
touch "$DISABLED_FLAG"
mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"failed\",\"message\":\"service failed to reach running state\",\"timeout\":$((MAX_TRIES*5)),\"timestamp\":$(date +%s)}"
exit 1
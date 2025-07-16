#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Mosquitto 状态查询脚本
# 版本: v1.0.0
# 功能: 检查服务运行状态和端口监听状态
# =============================================================================

set -euo pipefail

# 加载统一路径定义
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common_paths.sh" || {
    echo "Error: Cannot load common paths"
    exit 1
}

# 设置脚本特定的日志文件
LOG_FILE="$LOG_FILE_STATUS"

# 确保必要目录存在
ensure_directories

# -----------------------------------------------------------------------------
# 检查进程状态
# -----------------------------------------------------------------------------
PID=$(get_mosquitto_pid || true)
RUNTIME=""
PORT_STATUS="closed"

if [ -n "$PID" ]; then
    RUNTIME=$(ps -o etime= -p "$PID" | xargs)
    
    # 检查端口状态
    if netstat -tnl 2>/dev/null | grep -q ":$MOSQUITTO_PORT "; then
        PORT_STATUS="listening"
        STATUS="running"
        EXIT=0
    else
        PORT_STATUS="closed"
        STATUS="starting"
        EXIT=2
    fi
    
    # 检查WebSocket端口
    WS_PORT_STATUS="closed"
    if netstat -tnl 2>/dev/null | grep -q ":$MOSQUITTO_WS_PORT "; then
        WS_PORT_STATUS="listening"
    fi
else
    STATUS="stopped"
    EXIT=1
    PORT_STATUS="closed"
    WS_PORT_STATUS="closed"
fi

# -----------------------------------------------------------------------------
# 处理命令行参数
# -----------------------------------------------------------------------------
case "${1:-}" in
    --json)
        echo "{\"status\":\"$STATUS\",\"pid\":\"$PID\",\"runtime\":\"$RUNTIME\",\"port_status\":\"$PORT_STATUS\",\"ws_port_status\":\"$WS_PORT_STATUS\"}"
        exit $EXIT
        ;;
    --quiet)
        exit $EXIT
        ;;
    *)
        ;;
esac

# -----------------------------------------------------------------------------
# 上报状态和记录日志
# -----------------------------------------------------------------------------
TS=$(date +%s)
if [ "$STATUS" = "running" ]; then
    mqtt_report "isg/status/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"running\",\"pid\":$PID,\"runtime\":\"$RUNTIME\",\"port_status\":\"$PORT_STATUS\",\"ws_port_status\":\"$WS_PORT_STATUS\",\"timestamp\":$TS}"
    log "mosquitto running (PID=$PID, uptime=$RUNTIME, port=$PORT_STATUS, ws_port=$WS_PORT_STATUS)"
elif [ "$STATUS" = "starting" ]; then
    mqtt_report "isg/status/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"starting\",\"pid\":$PID,\"runtime\":\"$RUNTIME\",\"port_status\":\"$PORT_STATUS\",\"ws_port_status\":\"$WS_PORT_STATUS\",\"timestamp\":$TS}"
    log "mosquitto starting (PID=$PID, port=$PORT_STATUS, ws_port=$WS_PORT_STATUS)"
else
    mqtt_report "isg/status/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"stopped\",\"message\":\"service not running\",\"timestamp\":$TS}"
    log "mosquitto not running"
fi

exit $EXIT
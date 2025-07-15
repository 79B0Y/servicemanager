#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Z-Wave JS UI 状态查询脚本
# 版本: v1.0.0
# 功能: 检查服务运行状态和端口状态
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
PID=$(get_zwave_pid || true)
RUNTIME=""
WEB_STATUS="offline"

if [ -n "$PID" ]; then
    RUNTIME=$(ps -o etime= -p "$PID" | xargs)
    
    # 检查 Web 界面状态 (端口 8190)
    if timeout 5 nc -z 127.0.0.1 "$ZWAVE_PORT" 2>/dev/null; then
        WEB_STATUS="online"
        STATUS="running"
        EXIT=0
    else
        WEB_STATUS="starting"
        STATUS="starting"
        EXIT=2
    fi
else
    STATUS="stopped"
    EXIT=1
    WEB_STATUS="offline"
fi

# -----------------------------------------------------------------------------
# 处理命令行参数
# -----------------------------------------------------------------------------
case "${1:-}" in
    --json)
        echo "{\"status\":\"$STATUS\",\"pid\":\"$PID\",\"runtime\":\"$RUNTIME\",\"web_status\":\"$WEB_STATUS\",\"port\":\"$ZWAVE_PORT\"}"
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
    mqtt_report "isg/status/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"running\",\"pid\":$PID,\"runtime\":\"$RUNTIME\",\"web_status\":\"$WEB_STATUS\",\"port\":\"$ZWAVE_PORT\",\"timestamp\":$TS}"
    log "zwave-js-ui running (PID=$PID, uptime=$RUNTIME, web=$WEB_STATUS, port=$ZWAVE_PORT)"
elif [ "$STATUS" = "starting" ]; then
    mqtt_report "isg/status/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"starting\",\"pid\":$PID,\"runtime\":\"$RUNTIME\",\"web_status\":\"$WEB_STATUS\",\"port\":\"$ZWAVE_PORT\",\"timestamp\":$TS}"
    log "zwave-js-ui starting (PID=$PID, web=$WEB_STATUS, port=$ZWAVE_PORT)"
else
    mqtt_report "isg/status/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"stopped\",\"message\":\"service not running\",\"timestamp\":$TS}"
    log "zwave-js-ui not running"
fi

exit $EXIT

#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Node-RED 状态查询脚本
# 版本: v1.1.0
# 功能: 检查服务运行状态和 HTTP 接口可用性
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
PID=$(get_node_red_pid || true)
RUNTIME=""
HTTP_STATUS="offline"

if [ -n "$PID" ]; then
    RUNTIME=$(ps -o etime= -p "$PID" | xargs)
    
    # 检查 HTTP 接口状态
    if timeout "$HTTP_TIMEOUT" nc -z 127.0.0.1 "$NODE_RED_PORT" 2>/dev/null; then
        # 尝试获取简单的 HTTP 响应
        HTTP_RESPONSE=$(timeout "$HTTP_TIMEOUT" curl -s -I "http://127.0.0.1:$NODE_RED_PORT" 2>/dev/null | head -n1 || echo "")
        if echo "$HTTP_RESPONSE" | grep -q "200\|302\|401"; then
            HTTP_STATUS="online"
            STATUS="running"
            EXIT=0
        else
            HTTP_STATUS="starting"
            STATUS="starting"
            EXIT=2
        fi
    else
        HTTP_STATUS="offline"
        STATUS="starting"
        EXIT=2
    fi
else
    STATUS="stopped"
    EXIT=1
    HTTP_STATUS="offline"
fi

# -----------------------------------------------------------------------------
# 处理命令行参数
# -----------------------------------------------------------------------------
case "${1:-}" in
    --json)
        echo "{\"status\":\"$STATUS\",\"pid\":\"$PID\",\"runtime\":\"$RUNTIME\",\"http_status\":\"$HTTP_STATUS\",\"port\":\"$NODE_RED_PORT\"}"
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
    mqtt_report "isg/status/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"running\",\"pid\":$PID,\"runtime\":\"$RUNTIME\",\"http_status\":\"$HTTP_STATUS\",\"port\":\"$NODE_RED_PORT\",\"timestamp\":$TS}"
    log "node-red running (PID=$PID, uptime=$RUNTIME, http=$HTTP_STATUS, port=$NODE_RED_PORT)"
elif [ "$STATUS" = "starting" ]; then
    mqtt_report "isg/status/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"starting\",\"pid\":$PID,\"runtime\":\"$RUNTIME\",\"http_status\":\"$HTTP_STATUS\",\"port\":\"$NODE_RED_PORT\",\"timestamp\":$TS}"
    log "node-red starting (PID=$PID, http=$HTTP_STATUS)"
else
    mqtt_report "isg/status/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"stopped\",\"message\":\"service not running\",\"timestamp\":$TS}"
    log "node-red not running"
fi

exit $EXIT

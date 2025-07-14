#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Zigbee2MQTT 状态查询脚本
# 版本: v1.1.0
# 功能: 检查服务运行状态和 MQTT 桥接状态
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
PID=$(get_z2m_pid || true)
RUNTIME=""
BRIDGE_STATE="offline"

if [ -n "$PID" ]; then
    RUNTIME=$(ps -o etime= -p "$PID" | xargs)
    
    # 检查 MQTT bridge 状态
    load_mqtt_conf
    BRIDGE_RAW=$(timeout "$MQTT_TIMEOUT" mosquitto_sub -h "$MQTT_HOST" -p "$MQTT_PORT" \
        -u "$MQTT_USER" -P "$MQTT_PASS" \
        -t "zigbee2mqtt/bridge/state" -C 1 2>/dev/null || echo "unknown")
    
    # 解析 JSON 格式的桥接状态
    if command -v jq >/dev/null 2>&1; then
        BRIDGE_STATE=$(echo "$BRIDGE_RAW" | jq -r '.state // empty' 2>/dev/null || echo "$BRIDGE_RAW")
    else
        # 如果没有 jq，尝试简单的文本解析
        BRIDGE_STATE=$(echo "$BRIDGE_RAW" | grep -o '"state":"[^"]*"' | cut -d'"' -f4 2>/dev/null || echo "$BRIDGE_RAW")
    fi
    
    # 如果解析失败，使用原始值
    [ -z "$BRIDGE_STATE" ] && BRIDGE_STATE="$BRIDGE_RAW"
    
    if [ "$BRIDGE_STATE" = "online" ]; then
        STATUS="running"
        EXIT=0
    else
        STATUS="starting"
        EXIT=2
    fi
else
    STATUS="stopped"
    EXIT=1
    BRIDGE_STATE="offline"
fi

# -----------------------------------------------------------------------------
# 处理命令行参数
# -----------------------------------------------------------------------------
case "${1:-}" in
    --json)
        echo "{\"status\":\"$STATUS\",\"pid\":\"$PID\",\"runtime\":\"$RUNTIME\",\"bridge_state\":\"$BRIDGE_STATE\"}"
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
    mqtt_report "isg/status/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"running\",\"pid\":$PID,\"runtime\":\"$RUNTIME\",\"bridge_state\":\"$BRIDGE_STATE\",\"timestamp\":$TS}"
    log "zigbee2mqtt running (PID=$PID, uptime=$RUNTIME, bridge=$BRIDGE_STATE)"
elif [ "$STATUS" = "starting" ]; then
    mqtt_report "isg/status/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"starting\",\"pid\":$PID,\"runtime\":\"$RUNTIME\",\"bridge_state\":\"$BRIDGE_STATE\",\"timestamp\":$TS}"
    log "zigbee2mqtt starting (PID=$PID, bridge=$BRIDGE_STATE)"
else
    mqtt_report "isg/status/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"stopped\",\"message\":\"service not running\",\"timestamp\":$TS}"
    log "zigbee2mqtt not running"
fi

exit $EXIT

#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Mosquitto 状态查询脚本  
# 版本: v1.0.1
# 功能: 检查服务运行状态和IPv4端口监听状态
# 修复: IPv4监听验证，MQTT上报时机控制
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
# 检查进程状态和IPv4监听
# -----------------------------------------------------------------------------
PID=$(get_mosquitto_pid || true)
RUNTIME=""
PORT_STATUS="closed"
WS_PORT_STATUS="closed"
IPV4_LISTENING=false
STATUS="stopped"
EXIT=1

if [ -n "$PID" ]; then
    # 获取运行时间
    RUNTIME=$(ps -o etime= -p "$PID" 2>/dev/null | xargs || echo "unknown")
    
    # 检查IPv4主端口监听状态 - 关键验证
    if netstat -tulnp 2>/dev/null | grep -q "0.0.0.0:1883"; then
        PORT_STATUS="listening"
        IPV4_LISTENING=true
        STATUS="running"
        EXIT=0
        log_debug "mosquitto listening on IPv4 0.0.0.0:1883"
    elif netstat -tulnp 2>/dev/null | grep -q ":1883"; then
        # 检查是否监听其他地址
        local listening_addr=$(netstat -tulnp 2>/dev/null | grep ":1883" | awk '{print $4}' | head -1)
        PORT_STATUS="partial"
        STATUS="starting"
        EXIT=2
        log_debug "mosquitto listening on non-global address: $listening_addr"
    else
        PORT_STATUS="closed"
        STATUS="starting"  # 进程存在但端口未监听
        EXIT=2
        log_debug "mosquitto process exists but port 1883 not listening"
    fi
    
    # 检查WebSocket端口 - IPv4监听
    if netstat -tulnp 2>/dev/null | grep -q "0.0.0.0:9001"; then
        WS_PORT_STATUS="listening"
        log_debug "mosquitto WebSocket listening on IPv4 0.0.0.0:9001"
    elif netstat -tulnp 2>/dev/null | grep -q ":9001"; then
        WS_PORT_STATUS="partial"
        log_debug "mosquitto WebSocket listening on non-global address"
    else
        WS_PORT_STATUS="closed"
        log_debug "mosquitto WebSocket port 9001 not listening"
    fi
else
    STATUS="stopped"
    EXIT=1
    PORT_STATUS="closed"
    WS_PORT_STATUS="closed"
    IPV4_LISTENING=false
    log_debug "no mosquitto process found"
fi

# -----------------------------------------------------------------------------
# 配置文件验证
# -----------------------------------------------------------------------------
CONFIG_VALID=false
if [ -f "$MOSQUITTO_CONF_FILE" ]; then
    if mosquitto -c "$MOSQUITTO_CONF_FILE" -t 2>/dev/null; then
        CONFIG_VALID=true
    else
        log_debug "configuration file validation failed"
    fi
else
    log_debug "configuration file not found: $MOSQUITTO_CONF_FILE"
fi

# -----------------------------------------------------------------------------
# 处理命令行参数
# -----------------------------------------------------------------------------
case "${1:-}" in
    --json)
        echo "{\"status\":\"$STATUS\",\"pid\":\"$PID\",\"runtime\":\"$RUNTIME\",\"port_status\":\"$PORT_STATUS\",\"ws_port_status\":\"$WS_PORT_STATUS\",\"ipv4_listening\":$IPV4_LISTENING,\"config_valid\":$CONFIG_VALID}"
        exit $EXIT
        ;;
    --quiet)
        exit $EXIT
        ;;
    *)
        ;;
esac

# -----------------------------------------------------------------------------
# 上报状态和记录日志 - 仅在服务运行时上报MQTT
# -----------------------------------------------------------------------------
TS=$(date +%s)

if [ "$STATUS" = "running" ]; then
    log "mosquitto running (PID=$PID, uptime=$RUNTIME, IPv4=$IPV4_LISTENING, port=$PORT_STATUS, ws_port=$WS_PORT_STATUS)"
    
    # 服务运行中，安全上报MQTT状态
    mqtt_report "isg/status/$SERVICE_ID/status" \
        "{\"service\":\"$SERVICE_ID\",\"status\":\"running\",\"pid\":$PID,\"runtime\":\"$RUNTIME\",\"port_status\":\"$PORT_STATUS\",\"ws_port_status\":\"$WS_PORT_STATUS\",\"ipv4_listening\":$IPV4_LISTENING,\"config_valid\":$CONFIG_VALID,\"timestamp\":$TS}" \
        2 2>/dev/null || log "MQTT report failed (service may be restarting)"
        
elif [ "$STATUS" = "starting" ]; then
    log "mosquitto starting (PID=$PID, runtime=$RUNTIME, IPv4=$IPV4_LISTENING, port=$PORT_STATUS, ws_port=$WS_PORT_STATUS)"
    
    # 服务启动中，谨慎上报（可能MQTT不可用）
    (
        sleep 1
        mqtt_report "isg/status/$SERVICE_ID/status" \
            "{\"service\":\"$SERVICE_ID\",\"status\":\"starting\",\"pid\":$PID,\"runtime\":\"$RUNTIME\",\"port_status\":\"$PORT_STATUS\",\"ws_port_status\":\"$WS_PORT_STATUS\",\"ipv4_listening\":$IPV4_LISTENING,\"config_valid\":$CONFIG_VALID,\"timestamp\":$TS}" \
            1 2>/dev/null || true
    ) &
    
else
    log "mosquitto not running"
    
    # 服务停止时，不上报MQTT（因为MQTT服务本身可能不可用）
    # 仅记录到日志文件
    echo "[$(date '+%F %T')] [INFO] mosquitto service stopped" >> "$LOG_FILE"
fi

exit $EXIT
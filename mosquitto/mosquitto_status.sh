#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Mosquitto 状态查询脚本
# 版本: v1.0.0
# 功能: 检查服务运行状态和端口监听状态
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# 路径和变量定义
# -----------------------------------------------------------------------------
SERVICE_ID="mosquitto"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"

CONFIG_FILE="$BASE_DIR/configuration.yaml"
LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/status.log"

MOSQUITTO_PORT="1883"
MQTT_TIMEOUT="10"

# -----------------------------------------------------------------------------
# 辅助函数
# -----------------------------------------------------------------------------
ensure_directories() {
    mkdir -p "$LOG_DIR"
}

log() {
    echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"
}

load_mqtt_conf() {
    if [ -f "$CONFIG_FILE" ]; then
        MQTT_HOST=$(grep -Po '^[[:space:]]*host:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1 || echo "127.0.0.1")
        MQTT_PORT_CONFIG=$(grep -Po '^[[:space:]]*port:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1 || echo "1883")
        MQTT_USER=$(grep -Po '^[[:space:]]*username:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1 || echo "admin")
        MQTT_PASS=$(grep -Po '^[[:space:]]*password:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1 || echo "admin")
    else
        MQTT_HOST="127.0.0.1"
        MQTT_PORT_CONFIG="1883"
        MQTT_USER="admin"
        MQTT_PASS="admin"
    fi
}

get_mosquitto_pid() {
    local port_pid=$(netstat -tnlp 2>/dev/null | grep ":$MOSQUITTO_PORT " | awk '{print $7}' | cut -d'/' -f1 | head -n1)
    
    if [ -n "$port_pid" ] && [ "$port_pid" != "-" ]; then
        local process_name=$(ps -p "$port_pid" -o comm= 2>/dev/null)
        if [ "$process_name" = "mosquitto" ]; then
            echo "$port_pid"
            return 0
        fi
    fi
    return 1
}

mqtt_report() {
    local topic="$1"
    local payload="$2"
    
    # 检查 mosquitto 是否运行，如果没有运行则只记录日志不发送
    if ! get_mosquitto_pid > /dev/null 2>&1; then
        echo "[$(date '+%F %T')] [MQTT-OFFLINE] $topic -> $payload" >> "$LOG_FILE"
        return 0
    fi
    
    load_mqtt_conf
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT_CONFIG" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload" 2>/dev/null || true
    echo "[$(date '+%F %T')] [MQTT] $topic -> $payload" >> "$LOG_FILE"
}

# -----------------------------------------------------------------------------
# 主状态检查流程
# -----------------------------------------------------------------------------
ensure_directories

# -----------------------------------------------------------------------------
# 检查进程状态
# -----------------------------------------------------------------------------
PID=$(get_mosquitto_pid || true)
RUNTIME=""
PORT_STATUS="not_listening"
CONNECTIVITY_STATUS="unknown"

if [ -n "$PID" ]; then
    # 获取运行时间
    RUNTIME=$(ps -o etime= -p "$PID" | xargs)
    
    # 检查端口监听状态
    PORT_LISTEN=$(netstat -tulnp 2>/dev/null | grep ":$MOSQUITTO_PORT " | head -n1)
    if [ -n "$PORT_LISTEN" ]; then
        if echo "$PORT_LISTEN" | grep "0.0.0.0:$MOSQUITTO_PORT" > /dev/null; then
            PORT_STATUS="listening_global"
        elif echo "$PORT_LISTEN" | grep "127.0.0.1:$MOSQUITTO_PORT" > /dev/null; then
            PORT_STATUS="listening_local"
        else
            PORT_STATUS="listening_other"
        fi
    fi
    
    # 测试 MQTT 连接性（仅在端口监听时测试）
    if [ "$PORT_STATUS" != "not_listening" ]; then
        load_mqtt_conf
        if timeout "$MQTT_TIMEOUT" mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT_CONFIG" \
            -u "$MQTT_USER" -P "$MQTT_PASS" \
            -t "test/status" -m "ping" -q 1 2>/dev/null; then
            CONNECTIVITY_STATUS="connected"
            STATUS="running"
            EXIT=0
        else
            CONNECTIVITY_STATUS="auth_failed"
            STATUS="starting"
            EXIT=2
        fi
    else
        STATUS="starting"
        EXIT=2
    fi
else
    STATUS="stopped"
    EXIT=1
    PORT_STATUS="not_listening"
    CONNECTIVITY_STATUS="offline"
fi

# -----------------------------------------------------------------------------
# 处理命令行参数
# -----------------------------------------------------------------------------
case "${1:-}" in
    --json)
        echo "{\"status\":\"$STATUS\",\"pid\":\"$PID\",\"runtime\":\"$RUNTIME\",\"port_status\":\"$PORT_STATUS\",\"connectivity\":\"$CONNECTIVITY_STATUS\"}"
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
    mqtt_report "isg/status/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"running\",\"pid\":$PID,\"runtime\":\"$RUNTIME\",\"port_status\":\"$PORT_STATUS\",\"connectivity\":\"$CONNECTIVITY_STATUS\",\"timestamp\":$TS}"
    log "mosquitto 运行中 (PID=$PID, 运行时间=$RUNTIME, 端口状态=$PORT_STATUS, 连接性=$CONNECTIVITY_STATUS)"
    
    # 显示详细的监听信息
    if [ "$PORT_STATUS" = "listening_global" ]; then
        log "✅ 服务正在监听全局地址 0.0.0.0:$MOSQUITTO_PORT"
    elif [ "$PORT_STATUS" = "listening_local" ]; then
        log "⚠️  服务仅监听本地地址 127.0.0.1:$MOSQUITTO_PORT"
    elif [ "$PORT_STATUS" = "listening_other" ]; then
        log "⚠️  服务监听在其他地址: $(echo "$PORT_LISTEN" | awk '{print $4}')"
    fi
    
    if [ "$CONNECTIVITY_STATUS" = "connected" ]; then
        log "✅ MQTT 连接测试成功"
    elif [ "$CONNECTIVITY_STATUS" = "auth_failed" ]; then
        log "❌ MQTT 认证失败，请检查用户名密码"
    fi
    
elif [ "$STATUS" = "starting" ]; then
    mqtt_report "isg/status/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"starting\",\"pid\":$PID,\"runtime\":\"$RUNTIME\",\"port_status\":\"$PORT_STATUS\",\"connectivity\":\"$CONNECTIVITY_STATUS\",\"timestamp\":$TS}"
    log "mosquitto 启动中 (PID=$PID, 端口状态=$PORT_STATUS, 连接性=$CONNECTIVITY_STATUS)"
else
    mqtt_report "isg/status/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"stopped\",\"message\":\"service not running\",\"timestamp\":$TS}"
    log "mosquitto 未运行"
fi

exit $EXIT
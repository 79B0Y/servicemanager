#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# isgtrigger 状态查询脚本
# 版本: v1.0.0
# 功能: 检查服务运行状态和端口监听状态
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# 路径和变量定义
# -----------------------------------------------------------------------------
SERVICE_ID="isgtrigger"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"

CONFIG_FILE="$BASE_DIR/configuration.yaml"
LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/status.log"

ISGTRIGGER_PORT="61833"
ISGTRIGGER_INSTALL_DIR="/data/data/com.termux/files/usr/var/service/isgtrigger"
ISGTRIGGER_BINARY="$ISGTRIGGER_INSTALL_DIR/isgtrigger"

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

get_isgtrigger_pid() {
    local port_pid=$(netstat -tnlp 2>/dev/null | grep ":$ISGTRIGGER_PORT " | awk '{print $7}' | cut -d'/' -f1 | head -n1)
    
    if [ -n "$port_pid" ] && [ "$port_pid" != "-" ]; then
        local process_name=$(ps -p "$port_pid" -o comm= 2>/dev/null)
        if [ "$process_name" = "isgtrigger" ]; then
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
    if ! pgrep mosquitto > /dev/null 2>&1; then
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
# 检查安装状态
# -----------------------------------------------------------------------------
INSTALL_STATUS=false
ISGTRIGGER_VERSION="unknown"

# 通过dpkg检查包是否安装
if dpkg -s isgtrigger >/dev/null 2>&1; then
    ISGTRIGGER_VERSION=$(dpkg -s isgtrigger 2>/dev/null | grep 'Version' | awk '{print $2}' || echo "unknown")
    if [ "$ISGTRIGGER_VERSION" != "unknown" ] && [ -n "$ISGTRIGGER_VERSION" ]; then
        INSTALL_STATUS=true
        log "isgtrigger 已安装，版本: $ISGTRIGGER_VERSION"
    else
        log "isgtrigger 包存在但无法获取版本信息"
    fi
elif [ -f "$ISGTRIGGER_BINARY" ]; then
    # 二进制文件存在，认为已安装
    INSTALL_STATUS=true
    log "isgtrigger 二进制文件存在"
else
    log "isgtrigger 未安装"
fi

# -----------------------------------------------------------------------------
# 检查进程状态
# -----------------------------------------------------------------------------
PID=$(get_isgtrigger_pid || true)
RUNTIME=""
PORT_STATUS="not_listening"

if [ -n "$PID" ]; then
    # 获取运行时间
    RUNTIME=$(ps -o etime= -p "$PID" | xargs)
    
    # 检查端口监听状态
    PORT_LISTEN=$(netstat -tulnp 2>/dev/null | grep ":$ISGTRIGGER_PORT " | head -n1)
    if [ -n "$PORT_LISTEN" ]; then
        PORT_STATUS="listening"
        STATUS="running"
        EXIT=0
    else
        STATUS="starting"
        EXIT=2
    fi
else
    STATUS="stopped"
    EXIT=1
    PORT_STATUS="not_listening"
fi

# -----------------------------------------------------------------------------
# 处理命令行参数
# -----------------------------------------------------------------------------
case "${1:-}" in
    --json)
        echo "{\"status\":\"$STATUS\",\"pid\":\"$PID\",\"runtime\":\"$RUNTIME\",\"port_status\":\"$PORT_STATUS\",\"install\":$INSTALL_STATUS,\"version\":\"$ISGTRIGGER_VERSION\"}"
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
    mqtt_report "isg/status/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"running\",\"pid\":$PID,\"runtime\":\"$RUNTIME\",\"port_status\":\"$PORT_STATUS\",\"install\":$INSTALL_STATUS,\"version\":\"$ISGTRIGGER_VERSION\",\"timestamp\":$TS}"
    log "isgtrigger 运行中 (PID=$PID, 运行时间=$RUNTIME, 端口状态=$PORT_STATUS, 版本=$ISGTRIGGER_VERSION)"
    
    # 显示详细的监听信息
    if [ "$PORT_STATUS" = "listening" ]; then
        log "✅ 服务正在监听端口 $ISGTRIGGER_PORT"
        log "监听详情: $(echo "$PORT_LISTEN" | awk '{print $4}')"
    fi
    
elif [ "$STATUS" = "starting" ]; then
    mqtt_report "isg/status/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"starting\",\"pid\":$PID,\"runtime\":\"$RUNTIME\",\"port_status\":\"$PORT_STATUS\",\"install\":$INSTALL_STATUS,\"version\":\"$ISGTRIGGER_VERSION\",\"timestamp\":$TS}"
    log "isgtrigger 启动中 (PID=$PID, 端口状态=$PORT_STATUS, 版本=$ISGTRIGGER_VERSION)"
else
    mqtt_report "isg/status/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"stopped\",\"install\":$INSTALL_STATUS,\"version\":\"$ISGTRIGGER_VERSION\",\"message\":\"service not running\",\"timestamp\":$TS}"
    log "isgtrigger 未运行 (安装状态=$INSTALL_STATUS, 版本=$ISGTRIGGER_VERSION)"
fi

exit $EXIT
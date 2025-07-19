#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Node-RED 状态查询脚本
# 版本: v1.0.0
# 功能: 检查服务运行状态和 HTTP 接口状态
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# 路径和变量定义
# -----------------------------------------------------------------------------
SERVICE_ID="node-red"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"

CONFIG_FILE="$BASE_DIR/configuration.yaml"
LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/status.log"

PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
NR_INSTALL_DIR="/opt/node-red"
NR_PACKAGE_FILE="$NR_INSTALL_DIR/package.json"
NR_PORT="1880"
HTTP_TIMEOUT="10"

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

get_nr_pid() {
    local port_pid=$(netstat -tnlp 2>/dev/null | grep ":$NR_PORT " | awk '{print $7}' | cut -d'/' -f1 | head -n1)
    
    if [ -n "$port_pid" ] && [ "$port_pid" != "-" ]; then
        local cwd=$(ls -l /proc/$port_pid/cwd 2>/dev/null | grep -o 'node-red\|\.node-red' || true)
        if [ -n "$cwd" ]; then
            echo "$port_pid"
            return 0
        fi
    fi
    return 1
}

mqtt_report() {
    local topic="$1"
    local payload="$2"
    
    # 检查 MQTT broker 是否可用
    if ! nc -z 127.0.0.1 1883 2>/dev/null; then
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
NR_VERSION="unknown"

# 通过版本号检查程序是否安装
if proot-distro login "$PROOT_DISTRO" -- test -d "$NR_INSTALL_DIR" 2>/dev/null && \
   proot-distro login "$PROOT_DISTRO" -- test -f "$NR_PACKAGE_FILE" 2>/dev/null; then
    NR_VERSION=$(proot-distro login "$PROOT_DISTRO" -- bash -c "cd $NR_INSTALL_DIR && cat package.json | grep '\"node-red\"' | grep -v 'start' | sed -E 's/.*\"node-red\": *\"([^\"]+)\".*/\1/'" 2>/dev/null || echo "unknown")
    if [ "$NR_VERSION" != "unknown" ] && [ -n "$NR_VERSION" ]; then
        INSTALL_STATUS=true
        log "Node-RED 已安装，版本: $NR_VERSION"
    else
        log "Node-RED 安装目录存在但无法获取版本信息"
    fi
else
    log "Node-RED 未安装"
fi

# -----------------------------------------------------------------------------
# 检查进程状态
# -----------------------------------------------------------------------------
PID=$(get_nr_pid || true)
RUNTIME=""
HTTP_STATUS="offline"

if [ -n "$PID" ]; then
    # 获取运行时间
    RUNTIME=$(ps -o etime= -p "$PID" | xargs)
    
    # 检查 HTTP 接口状态
    if timeout "$HTTP_TIMEOUT" nc -z 127.0.0.1 "$NR_PORT" 2>/dev/null; then
        HTTP_STATUS="online"
        STATUS="running"
        EXIT=0
    else
        HTTP_STATUS="starting"
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
        echo "{\"status\":\"$STATUS\",\"pid\":\"$PID\",\"runtime\":\"$RUNTIME\",\"http_status\":\"$HTTP_STATUS\",\"port\":\"$NR_PORT\",\"install\":$INSTALL_STATUS,\"version\":\"$NR_VERSION\"}"
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
    mqtt_report "isg/status/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"running\",\"pid\":$PID,\"runtime\":\"$RUNTIME\",\"http_status\":\"$HTTP_STATUS\",\"port\":\"$NR_PORT\",\"install\":$INSTALL_STATUS,\"version\":\"$NR_VERSION\",\"timestamp\":$TS}"
    log "Node-RED 运行中 (PID=$PID, 运行时间=$RUNTIME, HTTP状态=$HTTP_STATUS, 端口=$NR_PORT, 版本=$NR_VERSION)"
    
    # 显示详细的状态信息
    if [ "$HTTP_STATUS" = "online" ]; then
        log "✅ HTTP 接口正常，可访问 http://127.0.0.1:$NR_PORT"
    else
        log "⚠️  HTTP 接口未就绪"
    fi
    
elif [ "$STATUS" = "starting" ]; then
    mqtt_report "isg/status/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"starting\",\"pid\":$PID,\"runtime\":\"$RUNTIME\",\"http_status\":\"$HTTP_STATUS\",\"port\":\"$NR_PORT\",\"install\":$INSTALL_STATUS,\"version\":\"$NR_VERSION\",\"timestamp\":$TS}"
    log "Node-RED 启动中 (PID=$PID, HTTP状态=$HTTP_STATUS, 版本=$NR_VERSION)"
else
    mqtt_report "isg/status/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"stopped\",\"install\":$INSTALL_STATUS,\"version\":\"$NR_VERSION\",\"message\":\"service not running\",\"timestamp\":$TS}"
    log "Node-RED 未运行 (安装状态=$INSTALL_STATUS, 版本=$NR_VERSION)"
fi

exit $EXIT
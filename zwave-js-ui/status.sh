#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Z-Wave JS UI 状态查询脚本
# 版本: v1.0.0
# 功能: 检查服务运行状态和端口状态
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# 路径和变量定义
# -----------------------------------------------------------------------------
SERVICE_ID="zwave-js-ui"
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"

CONFIG_FILE="$BASE_DIR/configuration.yaml"
LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/status.log"

ZWAVE_INSTALL_DIR="/root/.local/share/pnpm/global/5/node_modules/zwave-js-ui"
ZWAVE_PORT="8091"
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

get_zwave_pid() {
    local port_pid=$(netstat -tnlp 2>/dev/null | grep ":$ZWAVE_PORT " | awk '{print $7}' | cut -d'/' -f1 | head -n1)
    
    if [ -n "$port_pid" ] && [ "$port_pid" != "-" ]; then
        local cwd=$(ls -l /proc/$port_pid/cwd 2>/dev/null | grep -o 'zwave-js-ui' || true)
        if [ -n "$cwd" ]; then
            echo "$port_pid"
            return 0
        fi
    fi
    return 1
}

get_current_version() {
    proot-distro login "$PROOT_DISTRO" -- bash -c "
        export SHELL=/data/data/com.termux/files/usr/bin/bash
        export PNPM_HOME=\"/root/.local/share/pnpm\"
        export PATH=\"\$PNPM_HOME:\$PATH\"
        source ~/.bashrc 2>/dev/null || true
        
        if [ -f '$ZWAVE_INSTALL_DIR/package.json' ]; then
            grep -m1 '\"version\"' '$ZWAVE_INSTALL_DIR/package.json' | cut -d'\"' -f4
        elif command -v zwave-js-ui >/dev/null 2>&1; then
            zwave-js-ui --version 2>/dev/null | head -n1 || echo 'unknown'
        else
            echo 'unknown'
        fi
    " 2>/dev/null || echo "unknown"
}

mqtt_report() {
    local topic="$1"
    local payload="$2"
    
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
ZWAVE_VERSION="unknown"

# 通过版本号检查程序是否安装
ZWAVE_VERSION=$(get_current_version)
if [ "$ZWAVE_VERSION" != "unknown" ] && [ -n "$ZWAVE_VERSION" ]; then
    if proot-distro login "$PROOT_DISTRO" -- test -d "$ZWAVE_INSTALL_DIR"; then
        INSTALL_STATUS=true
        log "zwave-js-ui 已安装，版本: $ZWAVE_VERSION"
    else
        log "zwave-js-ui 版本信息存在但安装目录不存在"
    fi
else
    log "zwave-js-ui 未安装"
fi

# -----------------------------------------------------------------------------
# 检查进程状态
# -----------------------------------------------------------------------------
PID=$(get_zwave_pid || true)
RUNTIME=""
WEB_STATUS="offline"

if [ -n "$PID" ]; then
    # 获取运行时间
    RUNTIME=$(ps -o etime= -p "$PID" | xargs)
    
    # 检查 Web 界面状态 (端口 8091)
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
        echo "{\"status\":\"$STATUS\",\"pid\":\"$PID\",\"runtime\":\"$RUNTIME\",\"web_status\":\"$WEB_STATUS\",\"port\":\"$ZWAVE_PORT\",\"install\":$INSTALL_STATUS,\"version\":\"$ZWAVE_VERSION\"}"
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
    mqtt_report "isg/status/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"running\",\"pid\":$PID,\"runtime\":\"$RUNTIME\",\"web_status\":\"$WEB_STATUS\",\"port\":\"$ZWAVE_PORT\",\"install\":$INSTALL_STATUS,\"version\":\"$ZWAVE_VERSION\",\"timestamp\":$TS}"
    log "zwave-js-ui 运行中 (PID=$PID, 运行时间=$RUNTIME, Web状态=$WEB_STATUS, 端口=$ZWAVE_PORT, 版本=$ZWAVE_VERSION)"
    
    # 显示详细的监听信息
    LISTEN_STATUS=$(netstat -tulnp 2>/dev/null | grep ":$ZWAVE_PORT " | head -n1)
    if echo "$LISTEN_STATUS" | grep "0.0.0.0:$ZWAVE_PORT" > /dev/null; then
        log "✅ 服务正在监听全局地址 0.0.0.0:$ZWAVE_PORT"
    elif echo "$LISTEN_STATUS" | grep "127.0.0.1:$ZWAVE_PORT" > /dev/null; then
        log "⚠️  服务仅监听本地地址 127.0.0.1:$ZWAVE_PORT"
    elif [ -n "$LISTEN_STATUS" ]; then
        log "⚠️  服务监听在其他地址: $(echo "$LISTEN_STATUS" | awk '{print $4}')"
    fi
    
    if [ "$WEB_STATUS" = "online" ]; then
        log "✅ Web界面可访问"
    elif [ "$WEB_STATUS" = "starting" ]; then
        log "⚠️  Web界面启动中"
    fi
    
elif [ "$STATUS" = "starting" ]; then
    mqtt_report "isg/status/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"starting\",\"pid\":$PID,\"runtime\":\"$RUNTIME\",\"web_status\":\"$WEB_STATUS\",\"port\":\"$ZWAVE_PORT\",\"install\":$INSTALL_STATUS,\"version\":\"$ZWAVE_VERSION\",\"timestamp\":$TS}"
    log "zwave-js-ui 启动中 (PID=$PID, Web状态=$WEB_STATUS, 端口=$ZWAVE_PORT, 版本=$ZWAVE_VERSION)"
else
    mqtt_report "isg/status/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"stopped\",\"install\":$INSTALL_STATUS,\"version\":\"$ZWAVE_VERSION\",\"message\":\"service not running\",\"timestamp\":$TS}"
    log "zwave-js-ui 未运行 (安装状态=$INSTALL_STATUS, 版本=$ZWAVE_VERSION)"
fi

exit $EXIT
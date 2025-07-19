#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Z-Wave JS UI 状态查询脚本
# 版本: v1.0.0
# 功能: 检查服务运行状态和 HTTP 接口状态
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# 路径和变量定义
# -----------------------------------------------------------------------------
SERVICE_ID="zwave-js-ui"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"

CONFIG_FILE="$BASE_DIR/configuration.yaml"
LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/status.log"

PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
ZUI_INSTALL_PATH="/root/.pnpm-global/global/5/node_modules/zwave-js-ui"
ZUI_PACKAGE_FILE="$ZUI_INSTALL_PATH/package.json"
ZUI_PORT="8091"
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

get_zui_pid() {
    local port_pid=$(netstat -tnlp 2>/dev/null | grep ":$ZUI_PORT " | awk '{print $7}' | cut -d'/' -f1 | head -n1)
    
    if [ -n "$port_pid" ] && [ "$port_pid" != "-" ]; then
        local cwd=$(ls -l /proc/$port_pid/cwd 2>/dev/null | grep -o 'zwave\|node' || true)
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
ZUI_VERSION="unknown"

# 通过版本号检查程序是否安装
if proot-distro login "$PROOT_DISTRO" -- test -f "$ZUI_PACKAGE_FILE" 2>/dev/null; then
    ZUI_VERSION=$(proot-distro login "$PROOT_DISTRO" -- bash -c "
        export PNPM_HOME=/root/.pnpm-global
        export PATH=\$PNPM_HOME:\$PATH
        export SHELL=/bin/bash
        source ~/.bashrc 2>/dev/null || true
        
        if [ -f '$ZUI_PACKAGE_FILE' ]; then
            grep '\"version\"' '$ZUI_PACKAGE_FILE' | head -n1 | sed -E 's/.*\"version\": *\"([^\"]+)\".*/\1/'
        else
            echo 'unknown'
        fi
    " 2>/dev/null || echo "unknown")
    
    if [ "$ZUI_VERSION" != "unknown" ] && [ -n "$ZUI_VERSION" ]; then
        INSTALL_STATUS=true
        log "Z-Wave JS UI 已安装，版本: $ZUI_VERSION"
    else
        log "Z-Wave JS UI 安装目录存在但无法获取版本信息"
    fi
else
    # 如果文件不存在，检查是否通过其他方式安装（比如全局包）
    ZUI_VERSION=$(proot-distro login "$PROOT_DISTRO" -- bash -c "
        export PNPM_HOME=/root/.pnpm-global
        export PATH=\$PNPM_HOME:\$PATH
        export SHELL=/bin/bash
        source ~/.bashrc 2>/dev/null || true
        
        if command -v pnpm >/dev/null 2>&1; then
            pnpm list -g zwave-js-ui 2>/dev/null | grep zwave-js-ui | sed -E 's/.*zwave-js-ui@([0-9.]+).*/\1/' || echo 'unknown'
        else
            echo 'unknown'
        fi
    " 2>/dev/null || echo "unknown")
    
    if [ "$ZUI_VERSION" != "unknown" ] && [ -n "$ZUI_VERSION" ]; then
        INSTALL_STATUS=true
        log "Z-Wave JS UI 已安装 (全局包)，版本: $ZUI_VERSION"
    else
        log "Z-Wave JS UI 未安装"
    fi
fi

# -----------------------------------------------------------------------------
# 检查进程状态
# -----------------------------------------------------------------------------
PID=$(get_zui_pid || true)
RUNTIME=""
HTTP_STATUS="offline"
ZWAVE_STATUS="unknown"

if [ -n "$PID" ]; then
    # 获取运行时间
    RUNTIME=$(ps -o etime= -p "$PID" | xargs)
    
    # 检查 HTTP 接口状态
    if timeout "$HTTP_TIMEOUT" nc -z 127.0.0.1 "$ZUI_PORT" 2>/dev/null; then
        HTTP_STATUS="online"
        STATUS="running"
        EXIT=0
        
        # 检查 Z-Wave 状态 (简单的 HTTP 检查)
        # Z-Wave JS UI 通常在正常运行时会响应 HTTP 请求
        if timeout 5 curl -s "http://127.0.0.1:$ZUI_PORT" >/dev/null 2>&1; then
            ZWAVE_STATUS="online"
        else
            ZWAVE_STATUS="starting"
        fi
    else
        HTTP_STATUS="starting"
        STATUS="starting"
        EXIT=2
    fi
else
    STATUS="stopped"
    EXIT=1
    HTTP_STATUS="offline"
    ZWAVE_STATUS="offline"
fi

# -----------------------------------------------------------------------------
# 处理命令行参数
# -----------------------------------------------------------------------------
case "${1:-}" in
    --json)
        echo "{\"status\":\"$STATUS\",\"pid\":\"$PID\",\"runtime\":\"$RUNTIME\",\"http_status\":\"$HTTP_STATUS\",\"zwave_status\":\"$ZWAVE_STATUS\",\"port\":\"$ZUI_PORT\",\"install\":$INSTALL_STATUS,\"version\":\"$ZUI_VERSION\"}"
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
    mqtt_report "isg/status/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"running\",\"pid\":$PID,\"runtime\":\"$RUNTIME\",\"http_status\":\"$HTTP_STATUS\",\"zwave_status\":\"$ZWAVE_STATUS\",\"port\":\"$ZUI_PORT\",\"install\":$INSTALL_STATUS,\"version\":\"$ZUI_VERSION\",\"timestamp\":$TS}"
    log "Z-Wave JS UI 运行中 (PID=$PID, 运行时间=$RUNTIME, HTTP状态=$HTTP_STATUS, Z-Wave状态=$ZWAVE_STATUS, 端口=$ZUI_PORT, 版本=$ZUI_VERSION)"
    
    # 显示详细的状态信息
    if [ "$HTTP_STATUS" = "online" ]; then
        log "✅ HTTP 接口正常，可访问 http://127.0.0.1:$ZUI_PORT"
    else
        log "⚠️  HTTP 接口未就绪"
    fi
    
    if [ "$ZWAVE_STATUS" = "online" ]; then
        log "✅ Z-Wave 控制器状态正常"
    elif [ "$ZWAVE_STATUS" = "starting" ]; then
        log "⚠️  Z-Wave 控制器启动中"
    else
        log "❌ Z-Wave 控制器离线"
    fi
    
    # 检查服务监听地址
    LISTEN_INFO=$(netstat -tulnp 2>/dev/null | grep ":$ZUI_PORT " | head -n1)
    if [ -n "$LISTEN_INFO" ]; then
        LISTEN_ADDR=$(echo "$LISTEN_INFO" | awk '{print $4}')
        if [[ "$LISTEN_ADDR" == ":::$ZUI_PORT" ]]; then
            log "ℹ️  服务监听在所有IPv6地址: $LISTEN_ADDR"
        elif [[ "$LISTEN_ADDR" == "0.0.0.0:$ZUI_PORT" ]]; then
            log "ℹ️  服务监听在所有IPv4地址: $LISTEN_ADDR"
        elif [[ "$LISTEN_ADDR" == "127.0.0.1:$ZUI_PORT" ]]; then
            log "ℹ️  服务监听在本地地址: $LISTEN_ADDR"
        else
            log "ℹ️  服务监听地址: $LISTEN_ADDR"
        fi
    fi
    
elif [ "$STATUS" = "starting" ]; then
    mqtt_report "isg/status/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"starting\",\"pid\":$PID,\"runtime\":\"$RUNTIME\",\"http_status\":\"$HTTP_STATUS\",\"zwave_status\":\"$ZWAVE_STATUS\",\"port\":\"$ZUI_PORT\",\"install\":$INSTALL_STATUS,\"version\":\"$ZUI_VERSION\",\"timestamp\":$TS}"
    log "Z-Wave JS UI 启动中 (PID=$PID, HTTP状态=$HTTP_STATUS, Z-Wave状态=$ZWAVE_STATUS, 版本=$ZUI_VERSION)"
else
    mqtt_report "isg/status/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"stopped\",\"install\":$INSTALL_STATUS,\"version\":\"$ZUI_VERSION\",\"message\":\"service not running\",\"timestamp\":$TS}"
    log "Z-Wave JS UI 未运行 (安装状态=$INSTALL_STATUS, 版本=$ZUI_VERSION)"
fi

exit $EXIT
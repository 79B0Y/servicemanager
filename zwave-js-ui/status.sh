#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Z-Wave JS UI 状态查询脚本（优化版）
# 版本: v1.0.1
# 功能: 检查服务运行状态和 HTTP 接口状态，优化安装检测速度
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
ZUI_PORT="8091"
HTTP_TIMEOUT="5"

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
# 快速检查安装状态（优化版）
# -----------------------------------------------------------------------------
check_installation_fast() {
    # 方法1: 检查安装目录是否存在（最快）
    if proot-distro login "$PROOT_DISTRO" -- test -d "$ZUI_INSTALL_PATH" 2>/dev/null; then
        return 0
    fi
    
    # 方法2: 检查 pnpm 全局包列表（快速检查）
    local pnpm_check=$(proot-distro login "$PROOT_DISTRO" -- bash -c "
        export PNPM_HOME=/root/.pnpm-global
        export PATH=\$PNPM_HOME:\$PATH
        export SHELL=/bin/bash
        source ~/.bashrc 2>/dev/null || true
        
        if command -v pnpm >/dev/null 2>&1; then
            pnpm list -g --depth=0 2>/dev/null | grep -q 'zwave-js-ui' && echo 'installed' || echo 'not_installed'
        else
            echo 'not_installed'
        fi
    " 2>/dev/null || echo "not_installed")
    
    [ "$pnpm_check" = "installed" ]
}

get_version_fast() {
    # 优先从 package.json 获取（最快）
    local version=$(proot-distro login "$PROOT_DISTRO" -- bash -c "
        if [ -f '$ZUI_INSTALL_PATH/package.json' ]; then
            grep '\"version\"' '$ZUI_INSTALL_PATH/package.json' | head -n1 | sed -E 's/.*\"version\": *\"([^\"]+)\".*/\1/'
        else
            echo 'unknown'
        fi
    " 2>/dev/null || echo "unknown")
    
    echo "$version"
}

# -----------------------------------------------------------------------------
# 主状态检查流程
# -----------------------------------------------------------------------------
ensure_directories

# -----------------------------------------------------------------------------
# 检查安装状态（快速检测）
# -----------------------------------------------------------------------------
INSTALL_STATUS=false
ZUI_VERSION="unknown"

if check_installation_fast; then
    INSTALL_STATUS=true
    # 只有在需要详细信息时才获取版本
    case "${1:-}" in
        --json|--verbose)
            ZUI_VERSION=$(get_version_fast)
            ;;
        *)
            ZUI_VERSION="installed"
            ;;
    esac
    log "Z-Wave JS UI 已安装"
else
    log "Z-Wave JS UI 未安装"
fi

# -----------------------------------------------------------------------------
# 检查进程状态
# -----------------------------------------------------------------------------
PID=$(get_zui_pid || true)
RUNTIME=""
HTTP_STATUS="offline"
ZWAVE_STATUS="unknown"
STATUS="stopped"
EXIT=1

if [ -n "$PID" ]; then
    # 获取运行时间
    RUNTIME=$(ps -o etime= -p "$PID" 2>/dev/null | xargs || echo "")
    
    # 检查 HTTP 接口状态
    if timeout "$HTTP_TIMEOUT" nc -z 127.0.0.1 "$ZUI_PORT" 2>/dev/null; then
        HTTP_STATUS="online"
        STATUS="running"
        EXIT=0
        
        # 检查 Z-Wave 状态 (简单的 HTTP 检查)
        if timeout 3 curl -s "http://127.0.0.1:$ZUI_PORT" >/dev/null 2>&1; then
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
    # 检查是否有启动脚本正在运行
    if pgrep -f "$SERVICE_DIR/start.sh" > /dev/null 2>&1; then
        STATUS="starting"
        EXIT=2
    else
        STATUS="stopped"
        EXIT=1
    fi
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
    --check-install)
        echo "$INSTALL_STATUS"
        exit 0
        ;;
    --simple)
        echo "$STATUS"
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
    
    log "Z-Wave JS UI 运行中 (PID=$PID, 运行时间=$RUNTIME, HTTP状态=$HTTP_STATUS, Z-Wave状态=$ZWAVE_STATUS, 端口=$ZUI_PORT)"
    
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
    
    # 标准化输出最后一行状态
    echo "running"
    
elif [ "$STATUS" = "starting" ]; then
    mqtt_report "isg/status/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"starting\",\"pid\":\"$PID\",\"runtime\":\"$RUNTIME\",\"http_status\":\"$HTTP_STATUS\",\"zwave_status\":\"$ZWAVE_STATUS\",\"port\":\"$ZUI_PORT\",\"install\":$INSTALL_STATUS,\"version\":\"$ZUI_VERSION\",\"timestamp\":$TS}"
    
    log "Z-Wave JS UI 启动中 (PID=$PID, HTTP状态=$HTTP_STATUS, Z-Wave状态=$ZWAVE_STATUS)"
    
    # 标准化输出最后一行状态
    echo "starting"
    
else
    mqtt_report "isg/status/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"stopped\",\"install\":$INSTALL_STATUS,\"version\":\"$ZUI_VERSION\",\"message\":\"service not running\",\"timestamp\":$TS}"
    
    log "Z-Wave JS UI 未运行 (安装状态=$INSTALL_STATUS)"
    
    # 标准化输出最后一行状态
    echo "stopped"
fi

exit $EXIT

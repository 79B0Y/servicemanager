#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Node-RED 状态查询脚本 (Termux 优化版 + MQTT 上报 + 模式控制 + JSON模式)
# 版本: v2.2.0
# =============================================================================

set -euo pipefail

SERVICE_ID="node-red"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"
LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/status.log"
CONFIG_FILE="$BASE_DIR/configuration.yaml"

PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
NODERED_INSTALL_PATH="/opt/node-red/node_modules/node-red"
NODERED_PORT=1880
HTTP_TIMEOUT=5

CHECK_MODE=${STATUS_MODE:-0}

IS_JSON_MODE=0
if [[ "${1:-}" == "--json" ]]; then
    IS_JSON_MODE=1
fi

ensure_directories() {
    mkdir -p "$LOG_DIR"
}

log() {
    if [[ "$IS_JSON_MODE" -eq 0 ]]; then
        echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"
    fi
}

load_mqtt_conf() {
    if [ -f "$CONFIG_FILE" ]; then
        MQTT_HOST=$(grep -Po '^[[:space:]]*host:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1 || echo "127.0.0.1")
        MQTT_PORT=$(grep -Po '^[[:space:]]*port:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1 || echo "1883")
        MQTT_USER=$(grep -Po '^[[:space:]]*username:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1 || echo "admin")
        MQTT_PASS=$(grep -Po '^[[:space:]]*password:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1 || echo "admin")
    else
        MQTT_HOST="127.0.0.1"
        MQTT_PORT="1883"
        MQTT_USER="admin"
        MQTT_PASS="admin"
    fi
}

mqtt_report() {
    local topic="$1"
    local payload="$2"

    load_mqtt_conf
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload" 2>/dev/null || true

    if [[ "$IS_JSON_MODE" -eq 0 ]]; then
        log "[MQTT] $topic -> $payload"
    fi
}

check_installation_proot() {
    proot-distro login "$PROOT_DISTRO" -- test -d "$NODERED_INSTALL_PATH"
}

get_version_proot() {
    proot-distro login "$PROOT_DISTRO" -- bash -c "
        if [ -f '$NODERED_INSTALL_PATH/package.json' ]; then
            grep '\"version\"' '$NODERED_INSTALL_PATH/package.json' | head -n1 | sed -E 's/.*\"version\": *\"([^\"]+)\".*/\1/'
        else
            echo 'unknown'
        fi
    " 2>/dev/null || echo "unknown"
}

get_nodered_pid() {
    local result=$(netstat -tnlp 2>/dev/null | grep ":$NODERED_PORT " || true)
    if [ -n "$result" ]; then
        echo "$result" | awk '{print $7}' | cut -d'/' -f1 | head -n1
    else
        echo ""
    fi
}

# --- 主流程 ---
ensure_directories

PID=""
RUNTIME=""
HTTP_STATUS="offline"
STATUS="stopped"
EXIT=1
INSTALL_STATUS=false
NODERED_VERSION="unknown"

if [ "$CHECK_MODE" != "2" ]; then
    PID=$(get_nodered_pid)
    if [ -n "$PID" ]; then
        RUNTIME=$(ps -o etime= -p "$PID" 2>/dev/null | xargs || echo "")

        if timeout "$HTTP_TIMEOUT" nc -z 127.0.0.1 "$NODERED_PORT" 2>/dev/null; then
            HTTP_STATUS="online"
            STATUS="running"
            EXIT=0
        else
            HTTP_STATUS="starting"
            STATUS="starting"
            EXIT=2
        fi

        INSTALL_STATUS=true
        NODERED_VERSION="running"
        log "Node-RED 处于运行状态，标记已安装"
    fi
fi

if [ "$CHECK_MODE" = "2" ] || { [ "$CHECK_MODE" = "0" ] && [ "$INSTALL_STATUS" = false ]; }; then
    log "检查 Node-RED 是否已安装"
    if check_installation_proot; then
        INSTALL_STATUS=true
        NODERED_VERSION=$(get_version_proot)
        log "Node-RED 已安装，版本: $NODERED_VERSION"
    else
        log "Node-RED 未安装"
        NODERED_VERSION="unknown"
    fi
fi

if [ "$CHECK_MODE" = "1" ] && [ "$STATUS" = "stopped" ]; then
    INSTALL_STATUS=false
    NODERED_VERSION="unknown"
fi

STATUS_JSON="{\"service\":\"$SERVICE_ID\",\"status\":\"$STATUS\",\"pid\":\"$PID\",\"runtime\":\"$RUNTIME\",\"http_status\":\"$HTTP_STATUS\",\"port\":\"$NODERED_PORT\",\"install\":$INSTALL_STATUS,\"version\":\"$NODERED_VERSION\",\"timestamp\":$(date +%s)}"

mqtt_report "isg/status/$SERVICE_ID/status" "$STATUS_JSON"

echo "$STATUS_JSON"
exit $EXIT

#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Z-Wave JS UI 通用状态查询脚本（修正版）
# 版本: v1.1.0
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# 基础配置
# -----------------------------------------------------------------------------
SERVICE_ID="zwave-js-ui"
SERVICE_PORT="8091"
PROOT_DISTRO="ubuntu"
ZUI_INSTALL_PATH="/root/.pnpm-global/global/5/node_modules/zwave-js-ui"
HTTP_TIMEOUT=5
CONFIG_FILE="/data/data/com.termux/files/home/servicemanager/configuration.yaml"
LOG_FILE="/data/data/com.termux/files/home/servicemanager/$SERVICE_ID/logs/status.log"
STATUS_MODE="${STATUS_MODE:-0}"  # 默认模式0

mkdir -p "$(dirname "$LOG_FILE")"

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

mqtt_report() {
    local topic="$1"
    local payload="$2"
    load_mqtt_conf
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT_CONFIG" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload" 2>/dev/null || true
    echo "[$(date '+%F %T')] [MQTT] $topic -> $payload" >> "$LOG_FILE"
}

get_service_pid() {
    netstat -tnlp 2>/dev/null | grep ":$SERVICE_PORT " | awk '{print $7}' | cut -d'/' -f1 | head -n1
}

check_http_status() {
    timeout "$HTTP_TIMEOUT" nc -z 127.0.0.1 "$SERVICE_PORT" >/dev/null 2>&1 && echo "online" || echo "offline"
}

check_install() {
    proot-distro login "$PROOT_DISTRO" -- bash -c "test -d '$ZUI_INSTALL_PATH'" 2>/dev/null && echo "true" || echo "false"
}

get_version() {
    proot-distro login "$PROOT_DISTRO" -- bash -c "
        if [ -f '$ZUI_INSTALL_PATH/package.json' ]; then
            grep -Po '\"version\": *\"\K[^\"]+' '$ZUI_INSTALL_PATH/package.json'
        else
            echo 'unknown'
        fi
    " 2>/dev/null
}

TS=$(date +%s)
PID=""
RUNTIME=""
STATUS="stopped"
INSTALL_STATUS="false"
VERSION="unknown"
HTTP_STATUS="offline"

if [ "$STATUS_MODE" -eq 2 ]; then
    INSTALL_STATUS=$(check_install)
    VERSION=$(get_version)
    STATUS="stopped"
elif [ "$STATUS_MODE" -eq 1 ]; then
    PID=$(get_service_pid || echo "")
    if [ -n "$PID" ]; then
        STATUS="running"
        INSTALL_STATUS="true"
        VERSION="running"
        HTTP_STATUS=$(check_http_status)
        RUNTIME=$(ps -o etime= -p "$PID" 2>/dev/null | xargs || echo "")
    fi
else
    INSTALL_STATUS=$(check_install)
    VERSION=$(get_version)

    PID=$(get_service_pid || echo "")
    if [ -n "$PID" ]; then
        STATUS="running"
        HTTP_STATUS=$(check_http_status)
        RUNTIME=$(ps -o etime= -p "$PID" 2>/dev/null | xargs || echo "")
    fi
fi

RESULT_JSON=$(cat <<EOF
{
    "service": "$SERVICE_ID",
    "status": "$STATUS",
    "pid": "${PID:-null}",
    "runtime": "${RUNTIME:-null}",
    "http_status": "$HTTP_STATUS",
    "port": "$SERVICE_PORT",
    "install": $INSTALL_STATUS,
    "version": "$VERSION",
    "timestamp": $TS
}
EOF
)

echo "$RESULT_JSON"
mqtt_report "isg/status/$SERVICE_ID/status" "$RESULT_JSON"

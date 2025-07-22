#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Mosquitto 状态查询脚本（优化版）
# 版本: v1.2.0
# 功能: 检查服务运行状态、端口、HTTP连接性，支持多种模式，MQTT上报，支持 --json 输出
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# 路径和变量定义
# -----------------------------------------------------------------------------
SERVICE_ID="mosquitto"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
CONFIG_FILE="$BASE_DIR/configuration.yaml"
LOG_DIR="$BASE_DIR/$SERVICE_ID/logs"
LOG_FILE="$LOG_DIR/status.log"
SERVICE_PORT="1883"
HTTP_TIMEOUT=5

STATUS_MODE=${STATUS_MODE:-0}  # 默认模式

IS_JSON_MODE=0
if [[ "${1:-}" == "--json" ]]; then
    IS_JSON_MODE=1
fi

# -----------------------------------------------------------------------------
# 加载 MQTT 配置
# -----------------------------------------------------------------------------
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

log() {
    echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"
}

mqtt_report() {
    local topic="$1"
    local payload="$2"

    load_mqtt_conf
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" \
        -t "$topic" -m "$payload" 2>/dev/null || true

    if [[ "$IS_JSON_MODE" -eq 0 ]]; then
        log "[MQTT] $topic -> $payload"
    fi
}

get_service_pid() {
    netstat -tnlp 2>/dev/null | grep ":$SERVICE_PORT " | awk '{print $7}' | cut -d'/' -f1 | head -n1 || true
}

check_http_status() {
    if nc -z 127.0.0.1 "$SERVICE_PORT"; then
        echo "online"
    else
        echo "offline"
    fi
}

ensure_directories() {
    mkdir -p "$LOG_DIR"
}

ensure_directories

TIMESTAMP=$(date +%s)
PID=""
RUNTIME=""
INSTALL=false
VERSION="unknown"
HTTP_STATUS="offline"

PID=$(get_service_pid)

if [ -n "$PID" ]; then
    INSTALL=true
    VERSION=$(mosquitto -h 2>&1 | grep -Po 'version \K[\d.]+' || echo "unknown")
    RUNTIME=$(ps -o etime= -p "$PID" | xargs)
    HTTP_STATUS=$(check_http_status)
else
    INSTALL_STATUS=$(command -v mosquitto >/dev/null 2>&1 && echo true || echo false)
    INSTALL=$INSTALL_STATUS
fi

case "$STATUS_MODE" in
    0)
        STATUS=$([[ -n "$PID" ]] && echo "running" || echo "stopped")
        ;;
    1)
        STATUS=$([[ -n "$PID" ]] && echo "running" || echo "stopped")
        INSTALL=true
        VERSION="running"
        ;;
    2)
        STATUS="unknown"
        ;;
    *)
        STATUS="unknown"
        ;;
esac

STATUS_JSON=$(jq -n \
    --arg service "$SERVICE_ID" \
    --arg status "$STATUS" \
    --arg pid "$PID" \
    --arg runtime "$RUNTIME" \
    --arg http_status "$HTTP_STATUS" \
    --argjson install $INSTALL \
    --arg version "$VERSION" \
    --arg port "$SERVICE_PORT" \
    --argjson timestamp $TIMESTAMP \
    '{service: $service, status: $status, pid: $pid, runtime: $runtime, http_status: $http_status, port: $port, install: $install, version: $version, timestamp: $timestamp}'
)

mqtt_report "isg/status/$SERVICE_ID/status" "$STATUS_JSON"

if [[ "$IS_JSON_MODE" -eq 1 ]]; then
    echo "$STATUS_JSON"
    exit 0
fi

log "状态查询结果"
echo "$STATUS_JSON"

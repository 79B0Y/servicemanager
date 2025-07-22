#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Home Assistant 状态查询脚本（通用服务状态模式）
# 版本: v2.0.1
# =============================================================================
set -euo pipefail

# =============================================================================
# 基本配置
# =============================================================================
SERVICE_ID="hass"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
CONFIG_FILE="$BASE_DIR/configuration.yaml"

SERVICE_PORT="8123"
SERVICE_INSTALL_PATH="/root/.homeassistant"
HA_BINARY="/root/homeassistant/bin/hass"

LOG_DIR="$BASE_DIR/$SERVICE_ID/logs"
LOG_FILE="$LOG_DIR/status.log"

STATUS_MODE="${STATUS_MODE:-0}"  # 0=全检，1=仅运行，2=仅安装
HTTP_TIMEOUT=5

# =============================================================================
# 工具函数
# =============================================================================
ensure_directories() { mkdir -p "$LOG_DIR"; }

log() {
    echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"
}

load_mqtt_conf() {
    MQTT_HOST=$(grep -Po '^[[:space:]]*host:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1 || echo "127.0.0.1")
    MQTT_PORT=$(grep -Po '^[[:space:]]*port:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1 || echo "1883")
    MQTT_USER=$(grep -Po '^[[:space:]]*username:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1 || echo "admin")
    MQTT_PASS=$(grep -Po '^[[:space:]]*password:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1 || echo "admin")
}

mqtt_report() {
    local topic="$1" payload="$2"
    load_mqtt_conf
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload" || true
    log "[MQTT] $topic -> $payload"
}

get_service_pid() {
    pgrep -f '[h]omeassistant' | while read -r pid; do
        netstat -tnlp 2>/dev/null | grep -q ":$SERVICE_PORT.*$pid/" && echo "$pid" && return 0
    done
    return 1
}

check_http_status() {
    nc -z 127.0.0.1 "$SERVICE_PORT" >/dev/null 2>&1 && echo "online" || echo "offline"
}

check_install_status() {
    proot-distro login ubuntu -- bash -c "test -f '$HA_BINARY'" 2>/dev/null && echo "true" || echo "false"
}

# =============================================================================
# 主流程
# =============================================================================
ensure_directories
TS=$(date +%s)

PID="" RUNTIME="" HTTP_STATUS="offline" INSTALL_STATUS="false" VERSION="unknown"
STATUS="stopped" EXIT_CODE=1

if [[ "$STATUS_MODE" != "2" ]]; then
    PID=$(get_service_pid || true)
    if [ -n "$PID" ]; then
        RUNTIME=$(ps -o etime= -p "$PID" | xargs || echo "")
        HTTP_STATUS=$(check_http_status)
        if [[ "$HTTP_STATUS" == "online" ]]; then
            STATUS="running"
            EXIT_CODE=0
        else
            STATUS="starting"
            EXIT_CODE=2
        fi
    fi
fi

if [[ "$STATUS_MODE" != "1" ]]; then
    INSTALL_STATUS=$(check_install_status)
    if [[ "$INSTALL_STATUS" == "true" && "$VERSION" == "unknown" ]]; then
        VERSION=$(proot-distro login ubuntu -- bash -c "$HA_BINARY --version" 2>/dev/null | head -n1 || echo "unknown")
    fi
fi

# 运行中但未检测到安装，强制标记 install=true
if [[ "$STATUS" == "running" && "$INSTALL_STATUS" != "true" ]]; then
    INSTALL_STATUS="true"
    log "运行中，强制设定 INSTALL_STATUS=true"
fi

RESULT_JSON=$(jq -n \
    --arg service "$SERVICE_ID" \
    --arg status "$STATUS" \
    --arg pid "$PID" \
    --arg runtime "$RUNTIME" \
    --arg http_status "$HTTP_STATUS" \
    --arg port "$SERVICE_PORT" \
    --argjson install "$INSTALL_STATUS" \
    --arg version "$VERSION" \
    --argjson timestamp "$TS" \
    '{service: $service, status: $status, pid: $pid, runtime: $runtime, http_status: $http_status, port: ($port|tonumber), install: $install, version: $version, timestamp: $timestamp}'
)

if [[ "${1:-}" == "--json" ]]; then
    mqtt_report "isg/status/$SERVICE_ID/status" "$RESULT_JSON"
    echo "$RESULT_JSON"
    exit 0
fi

mqtt_report "isg/status/$SERVICE_ID/status" "$RESULT_JSON"
log "状态检查完成"
echo "$RESULT_JSON"
exit $EXIT_CODE

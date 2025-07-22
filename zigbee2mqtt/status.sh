#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# 通用服务状态查询脚本 - JSON模式增强版
# 版本: v2.2.0
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common_paths.sh" || {
    echo "❌ Error: Cannot load common paths"
    exit 1
}

LOG_FILE="$LOG_FILE_STATUS"
ensure_directories

SERVICE_PORT="${SERVICE_PORT:-8080}"
SERVICE_INSTALL_PATH="${Z2M_INSTALL_DIR:-/opt/zigbee2mqtt}"
HTTP_CHECK_PATH="${HTTP_CHECK_PATH:-/}"
STATUS_MODE="${STATUS_MODE:-0}"

IS_JSON_MODE=0
if [[ "${1:-}" == "--json" ]]; then
    IS_JSON_MODE=1
fi

TS=$(date +%s)
PID=""
RUNTIME=""
HTTP_STATUS="offline"
INSTALL_STATUS=false
VERSION="unknown"

get_service_pid() {
    netstat -tnlp 2>/dev/null | grep ":$SERVICE_PORT " | awk '{print $7}' | cut -d'/' -f1 | head -n1 || true
}

check_http_status() {
    if command -v nc >/dev/null 2>&1; then
        nc -z 127.0.0.1 "$SERVICE_PORT" >/dev/null 2>&1 && echo "online" || echo "offline"
    elif command -v curl >/dev/null 2>&1; then
        curl -fs --max-time 3 "http://127.0.0.1:$SERVICE_PORT$HTTP_CHECK_PATH" >/dev/null && echo "online" && return
    fi
    echo "offline"
}

check_install_status() {
    if proot-distro login "$PROOT_DISTRO" -- test -d "$SERVICE_INSTALL_PATH"; then
        INSTALL_STATUS=true
        VERSION=$(proot-distro login "$PROOT_DISTRO" -- bash -c "cd '$SERVICE_INSTALL_PATH' && grep -m1 '\"version\"' package.json | sed -E 's/.*\"version\"[[:space:]]*:[[:space:]]*\"([^\"]+)\".*/\1/'" 2>/dev/null || echo "unknown")
    fi
}

log() {
    if [[ "$IS_JSON_MODE" -eq 0 ]]; then
        echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"
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

PID=$(get_service_pid)
[ -n "$PID" ] && RUNTIME=$(ps -o etime= -p "$PID" | xargs)

case "$STATUS_MODE" in
    0)
        check_install_status
        HTTP_STATUS=$(check_http_status)
        ;;
    1)
        [ -n "$PID" ] && INSTALL_STATUS=true && VERSION="running" && HTTP_STATUS=$(check_http_status)
        ;;
    2)
        check_install_status
        ;;
    *)
        echo "❌ Error: Invalid STATUS_MODE=$STATUS_MODE"
        exit 99
        ;;
esac

if [ -n "$PID" ]; then
    if [ "$HTTP_STATUS" = "offline" ]; then
        STATUS="starting"
        EXIT=2
    else
        STATUS="running"
        EXIT=0
    fi
else
    STATUS="stopped"
    EXIT=1
fi

RESULT_JSON=$(jq -n \
    --arg service "$SERVICE_ID" \
    --arg status "$STATUS" \
    --arg pid "$PID" \
    --arg runtime "$RUNTIME" \
    --arg http_status "$HTTP_STATUS" \
    --argjson port "$SERVICE_PORT" \
    --argjson install "$INSTALL_STATUS" \
    --arg version "$VERSION" \
    --argjson timestamp "$TS" \
    '{service:$service, status:$status, pid:$pid, runtime:$runtime, http_status:$http_status, port:$port, install:$install, version:$version, timestamp:$timestamp}'
)

mqtt_report "isg/status/$SERVICE_ID/status" "$RESULT_JSON"

if [[ "$IS_JSON_MODE" -eq 1 ]]; then
    echo "$RESULT_JSON"
else
    log "状态查询完成"
    echo "$RESULT_JSON"
fi

exit $EXIT

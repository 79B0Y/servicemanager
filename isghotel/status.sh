#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# isghotel 状态查询脚本（优化统一版）
# 版本: v1.1.1
# =============================================================================

set -euo pipefail

# 基础配置
SERVICE_ID="isghotel"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"
CONFIG_FILE="$BASE_DIR/configuration.yaml"
LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/status.log"

SERVICE_PORT="22153"
BINARY_PATH="/data/data/com.termux/files/usr/var/service/isghotel/isghotel"
STATUS_MODE="${STATUS_MODE:-0}"

IS_JSON_MODE=0
IS_QUIET_MODE=0

# 解析参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --json) IS_JSON_MODE=1 ;;
        --quiet) IS_QUIET_MODE=1 ;;
    esac
    shift
done

# 工具函数
ensure_directories() { mkdir -p "$LOG_DIR" 2>/dev/null || true; }
log() { [[ "$IS_QUIET_MODE" -eq 0 ]] && echo "[$(date '+%F %T')] $*" >> "$LOG_FILE"; }

load_mqtt_conf() {
    MQTT_HOST=$(grep -Po '^[[:space:]]*host:[[:space:]]*\K.*' "$CONFIG_FILE" 2>/dev/null | head -n1 || echo "127.0.0.1")
    MQTT_PORT=$(grep -Po '^[[:space:]]*port:[[:space:]]*\K.*' "$CONFIG_FILE" 2>/dev/null | head -n1 || echo "1883")
    MQTT_USER=$(grep -Po '^[[:space:]]*username:[[:space:]]*\K.*' "$CONFIG_FILE" 2>/dev/null | head -n1 || echo "admin")
    MQTT_PASS=$(grep -Po '^[[:space:]]*password:[[:space:]]*\K.*' "$CONFIG_FILE" 2>/dev/null | head -n1 || echo "admin")
}

mqtt_report() {
    [[ "$IS_QUIET_MODE" -eq 1 ]] && return 0
    load_mqtt_conf
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$1" -m "$2" >/dev/null 2>&1 || true
    [[ "$IS_JSON_MODE" -eq 0 ]] || log "[MQTT] $1 -> $2"
}

get_service_pid() {
    netstat -tnlp 2>/dev/null | grep ":$SERVICE_PORT " | awk '{print $7}' | cut -d'/' -f1 | head -n1 || true
}

check_port_status() {
    nc -z 127.0.0.1 "$SERVICE_PORT" >/dev/null 2>&1 && echo "listening" || echo "not_listening"
}

check_install_status() {
    [[ -x "$BINARY_PATH" || $(dpkg -s isghotel 2>/dev/null | grep -q '^Status:') ]] && echo "true" || echo "false"
}

get_version() {
    if dpkg -s isghotel >/dev/null 2>&1; then
        dpkg -s isghotel | grep '^Version:' | awk '{print $2}' || echo "unknown"
    elif [ -x "$BINARY_PATH" ]; then
        "$BINARY_PATH" --version 2>/dev/null | head -n1 || echo "unknown"
    else
        echo "unknown"
    fi
}

# 主逻辑
ensure_directories
TS=$(date +%s)

PID="" RUNTIME="" PORT_STATUS="not_listening" INSTALL_STATUS="false" VERSION="unknown"
STATUS="stopped" EXIT_CODE=1

if [[ "$STATUS_MODE" != "2" ]]; then
    PID=$(get_service_pid || true)
    if [[ -n "$PID" ]]; then
        RUNTIME=$(ps -o etime= -p "$PID" 2>/dev/null | xargs || echo "")
        PORT_STATUS=$(check_port_status)
        if [[ "$PORT_STATUS" == "listening" ]]; then
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
    VERSION=$(get_version)
    [[ "$STATUS" == "running" && "$INSTALL_STATUS" != "true" ]] && INSTALL_STATUS="true"
fi

# JSON 构建
if [[ "$IS_JSON_MODE" -eq 1 ]]; then
    RESULT_JSON=$(jq -n \
        --arg service "$SERVICE_ID" \
        --arg status "$STATUS" \
        --arg pid "$PID" \
        --arg runtime "$RUNTIME" \
        --arg port_status "$PORT_STATUS" \
        --arg version "$VERSION" \
        --argjson install "$INSTALL_STATUS" \
        --argjson timestamp "$TS" \
        '{service: $service, status: $status, pid: $pid, runtime: $runtime, port_status: $port_status, install: $install, version: $version, timestamp: $timestamp}' 2>/dev/null
    )
    mqtt_report "isg/status/$SERVICE_ID/status" "$RESULT_JSON"
    echo "$RESULT_JSON"
    exit $EXIT_CODE
fi

# 非 JSON 输出控制
if [[ "$IS_QUIET_MODE" -eq 1 ]]; then
    exit $EXIT_CODE
else
    echo "$STATUS"
    exit $EXIT_CODE
fi

#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Matter Server 状态查询脚本 - 完整增强版
# 版本: v1.2.0
# 功能：支持运行状态、安装状态、端口监听、版本获取、MQTT 上报、JSON 输出
# =============================================================================

set -euo pipefail

# ---------------------------- 基本配置 ----------------------------
SERVICE_ID="matter-server"
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"
CONFIG_FILE="$BASE_DIR/configuration.yaml"
PROOT_ROOTFS="/data/data/com.termux/files/usr/var/lib/proot-distro/installed-rootfs/$PROOT_DISTRO"
MATTER_INSTALL_DIR="$PROOT_ROOTFS/opt/matter-server"
MATTER_ENV_DIR="$MATTER_INSTALL_DIR/venv"
LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/status.log"
SERVICE_PORT="8443"
WS_PORT="5540"
STATUS_MODE="${STATUS_MODE:-0}"
IS_JSON_MODE=0
IS_QUIET_MODE=0
HTTP_TIMEOUT=5

# ---------------------------- 参数解析 ----------------------------
while [[ $# -gt 0 ]]; do
    case $1 in
        --json) IS_JSON_MODE=1; shift ;;
        --quiet) IS_QUIET_MODE=1; shift ;;
        *) shift ;;
    esac
done

# ---------------------------- 工具函数 ----------------------------
ensure_directories() { mkdir -p "$LOG_DIR" 2>/dev/null || true; }

log() {
    [[ "$IS_QUIET_MODE" -eq 0 ]] && echo "[$(date '+%F %T')] $*" >> "$LOG_FILE" 2>/dev/null || true
}

load_mqtt_conf() {
    if [[ -f "$CONFIG_FILE" ]]; then
        MQTT_HOST=$(grep -Po '^[[:space:]]*host:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1 || echo "127.0.0.1")
        MQTT_PORT=$(grep -Po '^[[:space:]]*port:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1 || echo "1883")
        MQTT_USER=$(grep -Po '^[[:space:]]*username:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1 || echo "admin")
        MQTT_PASS=$(grep -Po '^[[:space:]]*password:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1 || echo "admin")
    else
        MQTT_HOST="127.0.0.1"; MQTT_PORT="1883"; MQTT_USER="admin"; MQTT_PASS="admin"
    fi
}

mqtt_report() {
    local topic="$1" payload="$2"
    [[ "$IS_QUIET_MODE" -eq 1 ]] && return 0
    load_mqtt_conf
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload" >/dev/null 2>&1 || true
    [[ "$IS_JSON_MODE" -eq 0 ]] && log "[MQTT] $topic -> $payload"
}

# ---------------------------- 状态检测 ----------------------------
get_service_pid() {
    # 匹配 python + matter-server 的进程
    ps aux | grep -E '[p]ython.*/matter[-_]server' | awk '{print $2}' | head -n1
}

check_http_status() {
    nc -z 127.0.0.1 "$SERVICE_PORT" >/dev/null 2>&1 && echo "online" || echo "offline"
}

check_websocket_status() {
    nc -z 127.0.0.1 "$WS_PORT" >/dev/null 2>&1 && echo "online" || echo "offline"
}

check_install_status() {
    if [[ -d "$MATTER_INSTALL_DIR" && -d "$MATTER_ENV_DIR" ]]; then
        echo "true"
    else
        proot-distro login "$PROOT_DISTRO" -- bash -c "source $MATTER_ENV_DIR/bin/activate 2>/dev/null && pip show python-matter-server >/dev/null 2>&1" && echo "true" || echo "false"
    fi
}

get_matter_version() {
    if [[ -d "$MATTER_ENV_DIR" ]]; then
        proot-distro login "$PROOT_DISTRO" -- bash -c '
            source "$MATTER_ENV_DIR/bin/activate" 2>/dev/null
            python -c "import matter_server; print(getattr(matter_server, '__version__', 'unknown'))" 2>/dev/null || echo "unknown"
        ' || echo "unknown"
    else
        echo "unknown"
    fi
}

# ---------------------------- 主流程 ----------------------------
ensure_directories
TS=$(date +%s)
PID="" RUNTIME="" HTTP_STATUS="offline" WS_STATUS="offline" INSTALL_STATUS="false" VERSION="unknown"
STATUS="stopped" EXIT_CODE=1

if [[ "$IS_JSON_MODE" -eq 0 && "$IS_QUIET_MODE" -eq 0 ]]; then
    # 快速模式
    PID=$(get_service_pid 2>/dev/null || true)
    if [[ -n "$PID" ]]; then
        HTTP_STATUS=$(check_http_status)
        STATUS="starting"; EXIT_CODE=2
        [[ "$HTTP_STATUS" == "online" ]] && STATUS="running" && EXIT_CODE=0
    fi
else
    # JSON 或完整模式
    if [[ "$STATUS_MODE" != "2" ]]; then
        PID=$(get_service_pid 2>/dev/null || true)
        [[ -n "$PID" ]] && RUNTIME=$(ps -o etime= -p "$PID" 2>/dev/null | xargs || echo "")
        HTTP_STATUS=$(check_http_status)
        WS_STATUS=$(check_websocket_status)
        STATUS="starting"; EXIT_CODE=2
        [[ "$HTTP_STATUS" == "online" ]] && STATUS="running" && EXIT_CODE=0
    fi
    if [[ "$STATUS_MODE" != "1" ]]; then
        INSTALL_STATUS=$(check_install_status)
        [[ "$INSTALL_STATUS" == "true" && "$VERSION" == "unknown" ]] && VERSION=$(get_matter_version)
    fi
    [[ "$STATUS" == "running" && "$INSTALL_STATUS" != "true" ]] && INSTALL_STATUS="true"
fi

# ---------------------------- 输出 ----------------------------
if [[ "$IS_JSON_MODE" -eq 1 ]]; then
    RESULT_JSON=$(jq -n \
        --arg service "$SERVICE_ID" \
        --arg status "$STATUS" \
        --arg pid "$PID" \
        --arg runtime "$RUNTIME" \
        --arg http_status "$HTTP_STATUS" \
        --arg ws_status "$WS_STATUS" \
        --arg port "$SERVICE_PORT" \
        --arg ws_port "$WS_PORT" \
        --argjson install "$INSTALL_STATUS" \
        --arg version "$VERSION" \
        --argjson timestamp "$TS" \
        '{service: $service, status: $status, pid: $pid, runtime: $runtime, http_status: $http_status, ws_status: $ws_status, port: ($port|tonumber), ws_port: ($ws_port|tonumber), install: $install, version: $version, timestamp: $timestamp}'
    )
    mqtt_report "isg/status/$SERVICE_ID/status" "$RESULT_JSON"
    echo "$RESULT_JSON"
    exit $EXIT_CODE
elif [[ "$IS_QUIET_MODE" -eq 1 ]]; then
    exit $EXIT_CODE
else
    echo "$STATUS"
    exit $EXIT_CODE
fi

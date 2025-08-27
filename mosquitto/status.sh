#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Mosquitto 状态查询脚本（优化版）
# 版本: v1.3.0
# 功能: 检查服务运行状态，支持快速模式和完整模式
# 优化: 默认模式只输出简单状态，--json 模式输出完整信息
# =============================================================================

set -euo pipefail

# =============================================================================
# 基本配置
# =============================================================================
SERVICE_ID="mosquitto"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
CONFIG_FILE="$BASE_DIR/configuration.yaml"

SERVICE_PORT="1883"
LOG_DIR="$BASE_DIR/$SERVICE_ID/logs"
LOG_FILE="$LOG_DIR/status.log"

STATUS_MODE="${STATUS_MODE:-0}"  # 0=全检，1=仅运行，2=仅安装
HTTP_TIMEOUT=5

IS_JSON_MODE=0
IS_QUIET_MODE=0

# 解析参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --json)
            IS_JSON_MODE=1
            shift
            ;;
        --quiet)
            IS_QUIET_MODE=1
            shift
            ;;
        *)
            shift
            ;;
    esac
done

# =============================================================================
# 工具函数
# =============================================================================
ensure_directories() { 
    mkdir -p "$LOG_DIR" 2>/dev/null || true
}

log() {
    # 静默模式下不写日志，避免产生输出
    if [[ "$IS_QUIET_MODE" -eq 0 ]]; then
        echo "[$(date '+%F %T')] $*" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

load_mqtt_conf() {
    MQTT_HOST=$(grep -Po '^[[:space:]]*host:[[:space:]]*\K.*' "$CONFIG_FILE" 2>/dev/null | head -n1 || echo "127.0.0.1")
    MQTT_PORT=$(grep -Po '^[[:space:]]*port:[[:space:]]*\K.*' "$CONFIG_FILE" 2>/dev/null | head -n1 || echo "1883")
    MQTT_USER=$(grep -Po '^[[:space:]]*username:[[:space:]]*\K.*' "$CONFIG_FILE" 2>/dev/null | head -n1 || echo "admin")
    MQTT_PASS=$(grep -Po '^[[:space:]]*password:[[:space:]]*\K.*' "$CONFIG_FILE" 2>/dev/null | head -n1 || echo "admin")
}

mqtt_report() {
    local topic="$1" payload="$2"
    
    # 静默模式下不进行 MQTT 上报，避免产生输出
    if [[ "$IS_QUIET_MODE" -eq 1 ]]; then
        return 0
    fi
    
    load_mqtt_conf
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload" >/dev/null 2>&1 || true

    # JSON模式下不输出MQTT日志
    if [[ "$IS_JSON_MODE" -eq 0 ]]; then
        log "[MQTT] $topic -> $payload"
    fi
}

get_service_pid() {
    # 方法1：通过端口找进程
    netstat -tnlp 2>/dev/null | grep ":$SERVICE_PORT " | awk '{print $7}' | cut -d'/' -f1 | head -n1 | grep -v '^$' || true
}

check_http_status() {
    nc -z 127.0.0.1 "$SERVICE_PORT" >/dev/null 2>&1 && echo "online" || echo "offline"
}

check_install_status() {
    command -v mosquitto >/dev/null 2>&1 && echo "true" || echo "false"
}

get_mosquitto_version() {
    mosquitto -h 2>&1 | grep -Po 'version \K[\d.]+' 2>/dev/null || echo "unknown"
}

# =============================================================================
# 主流程
# =============================================================================
ensure_directories
TS=$(date +%s)

PID="" RUNTIME="" HTTP_STATUS="offline" INSTALL_STATUS="false" VERSION="unknown"
STATUS="stopped" EXIT_CODE=1

# 默认模式（不带参数）只检查运行状态，加快速度
if [[ "$IS_JSON_MODE" -eq 0 && "$IS_QUIET_MODE" -eq 0 ]]; then
    # 快速模式：只检查运行状态
    PID=$(get_service_pid 2>/dev/null || true)
    if [ -n "$PID" ]; then
        HTTP_STATUS=$(check_http_status)
        if [[ "$HTTP_STATUS" == "online" ]]; then
            STATUS="running"
            EXIT_CODE=0
        else
            STATUS="starting"
            EXIT_CODE=2
        fi
    fi
else
    # 完整模式：用于 JSON 输出或其他模式
    if [[ "$STATUS_MODE" != "2" ]]; then
        PID=$(get_service_pid 2>/dev/null || true)
        if [ -n "$PID" ]; then
            RUNTIME=$(ps -o etime= -p "$PID" 2>/dev/null | xargs || echo "")
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
            VERSION=$(get_mosquitto_version)
        fi
    fi

    # 如果服务在运行但安装状态为false，修正安装状态
    if [[ "$STATUS" == "running" && "$INSTALL_STATUS" != "true" ]]; then
        INSTALL_STATUS="true"
    fi
    
    # STATUS_MODE=1 特殊处理：只关注运行状态
    if [[ "$STATUS_MODE" == "1" && "$STATUS" == "running" ]]; then
        INSTALL_STATUS="true"
        VERSION="running"
    fi
fi

# 只有在需要 JSON 输出时才构建 JSON
if [[ "$IS_JSON_MODE" -eq 1 ]]; then
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
        '{service: $service, status: $status, pid: $pid, runtime: $runtime, http_status: $http_status, port: ($port|tonumber), install: $install, version: $version, timestamp: $timestamp}' 2>/dev/null
    )
fi

# MQTT 上报（静默模式下跳过，默认模式下也跳过以加快速度）
if [[ "$IS_JSON_MODE" -eq 1 ]]; then
    mqtt_report "isg/status/$SERVICE_ID/status" "$RESULT_JSON"
fi

# 输出控制
if [[ "$IS_QUIET_MODE" -eq 1 ]]; then
    # 静默模式：不输出任何内容，只返回退出代码
    exit $EXIT_CODE
elif [[ "$IS_JSON_MODE" -eq 1 ]]; then
    # JSON模式：输出完整JSON信息
    echo "$RESULT_JSON"
    exit $EXIT_CODE
else
    # 默认模式：只输出简单的运行状态，快速响应
    echo "$STATUS"
    exit $EXIT_CODE
fi

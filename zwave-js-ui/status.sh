#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Z-Wave JS UI 状态查询脚本（通用服务状态模式）
# 版本: v2.0.3
# 默认简化模式：只输出状态词，快速响应
# =============================================================================
set -euo pipefail

# =============================================================================
# 基本配置
# =============================================================================
SERVICE_ID="zwave-js-ui"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
CONFIG_FILE="$BASE_DIR/configuration.yaml"

SERVICE_PORT="8091"
SERVICE_INSTALL_PATH="/root/.pnpm-global/global/5/node_modules/zwave-js-ui"
ZUI_BINARY="$SERVICE_INSTALL_PATH/dist/app.js"

LOG_DIR="$BASE_DIR/$SERVICE_ID/logs"
LOG_FILE="$LOG_DIR/status.log"

HTTP_TIMEOUT=5

# 检查参数和环境变量
IS_JSON_MODE=0
if [[ "${1:-}" == "--json" ]]; then
    IS_JSON_MODE=1
fi

IS_QUIET_MODE=0
if [[ "${1:-}" == "--quiet" ]]; then
    IS_QUIET_MODE=1
fi

# 决定模式：只有明确设置了参数或环境变量才使用完整模式
SIMPLE_MODE=1
if [[ -n "${STATUS_MODE:-}" ]] || [[ "$IS_JSON_MODE" -eq 1 ]] || [[ "$IS_QUIET_MODE" -eq 1 ]]; then
    SIMPLE_MODE=0
fi

# =============================================================================
# 简化模式：快速检查，只输出状态词
# =============================================================================
if [[ "$SIMPLE_MODE" -eq 1 ]]; then
    # 快速进程检测
    PID=$(pgrep -f '[z]wave-js-ui' | head -n1 || true)
    
    if [ -n "$PID" ]; then
        # 检查端口是否在线
        if nc -z 127.0.0.1 "$SERVICE_PORT" >/dev/null 2>&1; then
            STATUS="running"
            EXIT_CODE=0
        else
            STATUS="starting"
            EXIT_CODE=2
        fi
    else
        STATUS="stopped"
        EXIT_CODE=1
    fi
    
    # 简化的MQTT上报（静默方式，不输出日志）
    if [ -f "$CONFIG_FILE" ]; then
        MQTT_HOST=$(grep -Po '^[[:space:]]*host:[[:space:]]*\K.*' "$CONFIG_FILE" 2>/dev/null | head -n1 || echo "127.0.0.1")
        MQTT_PORT=$(grep -Po '^[[:space:]]*port:[[:space:]]*\K.*' "$CONFIG_FILE" 2>/dev/null | head -n1 || echo "1883")
        MQTT_USER=$(grep -Po '^[[:space:]]*username:[[:space:]]*\K.*' "$CONFIG_FILE" 2>/dev/null | head -n1 || echo "admin")
        MQTT_PASS=$(grep -Po '^[[:space:]]*password:[[:space:]]*\K.*' "$CONFIG_FILE" 2>/dev/null | head -n1 || echo "admin")
        
        mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" \
            -t "isg/status/$SERVICE_ID/status" -m "$STATUS" >/dev/null 2>&1 || true
    fi
    
    # 直接输出状态词
    echo "$STATUS"
    exit $EXIT_CODE
fi

# =============================================================================
# 完整模式：详细检查（仅在有参数或环境变量时使用）
# =============================================================================

# 工具函数
ensure_directories() { mkdir -p "$LOG_DIR"; }

log() {
    if [[ "$IS_JSON_MODE" -eq 0 && "$IS_QUIET_MODE" -eq 0 ]]; then
        echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"
    fi
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

    if [[ "$IS_JSON_MODE" -eq 0 && "$IS_QUIET_MODE" -eq 0 ]]; then
        log "[MQTT] $topic -> $payload"
    fi
}

get_service_pid() {
    # 方法1: 查找监听指定端口的进程
    pgrep -f '[z]wave-js-ui' | while read -r pid; do
        # 验证进程确实在监听指定端口
        if netstat -tnlp 2>/dev/null | grep -q ":$SERVICE_PORT.*$pid/"; then
            echo "$pid"
            return 0
        fi
    done
    return 1
}

check_http_status() {
    if nc -z 127.0.0.1 "$SERVICE_PORT" >/dev/null 2>&1; then
        echo "online"
    else
        echo "offline"
    fi
}

check_install_status() {
    proot-distro login ubuntu -- bash -c "test -f '$SERVICE_INSTALL_PATH/package.json'" 2>/dev/null && echo "true" || echo "false"
}

get_version() {
    proot-distro login ubuntu -- bash -c "
        if [ -f '$SERVICE_INSTALL_PATH/package.json' ]; then
            grep -m1 '\"version\"' '$SERVICE_INSTALL_PATH/package.json' | sed -E 's/.*\"version\"[[:space:]]*:[[:space:]]*\"([^\"]+)\".*/\1/'
        else
            echo 'unknown'
        fi
    " 2>/dev/null || echo "unknown"
}

# 完整模式主流程
ensure_directories
TS=$(date +%s)

PID="" RUNTIME="" HTTP_STATUS="offline" INSTALL_STATUS="false" VERSION="unknown"
STATUS="stopped" EXIT_CODE=1

# 根据 STATUS_MODE 执行不同的检查逻辑
if [[ "${STATUS_MODE:-0}" != "2" ]]; then
    # 检查运行状态
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

if [[ "${STATUS_MODE:-0}" != "1" ]]; then
    # 检查安装状态
    INSTALL_STATUS=$(check_install_status)
    if [[ "$INSTALL_STATUS" == "true" && "$VERSION" == "unknown" ]]; then
        VERSION=$(get_version)
    fi
fi

# 如果服务正在运行但检测为未安装，修正安装状态
if [[ "$STATUS" == "running" && "$INSTALL_STATUS" != "true" ]]; then
    INSTALL_STATUS="true"
fi

# 构建结果JSON
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

# 上报到MQTT
mqtt_report "isg/status/$SERVICE_ID/status" "$RESULT_JSON"

# 输出结果
if [[ "$IS_JSON_MODE" -eq 1 ]]; then
    echo "$RESULT_JSON"
    exit $EXIT_CODE
elif [[ "$IS_QUIET_MODE" -eq 1 ]]; then
    # quiet模式只返回退出码，不输出任何内容
    exit $EXIT_CODE
fi

log "状态检查完成"
echo "$RESULT_JSON"
exit $EXIT_CODE

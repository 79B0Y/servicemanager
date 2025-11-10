#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# isg-adb-server 状态查询脚本
# 版本: v1.0.0
# 功能: 查询 ADB 服务运行状态，支持 JSON 和静默模式
# =============================================================================
set -euo pipefail

# =============================================================================
# 基本配置
# =============================================================================
SERVICE_ID="isg-adb-server"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
CONFIG_FILE="$BASE_DIR/configuration.yaml"

ADB_PORT="5555"
ADB_HOST="127.0.0.1"
ADB_DEVICE="${ADB_HOST}:${ADB_PORT}"

LOG_DIR="$BASE_DIR/$SERVICE_ID/logs"
LOG_FILE="$LOG_DIR/status.log"

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
    # 静默模式下不写日志
    if [[ "$IS_QUIET_MODE" -eq 0 ]]; then
        echo "[$(date '+%F %T')] $*" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

load_mqtt_conf() {
    if [[ -f "$CONFIG_FILE" ]]; then
        MQTT_HOST=$(grep -Po '^[[:space:]]*host:[[:space:]]*\K.*' "$CONFIG_FILE" 2>/dev/null | head -n1 || echo "127.0.0.1")
        MQTT_PORT=$(grep -Po '^[[:space:]]*port:[[:space:]]*\K.*' "$CONFIG_FILE" 2>/dev/null | head -n1 || echo "1883")
        MQTT_USER=$(grep -Po '^[[:space:]]*username:[[:space:]]*\K.*' "$CONFIG_FILE" 2>/dev/null | head -n1 || echo "admin")
        MQTT_PASS=$(grep -Po '^[[:space:]]*password:[[:space:]]*\K.*' "$CONFIG_FILE" 2>/dev/null | head -n1 || echo "admin")
    else
        MQTT_HOST="127.0.0.1"
        MQTT_PORT="1883"
        MQTT_USER="admin"
        MQTT_PASS="admin"
    fi
}

mqtt_report() {
    local topic="$1" payload="$2"
    
    # 静默模式下不进行 MQTT 上报
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

check_adb_connected() {
    adb devices 2>/dev/null | grep -q "$ADB_DEVICE" && return 0 || return 1
}

check_install_status() {
    # 通过 pkg show android-tools 检查是否安装
    if pkg show android-tools >/dev/null 2>&1; then
        echo "true"
    else
        echo "false"
    fi
}

get_android_tools_version() {
    pkg show android-tools 2>/dev/null | grep -oP '(?<=Version: )[0-9.r\-]+' | head -n1 || echo "unknown"
}

get_adb_devices() {
    # 获取连接的设备列表
    adb devices 2>/dev/null | tail -n +2 | grep -v "^$" | awk '{print $1}' | tr '\n' ',' | sed 's/,$//' || echo ""
}

# =============================================================================
# 主流程
# =============================================================================
ensure_directories
TS=$(date +%s)

INSTALL_STATUS="false"
VERSION="unknown"
ADB_CONNECTED="false"
DEVICES=""
STATUS="stopped"
EXIT_CODE=1

# 检查安装状态
INSTALL_STATUS=$(check_install_status)

if [[ "$INSTALL_STATUS" == "true" ]]; then
    VERSION=$(get_android_tools_version)
fi

# 快速模式：只检查 ADB 连接状态
if [[ "$IS_JSON_MODE" -eq 0 && "$IS_QUIET_MODE" -eq 0 ]]; then
    if check_adb_connected; then
        STATUS="running"
        ADB_CONNECTED="true"
        EXIT_CODE=0
    else
        STATUS="stopped"
        ADB_CONNECTED="false"
        EXIT_CODE=1
    fi
    
    # 在普通模式下进行基本的MQTT上报
    BASIC_JSON=$(jq -n \
        --arg service "$SERVICE_ID" \
        --arg status "$STATUS" \
        --arg adb_connected "$ADB_CONNECTED" \
        --arg device "$ADB_DEVICE" \
        --arg port "$ADB_PORT" \
        --argjson timestamp "$TS" \
        '{service: $service, status: $status, adb_connected: ($adb_connected == "true"), device: $device, port: ($port|tonumber), timestamp: $timestamp}' 2>/dev/null
    )
    mqtt_report "isg/status/$SERVICE_ID/status" "$BASIC_JSON"
    
else
    # 完整检查模式（JSON模式时）
    if check_adb_connected; then
        STATUS="running"
        ADB_CONNECTED="true"
        EXIT_CODE=0
    else
        STATUS="stopped"
        ADB_CONNECTED="false"
        EXIT_CODE=1
    fi
    
    # 获取设备列表
    DEVICES=$(get_adb_devices)
fi

# 构建JSON结果（仅在JSON模式时输出详细信息）
if [[ "$IS_JSON_MODE" -eq 1 ]]; then
    RESULT_JSON=$(jq -n \
        --arg service "$SERVICE_ID" \
        --arg status "$STATUS" \
        --arg adb_connected "$ADB_CONNECTED" \
        --arg device "$ADB_DEVICE" \
        --arg port "$ADB_PORT" \
        --arg devices "$DEVICES" \
        --argjson install "$INSTALL_STATUS" \
        --arg version "$VERSION" \
        --argjson timestamp "$TS" \
        '{service: $service, status: $status, adb_connected: ($adb_connected == "true"), device: $device, port: ($port|tonumber), devices: $devices, install: $install, version: $version, timestamp: $timestamp}' 2>/dev/null
    )
    
    # MQTT 上报（静默模式下跳过）
    mqtt_report "isg/status/$SERVICE_ID/status" "$RESULT_JSON"
fi

# 输出控制
if [[ "$IS_QUIET_MODE" -eq 1 ]]; then
    # 静默模式：不输出任何内容，只返回退出代码
    exit $EXIT_CODE
elif [[ "$IS_JSON_MODE" -eq 1 ]]; then
    # JSON模式：只输出JSON，不输出其他信息
    echo "$RESULT_JSON"
    exit $EXIT_CODE
else
    # 普通模式：只输出简单的运行状态
    echo "$STATUS"
    exit $EXIT_CODE
fi

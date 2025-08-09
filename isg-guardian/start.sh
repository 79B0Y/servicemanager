#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# isg-guardian 状态查询脚本
# 版本: v1.0.0
# 功能: 查询 isg-guardian 服务运行状态，支持JSON模式
# =============================================================================

set -euo pipefail

# =============================================================================
# 基本配置
# =============================================================================
SERVICE_ID="isg-guardian"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
CONFIG_FILE="$BASE_DIR/configuration.yaml"

PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
GUARDIAN_INSTALL_DIR="/root/isg-guardian"
GUARDIAN_VENV_DIR="$GUARDIAN_INSTALL_DIR/venv"

LOG_DIR="$BASE_DIR/$SERVICE_ID/logs"
LOG_FILE="$LOG_DIR/status.log"

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

get_guardian_pid() {
    # 查找 iSG App Guardian 进程
    local pid=$(proot-distro login "$PROOT_DISTRO" -- bash -c "pgrep -f 'iSG App Guardian' | head -n1" 2>/dev/null || echo "")
    
    if [ -n "$pid" ]; then
        # 验证是否为正确的 iSG App Guardian 进程
        local cmdline=$(proot-distro login "$PROOT_DISTRO" -- bash -c "cat /proc/$pid/cmdline 2>/dev/null | tr '\0' ' ' | grep -i 'iSG App Guardian'" 2>/dev/null || echo "")
        if [ -n "$cmdline" ]; then
            echo "$pid"
            return 0
        fi
    fi
    return 1
}

check_install_status() {
    # 通过检查版本号来确定程序是否安装
    local version=$(get_guardian_version)
    if [[ "$version" != "unknown" && -d "$GUARDIAN_VENV_DIR" ]]; then
        echo "true"
    else
        echo "false"
    fi
}

get_guardian_version() {
    # 通过版本号确定是否安装
    proot-distro login "$PROOT_DISTRO" -- bash -c '
        if [ -f "'"$GUARDIAN_VENV_DIR"'/bin/activate" ]; then
            source "'"$GUARDIAN_VENV_DIR"'/bin/activate"
            cd "'"$GUARDIAN_INSTALL_DIR"'"
            if [ -f "isg-guardian" ]; then
                grep "VERSION = " isg-guardian 2>/dev/null | sed "s/.*VERSION = [\"'"'"']\(.*\)[\"'"'"'].*/\1/" || echo "unknown"
            else
                echo "unknown"
            fi
        else
            echo "unknown"
        fi
    ' 2>/dev/null || echo "unknown"
}

get_service_status() {
    # 通过 isg-guardian status 查看状态
    if proot-distro login "$PROOT_DISTRO" -- bash -c "cd $GUARDIAN_INSTALL_DIR && source venv/bin/activate && isg-guardian status" 2>/dev/null | grep -q "running"; then
        echo "running"
    else
        echo "stopped"
    fi
}

# =============================================================================
# 主流程
# =============================================================================
ensure_directories
TS=$(date +%s)

PID="" RUNTIME="" INSTALL_STATUS="false" VERSION="unknown"
STATUS="stopped" EXIT_CODE=1

# 检查安装状态
INSTALL_STATUS=$(check_install_status)
if [[ "$INSTALL_STATUS" == "true" ]]; then
    VERSION=$(get_guardian_version)
fi

# 检查运行状态
PID=$(get_guardian_pid 2>/dev/null || true)
if [[ -n "$PID" ]]; then
    RUNTIME=$(proot-distro login "$PROOT_DISTRO" -- bash -c "ps -o etime= -p $PID 2>/dev/null | xargs" || echo "")
    # 进一步验证服务状态
    if [[ "$(get_service_status)" == "running" ]]; then
        STATUS="running"
        EXIT_CODE=0
    else
        STATUS="starting"
        EXIT_CODE=2
    fi
fi

# 构建JSON结果（仅在JSON模式时输出详细信息）
if [[ "$IS_JSON_MODE" -eq 1 ]]; then
    RESULT_JSON=$(jq -n \
        --arg service "$SERVICE_ID" \
        --arg status "$STATUS" \
        --arg pid "$PID" \
        --arg runtime "$RUNTIME" \
        --argjson install "$INSTALL_STATUS" \
        --arg version "$VERSION" \
        --argjson timestamp "$TS" \
        '{service: $service, status: $status, pid: $pid, runtime: $runtime, install: $install, version: $version, timestamp: $timestamp}' 2>/dev/null
    )
    
    # MQTT 上报（静默模式下跳过）
    mqtt_report "isg/status/$SERVICE_ID/status" "$RESULT_JSON"
else
    # 在普通模式下也进行基本的MQTT上报
    BASIC_JSON=$(jq -n \
        --arg service "$SERVICE_ID" \
        --arg status "$STATUS" \
        --arg pid "$PID" \
        --argjson install "$INSTALL_STATUS" \
        --argjson timestamp "$TS" \
        '{service: $service, status: $status, pid: $pid, install: $install, timestamp: $timestamp}' 2>/dev/null
    )
    mqtt_report "isg/status/$SERVICE_ID/status" "$BASIC_JSON"
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

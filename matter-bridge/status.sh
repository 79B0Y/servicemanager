#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Matter Bridge 状态查询脚本
# 版本: v1.0.0
# 功能: 查询 Matter Bridge 服务运行状态，依据 PID 和 8482 端口
# =============================================================================
set -euo pipefail

# =============================================================================
# 基本配置
# =============================================================================
SERVICE_ID="matter-bridge"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
CONFIG_FILE="$BASE_DIR/configuration.yaml"

SERVICE_PORT="8482"
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
PROOT_ROOTFS="/data/data/com.termux/files/usr/var/lib/proot-distro/installed-rootfs/$PROOT_DISTRO"
MATTER_BRIDGE_INSTALL_PATH="$PROOT_ROOTFS/root/.pnpm-global/global/5/node_modules/home-assistant-matter-hub"

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

get_service_pid() {
    local port_pid=$(netstat -tnlp 2>/dev/null | grep ":$SERVICE_PORT " | awk '{print $7}' | cut -d'/' -f1 | head -n1)
    
    if [[ -n "$port_pid" && "$port_pid" != "-" ]]; then
        # 验证是否为 matter-bridge 相关进程（检查工作目录或命令行）
        local cmdline=$(cat /proc/$port_pid/cmdline 2>/dev/null | tr '\0' ' ' | grep -i 'matter\|home-assistant-matter-hub' || true)
        local cwd=$(ls -l /proc/$port_pid/cwd 2>/dev/null | grep -o 'matter\|pnpm' || true)
        local exe=$(ls -l /proc/$port_pid/exe 2>/dev/null | grep -o 'node\|matter' || true)
        
        # 如果找到任何一个匹配条件就认为是 matter-bridge 进程
        if [[ -n "$cmdline" || -n "$cwd" || -n "$exe" ]]; then
            echo "$port_pid"
            return 0
        fi
        
        # 如果上述检查都失败，但端口确实被占用，可能是通过不同方式启动的
        # 作为最后的手段，检查进程是否监听了正确的端口
        if netstat -tnlp 2>/dev/null | grep ":$SERVICE_PORT " | grep -q "$port_pid"; then
            echo "$port_pid"
            return 0
        fi
    fi
    
    return 1
}

check_http_status() {
    nc -z 127.0.0.1 "$SERVICE_PORT" >/dev/null 2>&1 && echo "online" || echo "offline"
}

check_install_status() {
    test -d "$MATTER_BRIDGE_INSTALL_PATH" && echo "true" || echo "false"
}

get_matter_bridge_version() {
    # 通过版本号来确定程序是否安装
    proot-distro login "$PROOT_DISTRO" -- bash -c '
        VERSION_FILE="/root/.pnpm-global/global/5/node_modules/home-assistant-matter-hub/package.json"
        if [ -f "$VERSION_FILE" ]; then
            jq -r .version "$VERSION_FILE" 2>/dev/null || echo "unknown"
        else
            echo "unknown"
        fi
    ' 2>/dev/null || echo "unknown"
}

# =============================================================================
# 主流程
# =============================================================================
ensure_directories
TS=$(date +%s)

PID="" RUNTIME="" HTTP_STATUS="offline" INSTALL_STATUS="false" VERSION="unknown"
STATUS="stopped" EXIT_CODE=1

# 检查运行状态
PID=$(get_service_pid 2>/dev/null || true)
if [[ -n "$PID" ]]; then
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

# 检查安装状态
INSTALL_STATUS=$(check_install_status)
if [[ "$INSTALL_STATUS" == "true" ]]; then
    VERSION=$(get_matter_bridge_version)
fi

if [[ "$STATUS" == "running" && "$INSTALL_STATUS" != "true" ]]; then
    INSTALL_STATUS="true"
fi

# 构建JSON结果（仅在JSON模式时输出详细信息）
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
    
    # MQTT 上报（静默模式下跳过）
    mqtt_report "isg/status/$SERVICE_ID/status" "$RESULT_JSON"
else
    # 在普通模式下也进行基本的MQTT上报
    BASIC_JSON=$(jq -n \
        --arg service "$SERVICE_ID" \
        --arg status "$STATUS" \
        --arg pid "$PID" \
        --arg http_status "$HTTP_STATUS" \
        --arg port "$SERVICE_PORT" \
        --argjson install "$INSTALL_STATUS" \
        --argjson timestamp "$TS" \
        '{service: $service, status: $status, pid: $pid, http_status: $http_status, port: ($port|tonumber), install: $install, timestamp: $timestamp}' 2>/dev/null
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

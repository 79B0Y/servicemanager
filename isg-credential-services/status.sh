#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# isg-credential-services 状态查询脚本
# 版本: v1.0.0
# 功能: 查询服务运行状态，支持 JSON 和静默模式
# =============================================================================
set -euo pipefail

# =============================================================================
# 基本配置
# =============================================================================
SERVICE_ID="isg-credential-services"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
CONFIG_FILE="$BASE_DIR/configuration.yaml"

SERVICE_PORT="3000"
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
PROOT_ROOTFS="/data/data/com.termux/files/usr/var/lib/proot-distro/installed-rootfs/$PROOT_DISTRO"
ISG_INSTALL_PATH="$PROOT_ROOTFS/root/isg-credential-services"

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

get_service_pid() {
    local port_pid=$(netstat -tnlp 2>/dev/null | grep ":$SERVICE_PORT " | awk '{print $7}' | cut -d'/' -f1 | head -n1)
    
    if [[ -n "$port_pid" && "$port_pid" != "-" ]]; then
        # 验证是否为 isg-credential-services 相关进程
        local cmdline=$(cat /proc/$port_pid/cmdline 2>/dev/null | tr '\0' ' ' | grep -i 'node\|npm\|credential' || true)
        local cwd=$(ls -l /proc/$port_pid/cwd 2>/dev/null | grep -o 'credential\|isg-credential' || true)
        local exe=$(ls -l /proc/$port_pid/exe 2>/dev/null | grep -o 'node\|npm' || true)
        
        # 如果找到任何一个匹配条件就认为是 isg-credential-services 进程
        if [[ -n "$cmdline" || -n "$cwd" || -n "$exe" ]]; then
            echo "$port_pid"
            return 0
        fi
        
        # 如果上述检查都失败，但端口确实被占用
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
    test -d "$ISG_INSTALL_PATH" && echo "true" || echo "false"
}

get_isg_version() {
    proot-distro login "$PROOT_DISTRO" -- bash -c "
        if [ -d '/root/isg-credential-services' ] && [ -f '/root/isg-credential-services/manage-service.sh' ]; then
            cd '/root/isg-credential-services'
            bash manage-service.sh version 2>/dev/null | grep -oP '(?<=版本号: )[0-9.]+' || echo 'unknown'
        else
            echo 'unknown'
        fi
    " 2>/dev/null || echo "unknown"
}

# =============================================================================
# 主流程
# =============================================================================
ensure_directories
TS=$(date +%s)

PID="" RUNTIME="" HTTP_STATUS="offline" INSTALL_STATUS="false" VERSION="unknown"
STATUS="stopped" EXIT_CODE=1

# 快速模式：只检查进程和HTTP状态
if [[ "$IS_JSON_MODE" -eq 0 && "$IS_QUIET_MODE" -eq 0 ]]; then
    PID=$(get_service_pid 2>/dev/null || true)
    if [[ -n "$PID" ]]; then
        HTTP_STATUS=$(check_http_status)
        if [[ "$HTTP_STATUS" == "online" ]]; then
            STATUS="running"
            EXIT_CODE=0
        else
            STATUS="starting"
            EXIT_CODE=2
        fi
    fi
    
    # 在普通模式下进行基本的MQTT上报
    BASIC_JSON=$(jq -n \
        --arg service "$SERVICE_ID" \
        --arg status "$STATUS" \
        --arg pid "$PID" \
        --arg http_status "$HTTP_STATUS" \
        --arg port "$SERVICE_PORT" \
        --argjson timestamp "$TS" \
        '{service: $service, status: $status, pid: $pid, http_status: $http_status, port: ($port|tonumber), timestamp: $timestamp}' 2>/dev/null
    )
    mqtt_report "isg/status/$SERVICE_ID/status" "$BASIC_JSON"
    
else
    # 完整检查模式（JSON模式时）
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

    INSTALL_STATUS=$(check_install_status)
    if [[ "$INSTALL_STATUS" == "true" && "$VERSION" == "unknown" ]]; then
        VERSION=$(get_isg_version)
    fi

    if [[ "$STATUS" == "running" && "$INSTALL_STATUS" != "true" ]]; then
        INSTALL_STATUS="true"
    fi
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

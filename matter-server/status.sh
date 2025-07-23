#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Matter Server 状态查询脚本 - 优化版本
# 版本: v1.0.0
# 优化: 支持快速模式，优化输出格式
# =============================================================================
set -euo pipefail

# =============================================================================
# 路径和配置定义
# =============================================================================
SERVICE_ID="matter-server"
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"

# 基础目录
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"
CONFIG_FILE="$BASE_DIR/configuration.yaml"

# 容器内路径
PROOT_ROOTFS="/data/data/com.termux/files/usr/var/lib/proot-distro/installed-rootfs/$PROOT_DISTRO"
MATTER_INSTALL_DIR="$PROOT_ROOTFS/opt/matter-server"
MATTER_ENV_DIR="$MATTER_INSTALL_DIR/venv"

# 日志文件
LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/status.log"

# 网络端口
SERVICE_PORT="8443"
WS_PORT="5540"

# 脚本参数
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
        # 验证是否为 matter-server 相关进程
        local cmdline=$(cat /proc/$port_pid/cmdline 2>/dev/null | tr '\0' ' ' || echo "")
        if [[ "$cmdline" =~ "matter_server" ]]; then
            echo "$port_pid"
            return 0
        fi
    fi
    
    return 1
}

check_http_status() {
    nc -z 127.0.0.1 "$SERVICE_PORT" >/dev/null 2>&1 && echo "online" || echo "offline"
}

check_websocket_status() {
    nc -z 127.0.0.1 "$WS_PORT" >/dev/null 2>&1 && echo "online" || echo "offline"
}

check_install_status() {
    test -d "$MATTER_INSTALL_DIR" && test -d "$MATTER_ENV_DIR" && echo "true" || echo "false"
}

get_matter_version() {
    if [[ -d "$MATTER_ENV_DIR" ]]; then
        # 直接通过虚拟环境检查版本
        proot-distro login "$PROOT_DISTRO" -- bash -c "
            source $MATTER_ENV_DIR/bin/activate 2>/dev/null || exit 1
            python -c 'import matter_server; print(matter_server.__version__)' 2>/dev/null || echo 'unknown'
        " || echo "unknown"
    else
        echo "unknown"
    fi
}

# =============================================================================
# 主流程 - 优化版本：默认模式只检查运行状态
# =============================================================================
ensure_directories
TS=$(date +%s)

PID="" RUNTIME="" HTTP_STATUS="offline" WS_STATUS="offline" INSTALL_STATUS="false" VERSION="unknown"
STATUS="stopped" EXIT_CODE=1

# 默认模式：只检查运行状态，不检查安装和版本（加快速度）
if [[ "$IS_JSON_MODE" -eq 0 && "$IS_QUIET_MODE" -eq 0 ]]; then
    # 快速模式：只检查进程和HTTP状态
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
else
    # 完整检查模式（JSON模式或有STATUS_MODE环境变量时）
    if [[ "$STATUS_MODE" != "2" ]]; then
        PID=$(get_service_pid 2>/dev/null || true)
        if [[ -n "$PID" ]]; then
            RUNTIME=$(ps -o etime= -p "$PID" 2>/dev/null | xargs || echo "")
            HTTP_STATUS=$(check_http_status)
            WS_STATUS=$(check_websocket_status)
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
            VERSION=$(get_matter_version)
        fi
    fi

    if [[ "$STATUS" == "running" && "$INSTALL_STATUS" != "true" ]]; then
        INSTALL_STATUS="true"
    fi
fi

# 构建JSON结果（仅在需要时）
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
        '{service: $service, status: $status, pid: $pid, runtime: $runtime, http_status: $http_status, ws_status: $ws_status, port: ($port|tonumber), ws_port: ($ws_port|tonumber), install: $install, version: $version, timestamp: $timestamp}' 2>/dev/null
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
    # 普通模式：只输出简单的运行状态（快速模式）
    echo "$STATUS"
    exit $EXIT_CODE
fi
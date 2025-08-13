#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# isg-android-control 状态查询脚本
# 版本: v1.0.0
# 功能: 查询 isg-android-control 服务运行状态
# =============================================================================
set -euo pipefail

# =============================================================================
# 基本配置
# =============================================================================
SERVICE_ID="isg-android-control"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
CONFIG_FILE="$BASE_DIR/configuration.yaml"

PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
ANDROID_CONTROL_INSTALL_DIR="/root/android-control"

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
    pgrep -f "python3 -m isg_android_control.run" 2>/dev/null || return 1
}

check_install_status() {
    # 检查安装目录是否存在，抑制proot警告
    proot-distro login "$PROOT_DISTRO" -- test -d "/root/android-control" >/dev/null 2>&1 && echo "true" || echo "false"
}

get_android_control_version() {
  # 版本提取函数（只取第一行 x.y 或 x.y.z）
  _print_ver() {
    head -n1 | grep -oE '^[0-9]+(\.[0-9]+){1,2}' || echo unknown
  }

  # 执行获取版本的逻辑
  _run() {
    cd /root/android-control 2>/dev/null || { echo unknown; return; }
    export PATH="/root/.local/bin:$PATH"
    for cmd in \
      "/root/.local/bin/isg-android-control" \
      "isg-android-control" \
      "/root/android-control/.venv/bin/isg-android-control" \
      "/root/android-control/venv/bin/isg-android-control" \
      "/root/android-control/.venv/bin/python3 -m isg_android_control.run" \
      "/root/android-control/venv/bin/python3 -m isg_android_control.run" \
      "/usr/bin/python3 -m isg_android_control.run"
    do
      # shellcheck disable=SC2086
      if $cmd version 2>/dev/null | _print_ver; then return; fi
    done
    echo unknown
  }

  if grep -qa "proot" /proc/1/cmdline 2>/dev/null; then
    _run
  else
    PROOT_NO_SECCOMP=1 proot-distro login ubuntu -- bash -lc "$(typeset -f _print_ver _run); _run" 2>/dev/null || echo unknown
  fi
}
# =============================================================================
# 主流程
# =============================================================================
ensure_directories
TS=$(date +%s)

PID="" RUNTIME="" INSTALL_STATUS="false" VERSION="unknown"
STATUS="stopped" EXIT_CODE=1

# 默认模式：只检查运行状态，不检查安装和版本（加快速度）
if [[ "$IS_JSON_MODE" -eq 0 && "$IS_QUIET_MODE" -eq 0 ]]; then
    # 快速模式：只检查进程状态
    PID=$(get_service_pid 2>/dev/null || true)
    if [[ -n "$PID" ]]; then
        STATUS="running"
        EXIT_CODE=0
    fi
    
    # 在普通模式下也进行基本的MQTT上报
    BASIC_JSON=$(jq -n \
        --arg service "$SERVICE_ID" \
        --arg status "$STATUS" \
        --arg pid "$PID" \
        --argjson timestamp "$TS" \
        '{service: $service, status: $status, pid: $pid, timestamp: $timestamp}' 2>/dev/null
    )
    mqtt_report "isg/status/$SERVICE_ID/status" "$BASIC_JSON"
    
else
    # 完整检查模式（JSON模式时）
    PID=$(get_service_pid 2>/dev/null || true)
    if [[ -n "$PID" ]]; then
        RUNTIME=$(ps -o etime= -p "$PID" 2>/dev/null | xargs || echo "")
        STATUS="running"
        EXIT_CODE=0
    fi

    INSTALL_STATUS=$(check_install_status)
    if [[ "$INSTALL_STATUS" == "true" ]]; then
        VERSION=$(get_android_control_version)
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
        --argjson install "$INSTALL_STATUS" \
        --arg version "$VERSION" \
        --argjson timestamp "$TS" \
        '{service: $service, status: $status, pid: $pid, runtime: $runtime, install: $install, version: $version, timestamp: $timestamp}' 2>/dev/null
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

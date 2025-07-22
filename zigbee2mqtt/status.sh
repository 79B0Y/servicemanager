#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# 通用服务状态查询脚本 - 修正版
# 版本: v2.1.0
# =============================================================================

set -euo pipefail

# 1️⃣ 加载配置与路径
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common_paths.sh" || {
    echo "❌ Error: Cannot load common paths"
    exit 1
}

LOG_FILE="$LOG_FILE_STATUS"
ensure_directories

SERVICE_PORT="${SERVICE_PORT:-8080}"
SERVICE_INSTALL_PATH="${Z2M_INSTALL_DIR:-/opt/zigbee2mqtt}"
HTTP_CHECK_PATH="${HTTP_CHECK_PATH:-/}"
STATUS_MODE="${STATUS_MODE:-0}"

TS=$(date +%s)
PID=""
RUNTIME=""
HTTP_STATUS="offline"
INSTALL_STATUS=false
VERSION="unknown"

# 2️⃣ 进程检测
get_service_pid() {
    netstat -tnlp 2>/dev/null | grep ":$SERVICE_PORT " | awk '{print $7}' | cut -d'/' -f1 | head -n1 || true
}

# 3️⃣ HTTP 健康检查
check_http_status() {
    if command -v nc >/dev/null 2>&1; then
        nc -z 127.0.0.1 "$SERVICE_PORT" && echo "online" && return
    elif command -v curl >/dev/null 2>&1; then
        curl -fs --max-time 3 "http://127.0.0.1:$SERVICE_PORT$HTTP_CHECK_PATH" >/dev/null && echo "online" && return
    fi
    echo "offline"
}

# 4️⃣ 安装与版本检查
check_install_status() {
    if proot-distro login "$PROOT_DISTRO" -- test -d "$SERVICE_INSTALL_PATH"; then
        INSTALL_STATUS=true
        VERSION=$(proot-distro login "$PROOT_DISTRO" -- bash -c "cd '$SERVICE_INSTALL_PATH' && grep -m1 '\"version\"' package.json | sed -E 's/.*\"version\"[[:space:]]*:[[:space:]]*\"([^\"]+)\".*/\1/'" 2>/dev/null || echo "unknown")
    fi
}

# 5️⃣ 执行模式检测
PID=$(get_service_pid)
[ -n "$PID" ] && RUNTIME=$(ps -o etime= -p "$PID" | xargs)

case "$STATUS_MODE" in
    0)
        check_install_status
        HTTP_STATUS=$(check_http_status)
        ;;
    1)
        [ -n "$PID" ] && INSTALL_STATUS=true && VERSION="running" && HTTP_STATUS=$(check_http_status)
        ;;
    2)
        check_install_status
        ;;
    *)
        echo "❌ Error: Invalid STATUS_MODE=$STATUS_MODE"
        exit 99
        ;;
esac

# 6️⃣ 最终状态判定
if [ -n "$PID" ]; then
    if [ "$HTTP_STATUS" = "offline" ]; then
        STATUS="starting"
        EXIT=2
    else
        STATUS="running"
        EXIT=0
    fi
else
    STATUS="stopped"
    EXIT=1
fi

# 7️⃣ JSON 输出 & MQTT 上报
RESULT_JSON=$(jq -n \
    --arg service "$SERVICE_ID" \
    --arg status "$STATUS" \
    --arg pid "$PID" \
    --arg runtime "$RUNTIME" \
    --arg http_status "$HTTP_STATUS" \
    --argjson port "$SERVICE_PORT" \
    --argjson install "$INSTALL_STATUS" \
    --arg version "$VERSION" \
    --argjson timestamp "$TS" \
    '{service:$service, status:$status, pid:$pid, runtime:$runtime, http_status:$http_status, port:$port, install:$install, version:$version, timestamp:$timestamp}'
)

mqtt_report "isg/status/$SERVICE_ID/status" "$RESULT_JSON"
log "$RESULT_JSON"

# 8️⃣ 输出控制
case "${1:-}" in
    --json)
        echo "$RESULT_JSON"
        ;;
    --quiet)
        ;;
    *)
        echo "$RESULT_JSON"
        ;;
esac

exit $EXIT

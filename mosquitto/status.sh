#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Mosquitto 状态查询脚本 - 独立版，移除 common_paths.sh 依赖
# 版本: v1.1.0
# =============================================================================

set -euo pipefail

# ---------------------- 基本参数与路径 ----------------------
SERVICE_ID="mosquitto"
BASE_DIR="/data/data/com.termux/files/home/servicemanager/$SERVICE_ID"
TERMUX_VAR_DIR="/data/data/com.termux/files/usr/var"
TERMUX_ETC_DIR="/data/data/com.termux/files/usr/etc"

SERVICE_CONTROL_DIR="$TERMUX_VAR_DIR/service/$SERVICE_ID"
MOSQUITTO_CONF_FILE="$TERMUX_ETC_DIR/mosquitto/mosquitto.conf"
MOSQUITTO_PORT=1883
LOG_DIR="$BASE_DIR/logs"
LOG_FILE="$LOG_DIR/status.log"
INSTALL_HISTORY_FILE="/sdcard/isgbackup/$SERVICE_ID/.install_history"

mkdir -p "$LOG_DIR"
log() { echo "[$(date '+%F %T')] [INFO] $*" | tee -a "$LOG_FILE"; }

# ---------------------- 判断 Mosquitto 是否安装 ----------------------
INSTALL_STATUS="unknown"
if command -v mosquitto >/dev/null 2>&1; then
    if [ -f "$MOSQUITTO_CONF_FILE" ]; then
        INSTALL_STATUS="installed"
    else
        INSTALL_STATUS="partial"
    fi
else
    INSTALL_STATUS="not_installed"
fi

log "安装状态: $INSTALL_STATUS"

# 读取安装历史
if [ -f "$INSTALL_HISTORY_FILE" ]; then
    LAST_INSTALL=$(tail -n 1 "$INSTALL_HISTORY_FILE")
    log "最近安装历史: $LAST_INSTALL"
else
    log "没有安装历史记录: $INSTALL_HISTORY_FILE"
fi

# ---------------------- 检查 Mosquitto 运行状态 ----------------------
PID=$(netstat -tulnp 2>/dev/null | grep ":$MOSQUITTO_PORT" | awk '{print $7}' | cut -d'/' -f1 | head -n1)
RUNTIME=""
PORT_STATUS="closed"
STATUS="stopped"

if [ -n "$PID" ]; then
    RUNTIME=$(ps -o etime= -p "$PID" 2>/dev/null | xargs || echo "unknown")
    if netstat -tulnp 2>/dev/null | grep -q "0.0.0.0:$MOSQUITTO_PORT"; then
        PORT_STATUS="listening"
        STATUS="running"
    else
        PORT_STATUS="partial"
        STATUS="starting"
    fi
else
    STATUS="stopped"
fi

log "PID: ${PID:-none}, 状态: $STATUS, 监听端口: $PORT_STATUS, 运行时长: $RUNTIME"

# ---------------------- 输出 JSON 格式 ----------------------
case "${1:-}" in
    --json)
        echo "{\"install_status\":\"$INSTALL_STATUS\",\"status\":\"$STATUS\",\"pid\":\"$PID\",\"runtime\":\"$RUNTIME\",\"port_status\":\"$PORT_STATUS\"}"
        ;;
    *)
        echo "Mosquitto 安装状态: $INSTALL_STATUS"
        echo "运行状态: $STATUS"
        echo "PID: ${PID:-none}"
        echo "运行时间: $RUNTIME"
        echo "端口监听状态: $PORT_STATUS"
        ;;
esac

exit 0

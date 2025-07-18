#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Mosquitto 状态查询脚本 - 参数独立, 增强安装判断
# 版本: v1.1.0
# =============================================================================

set -euo pipefail

# ---------------------- 基本参数与路径 ----------------------
SERVICE_ID="mosquitto"
BASE_DIR="/data/data/com.termux/files/home/servicemanager/$SERVICE_ID"
SERVICE_CONTROL_DIR="/data/data/com.termux/files/usr/var/service/$SERVICE_ID"
CONTROL_FILE="$SERVICE_CONTROL_DIR/supervise/control"
DOWN_FILE="$SERVICE_CONTROL_DIR/down"

TERMUX_VAR_DIR="/data/data/com.termux/files/usr/var"
LOG_DIR="$BASE_DIR/logs"
LOG_FILE="$LOG_DIR/status.log"
BACKUP_DIR="$BASE_DIR/backup"
INSTALL_HISTORY_FILE="$BACKUP_DIR/.install_history"
MOSQUITTO_PORT=1883

mkdir -p "$LOG_DIR"
log() { echo "[$(date '+%F %T')] [INFO] $*" | tee -a "$LOG_FILE"; }

log "查询 Mosquitto 服务状态..."

# ---------------------- 查询进程状态 ----------------------
SERVICE_STATUS="unknown"
MOSQUITTO_PID=$(netstat -tulnp 2>/dev/null | grep ":$MOSQUITTO_PORT" | awk '{print $7}' | cut -d'/' -f1 | head -n1)

if [ -n "$MOSQUITTO_PID" ]; then
    SERVICE_STATUS="running"
    log "Mosquitto 正在运行，PID: $MOSQUITTO_PID"
else
    if [ -f "$DOWN_FILE" ]; then
        SERVICE_STATUS="disabled"
        log "检测到 down 文件，服务已禁用"
    else
        SERVICE_STATUS="stopped"
        log "未检测到 Mosquitto 进程，服务已停止"
    fi
fi

# ---------------------- 判断安装状态 ----------------------
INSTALL_STATUS="unknown"
if [ "$SERVICE_STATUS" == "running" ]; then
    INSTALL_STATUS="installed"
elif [ -f "$INSTALL_HISTORY_FILE" ]; then
    INSTALL_STATUS="installed"
    log "根据安装历史文件，Mosquitto 已安装"
else
    INSTALL_STATUS="not_installed"
    log "未找到安装历史文件，Mosquitto 未安装"
fi

# ---------------------- 输出 JSON 状态 ----------------------
STATUS_JSON="{\n  \"service\": \"$SERVICE_ID\",\n  \"status\": \"$SERVICE_STATUS\",\n  \"install_status\": \"$INSTALL_STATUS\",\n  \"pid\": \"$MOSQUITTO_PID\"\n}"

echo -e "$STATUS_JSON" | tee -a "$LOG_FILE"
log "Mosquitto 状态查询完成"

exit 0

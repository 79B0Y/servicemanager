#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Mosquitto 卸载脚本 - 集成 stop.sh, 参数独立, 全量功能
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
TERMUX_ETC_DIR="/data/data/com.termux/files/usr/etc"

MOSQUITTO_CONF_DIR="$TERMUX_ETC_DIR/mosquitto"
MOSQUITTO_CONF_FILE="$MOSQUITTO_CONF_DIR/mosquitto.conf"
MOSQUITTO_PASSWD_FILE="$MOSQUITTO_CONF_DIR/passwd"
MOSQUITTO_LOG_DIR="$TERMUX_VAR_DIR/log/mosquitto"
MOSQUITTO_PID_FILE="$TERMUX_VAR_DIR/run/mosquitto.pid"

LOG_DIR="$BASE_DIR/logs"
LOG_FILE="$LOG_DIR/uninstall.log"

mkdir -p "$LOG_DIR"
log() { echo "[$(date '+%F %T')] [INFO] $*" | tee -a "$LOG_FILE"; }

log "开始卸载 Mosquitto..."

# ---------------------- 停止服务 ----------------------
STOP_SCRIPT="$BASE_DIR/stop.sh"
if [ -x "$STOP_SCRIPT" ]; then
    log "调用 stop.sh 停止 Mosquitto"
    bash "$STOP_SCRIPT"
else
    if [ -e "$CONTROL_FILE" ]; then
        echo d > "$CONTROL_FILE"
        log "发送 'd' 指令到 $CONTROL_FILE 停止服务"
    else
        log "未找到控制文件，跳过控制指令停止"
    fi
fi
sleep 3

# 强制杀掉 mosquitto 进程
MOSQUITTO_PID=$(pgrep -f "mosquitto.*$MOSQUITTO_CONF_FILE" || true)
if [ -n "$MOSQUITTO_PID" ]; then
    log "强制杀死 Mosquitto 进程 PID=$MOSQUITTO_PID"
    kill -9 "$MOSQUITTO_PID" || true
fi

# ---------------------- 卸载包与清理 ----------------------
log "卸载 Mosquitto 包"
pkg uninstall -y mosquitto || log "pkg 卸载失败，尝试手动清理"

for bin in mosquitto mosquitto_pub mosquitto_sub mosquitto_passwd; do
    rm -f "/data/data/com.termux/files/usr/bin/$bin" || true
done

log "清理配置目录: $MOSQUITTO_CONF_DIR"
rm -rf "$MOSQUITTO_CONF_DIR"

log "清理日志目录: $MOSQUITTO_LOG_DIR"
rm -rf "$MOSQUITTO_LOG_DIR"

log "清理持久化数据目录: $TERMUX_VAR_DIR/lib/mosquitto"
rm -rf "$TERMUX_VAR_DIR/lib/mosquitto"

log "移除 service monitor 目录: $SERVICE_CONTROL_DIR"
rm -rf "$SERVICE_CONTROL_DIR"

log "移除 PID 文件: $MOSQUITTO_PID_FILE"
rm -f "$MOSQUITTO_PID_FILE"

log "Mosquitto 卸载完成"
exit 0

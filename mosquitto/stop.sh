#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Mosquitto 停止脚本 - 参数独立版，移除 common_paths.sh 依赖
# 版本: v1.1.0
# =============================================================================

set -euo pipefail

# ---------------------- 基本参数与路径 ----------------------
SERVICE_ID="mosquitto"
BASE_DIR="/data/data/com.termux/files/home/servicemanager/$SERVICE_ID"
SERVICE_CONTROL_DIR="/data/data/com.termux/files/usr/var/service/$SERVICE_ID"
CONTROL_FILE="$SERVICE_CONTROL_DIR/supervise/control"
DOWN_FILE="$SERVICE_CONTROL_DIR/down"
LOG_DIR="$BASE_DIR/logs"
LOG_FILE="$LOG_DIR/stop.log"
DISABLED_FLAG="$BASE_DIR/.disabled"
MOSQUITTO_PORT=1883

mkdir -p "$LOG_DIR"
log() { echo "[$(date '+%F %T')] [INFO] $*" | tee -a "$LOG_FILE"; }

log "开始停止 Mosquitto 服务..."

# ---------------------- 发送停止信号 ----------------------
if [ -e "$CONTROL_FILE" ]; then
    echo d > "$CONTROL_FILE"
    log "已发送 'd' 指令到 $CONTROL_FILE，要求停止服务"
    
    # 禁用自启动
    touch "$DOWN_FILE"
    log "创建 down 文件，禁用自启动"
else
    log "未找到控制文件 $CONTROL_FILE，跳过控制指令"
fi

sleep 3

# ---------------------- 确认进程停止 ----------------------
MOSQUITTO_PID=$(netstat -tulnp 2>/dev/null | grep ":$MOSQUITTO_PORT" | awk '{print $7}' | cut -d'/' -f1 | head -n1)

if [ -n "$MOSQUITTO_PID" ]; then
    log "检测到 Mosquitto PID: $MOSQUITTO_PID，发送 TERM 信号"
    kill -TERM "$MOSQUITTO_PID" || true
    sleep 2

    if ps -p "$MOSQUITTO_PID" >/dev/null 2>&1; then
        log "进程仍在运行，发送 KILL 信号"
        kill -KILL "$MOSQUITTO_PID" || true
    fi
else
    log "未检测到 Mosquitto 进程"
fi

# ---------------------- 验证端口释放 ----------------------
WAIT=5
while [ $WAIT -gt 0 ]; do
    if netstat -tulnp 2>/dev/null | grep -q ":$MOSQUITTO_PORT"; then
        log "等待端口 $MOSQUITTO_PORT 释放... ($WAIT 秒)"
        sleep 1
        WAIT=$((WAIT-1))
    else
        log "端口 $MOSQUITTO_PORT 已释放"
        break
    fi
    done

# 标记已禁用
log "创建 .disabled 标志文件"
touch "$DISABLED_FLAG"

log "Mosquitto stop success"
exit 0

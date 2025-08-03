#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# isghotel 卸载脚本
# 版本: v1.0.0
# 功能: 完全卸载 isghotel 服务及其相关配置
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# 路径和变量定义
# -----------------------------------------------------------------------------
SERVICE_ID="isghotel"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"
TERMUX_VAR_DIR="/data/data/com.termux/files/usr/var"

CONFIG_FILE="$BASE_DIR/configuration.yaml"
SERVICE_CONTROL_DIR="$TERMUX_VAR_DIR/service/$SERVICE_ID"

LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/uninstall.log"
BACKUP_DIR="/sdcard/isgbackup/$SERVICE_ID"
INSTALL_HISTORY_FILE="$BACKUP_DIR/.install_history"
DISABLED_FLAG="$SERVICE_DIR/.disabled"

ISGCTWING_PORT="22153"

# -----------------------------------------------------------------------------
# 辅助函数
# -----------------------------------------------------------------------------
ensure_directories() {
    mkdir -p "$LOG_DIR"
    mkdir -p "$BACKUP_DIR"
    touch "$INSTALL_HISTORY_FILE" 2>/dev/null || true
}

log() {
    echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"
}

load_mqtt_conf() {
    if [ -f "$CONFIG_FILE" ]; then
        MQTT_HOST=$(grep -Po '^[[:space:]]*host:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1 || echo "127.0.0.1")
        MQTT_PORT_CONFIG=$(grep -Po '^[[:space:]]*port:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1 || echo "1883")
        MQTT_USER=$(grep -Po '^[[:space:]]*username:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1 || echo "admin")
        MQTT_PASS=$(grep -Po '^[[:space:]]*password:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1 || echo "admin")
    else
        MQTT_HOST="127.0.0.1"
        MQTT_PORT_CONFIG="1883"
        MQTT_USER="admin"
        MQTT_PASS="admin"
    fi
}

mqtt_report() {
    local topic="$1"
    local payload="$2"

    if ! nc -z 127.0.0.1 1883 2>/dev/null; then
        echo "[$(date '+%F %T')] [MQTT-OFFLINE] $topic -> $payload" >> "$LOG_FILE"
        return 0
    fi

    load_mqtt_conf
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT_CONFIG" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload" 2>/dev/null || true
    echo "[$(date '+%F %T')] [MQTT] $topic -> $payload" >> "$LOG_FILE"
}

record_uninstall_history() {
    local status="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$timestamp UNINSTALL $status" >> "$INSTALL_HISTORY_FILE"
}

get_isghotel_pid() {
    netstat -tnlp 2>/dev/null | grep ":$ISGCTWING_PORT " | awk '{print $7}' | cut -d'/' -f1 | head -n1
}

# -----------------------------------------------------------------------------
# 主卸载流程
# -----------------------------------------------------------------------------
ensure_directories

log "开始卸载 isghotel"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"uninstalling\",\"message\":\"starting uninstall process\",\"timestamp\":$(date +%s)}"

# -----------------------------------------------------------------------------
# 停止服务
# -----------------------------------------------------------------------------
log "停止服务"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"uninstalling\",\"message\":\"stopping service\",\"timestamp\":$(date +%s)}"

if [ -f "$SERVICE_DIR/stop.sh" ]; then
    bash "$SERVICE_DIR/stop.sh" || true
else
    # 尝试通过 service monitor 停止
    if [ -e "$SERVICE_CONTROL_DIR/supervise/control" ]; then
        echo d > "$SERVICE_CONTROL_DIR/supervise/control" || true
        touch "$SERVICE_CONTROL_DIR/down" || true
    fi

    PID=$(get_isghotel_pid || echo "")
    if [ -n "$PID" ]; then
        log "尝试杀死 isghotel 进程 $PID"
        kill "$PID" 2>/dev/null || true
        sleep 2
        if ps -p "$PID" > /dev/null 2>&1; then
            kill -9 "$PID" 2>/dev/null || true
        fi
    fi
fi

sleep 3

# -----------------------------------------------------------------------------
# 卸载软件包
# -----------------------------------------------------------------------------
log "移除 isghotel 软件包"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"uninstalling\",\"message\":\"removing package\",\"timestamp\":$(date +%s)}"
apt remove -y isghotel || true

# -----------------------------------------------------------------------------
# 删除服务控制目录
# -----------------------------------------------------------------------------
log "删除服务控制目录"
rm -rf "$SERVICE_CONTROL_DIR"
log "已删除: $SERVICE_CONTROL_DIR"

# -----------------------------------------------------------------------------
# 创建 .disabled 标志
# -----------------------------------------------------------------------------
touch "$DISABLED_FLAG"

# -----------------------------------------------------------------------------
# 记录卸载历史
# -----------------------------------------------------------------------------
record_uninstall_history "SUCCESS"

# -----------------------------------------------------------------------------
# 验证卸载状态
# -----------------------------------------------------------------------------
log "验证卸载状态"
UNINSTALL_STATUS="complete"

if get_isghotel_pid > /dev/null 2>&1; then
    log "警告: isghotel 进程仍在运行"
    UNINSTALL_STATUS="partial"
else
    log "✅ isghotel 进程已停止"
fi

if netstat -tulnp 2>/dev/null | grep ":$ISGCTWING_PORT " > /dev/null; then
    log "警告: 端口 $ISGCTWING_PORT 仍被占用"
    UNINSTALL_STATUS="partial"
else
    log "✅ 端口 $ISGCTWING_PORT 已释放"
fi

# -----------------------------------------------------------------------------
# 上报卸载完成
# -----------------------------------------------------------------------------
if [ "$UNINSTALL_STATUS" = "complete" ]; then
    log "isghotel 完全卸载成功"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"uninstalled\",\"message\":\"isghotel completely removed\",\"timestamp\":$(date +%s)}"
else
    log "isghotel 部分卸载，可能需要手动清理"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"uninstalled\",\"message\":\"isghotel partially removed, manual cleanup may be required\",\"timestamp\":$(date +%s)}"
fi

log "卸载摘要:"
log "  - 状态: $UNINSTALL_STATUS"
log "  - 端口释放: $(netstat -tulnp | grep ":$ISGCTWING_PORT " >/dev/null && echo "未完成" || echo "已完成")"
log "  - 服务控制目录: 已删除"

exit 0


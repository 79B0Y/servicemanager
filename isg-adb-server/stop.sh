#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# isg-adb-server 停止脚本
# 版本: v1.0.0
# 功能: 通过 isgservicemonitor 停止 ADB 连接
# =============================================================================

set -euo pipefail
trap 'echo "[ERROR] line $LINENO: command failed." | tee -a "$LOG_FILE"' ERR

# -----------------------------------------------------------------------------
# 路径和变量定义
# -----------------------------------------------------------------------------
SERVICE_ID="isg-adb-server"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"
TERMUX_VAR_DIR="/data/data/com.termux/files/usr/var"

CONFIG_FILE="$BASE_DIR/configuration.yaml"
SERVICE_CONTROL_DIR="$TERMUX_VAR_DIR/service/$SERVICE_ID"
CONTROL_FILE="$SERVICE_CONTROL_DIR/supervise/control"
DOWN_FILE="$SERVICE_CONTROL_DIR/down"

LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/stop.log"
DISABLED_FLAG="$SERVICE_DIR/.disabled"

ADB_PORT="5555"
ADB_HOST="127.0.0.1"
ADB_DEVICE="${ADB_HOST}:${ADB_PORT}"

# -----------------------------------------------------------------------------
# 辅助函数
# -----------------------------------------------------------------------------
ensure_directories() {
    mkdir -p "$LOG_DIR"
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

check_adb_connected() {
    adb devices 2>/dev/null | grep -q "$ADB_DEVICE" && return 0 || return 1
}

mqtt_report() {
    local topic="$1"
    local payload="$2"
    
    # 检查 MQTT broker 是否可用
    if ! nc -z 127.0.0.1 1883 2>/dev/null; then
        echo "[$(date '+%F %T')] [MQTT-OFFLINE] $topic -> $payload" >> "$LOG_FILE"
        return 0
    fi
    
    load_mqtt_conf
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT_CONFIG" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload" 2>/dev/null || true
    echo "[$(date '+%F %T')] [MQTT] $topic -> $payload" >> "$LOG_FILE"
}

# -----------------------------------------------------------------------------
# 主停止流程
# -----------------------------------------------------------------------------
ensure_directories

log "停止 isg-adb-server 服务"
mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"stopping\",\"message\":\"stopping service\",\"timestamp\":$(date +%s)}"

# -----------------------------------------------------------------------------
# 创建禁用标志（必须最先做，防止 autocheck 重新连接）
# -----------------------------------------------------------------------------
touch "$DISABLED_FLAG"
log "已创建 .disabled 标志以防止自动重连"

# -----------------------------------------------------------------------------
# 检查服务是否已经停止
# -----------------------------------------------------------------------------
if ! check_adb_connected; then
    log "isg-adb-server 已经停止 (ADB 未连接)"
    # 确保创建 down 文件
    touch "$DOWN_FILE"
    mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"success\",\"message\":\"service already stopped\",\"timestamp\":$(date +%s)}"
    exit 0
fi

# -----------------------------------------------------------------------------
# 创建 down 文件禁用自启动（防止 supervise 重启服务）
# -----------------------------------------------------------------------------
touch "$DOWN_FILE"
log "已创建 down 文件以禁用自启动"
mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"stopping\",\"message\":\"created down file to disable auto-start\",\"timestamp\":$(date +%s)}"

# -----------------------------------------------------------------------------
# 停止 supervise 管理的服务（不杀死 supervise 进程本身）
# -----------------------------------------------------------------------------
if [ -e "$CONTROL_FILE" ]; then
    log "停止 supervise 管理的 $SERVICE_ID 服务"
    
    # 方法 1: 使用 sv stop (停止并禁用)
    if command -v sv >/dev/null 2>&1; then
        # 先 stop，再 down
        sv stop "$SERVICE_CONTROL_DIR" 2>/dev/null || true
        sleep 1
        sv down "$SERVICE_CONTROL_DIR" 2>/dev/null || true
        log "已使用 sv stop + sv down 命令停止服务"
        sleep 2
    fi
    
    # 方法 2: 发送控制信号
    # 发送 't' (terminate) 而不是 'd' (down)
    echo t > "$CONTROL_FILE" 2>/dev/null || true
    log "已发送 't' 命令终止服务进程"
    sleep 1
    
    # 再发送 'd' 防止重启
    echo d > "$CONTROL_FILE" 2>/dev/null || true
    log "已发送 'd' 命令禁止重启"
    sleep 1
    
    # 查找并杀死由 run 脚本启动的所有相关进程
    # 注意：不杀死 supervise 进程本身，只杀死它管理的子进程
    pkill -f "adb connect.*$ADB_DEVICE" 2>/dev/null || true
    
    # 同时杀死可能在运行的 run 脚本实例
    pkill -f "$SERVICE_CONTROL_DIR/run" 2>/dev/null || true
    log "已终止所有服务子进程"
else
    log "控制文件不存在,跳过服务停止通知"
fi

# -----------------------------------------------------------------------------
# 断开 ADB 连接
# -----------------------------------------------------------------------------
log "断开 ADB 连接"
adb disconnect "$ADB_DEVICE" 2>/dev/null || true
# 多次断开以确保彻底断开
sleep 1
adb disconnect "$ADB_DEVICE" 2>/dev/null || true

# -----------------------------------------------------------------------------
# 等待 ADB 断开
# -----------------------------------------------------------------------------
log "等待 ADB 断开"
mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"stopping\",\"message\":\"waiting for ADB disconnection\",\"timestamp\":$(date +%s)}"

TRIES=0
MAX_TRIES=10  # 减少等待次数，因为我们已经主动断开了

while (( TRIES < MAX_TRIES )); do
    if ! check_adb_connected; then
        log "isg-adb-server 已成功停止 (ADB 已断开)"
        break
    fi
    
    # 如果还是连接着，继续尝试断开
    if [ $TRIES -gt 2 ]; then
        log "尝试再次断开 ADB 连接 (第 $TRIES 次)"
        adb disconnect "$ADB_DEVICE" 2>/dev/null || true
    fi
    
    # 如果多次尝试失败，尝试重启 adb server
    if [ $TRIES -eq 6 ]; then
        log "尝试重启 ADB server"
        adb kill-server 2>/dev/null || true
        sleep 2
        adb start-server 2>/dev/null || true
        sleep 1
    fi
    
    sleep 3
    TRIES=$((TRIES+1))
done

# -----------------------------------------------------------------------------
# 检查停止结果
# -----------------------------------------------------------------------------
if check_adb_connected; then
    log "ADB 在 $((MAX_TRIES*3)) 秒后仍未断开,但已禁用自启动和停止服务"
    mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"warning\",\"message\":\"ADB still connected after stop timeout, but service and auto-start disabled\",\"timeout\":$((MAX_TRIES*3)),\"timestamp\":$(date +%s)}"
    
    log "提示: ADB 连接可能由其他进程维护，可以尝试:"
    log "  1. adb kill-server && adb start-server"
    log "  2. 检查是否有其他服务在维护 ADB 连接"
    log "  3. 重启 Termux"
    exit 1
fi

# -----------------------------------------------------------------------------
# 停止成功
# -----------------------------------------------------------------------------
log "服务已停止 (ADB 已断开, .disabled 标志已创建)"
mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"success\",\"message\":\"service stopped and disabled\",\"timestamp\":$(date +%s)}"

log "isg-adb-server 服务停止完成"
exit 0

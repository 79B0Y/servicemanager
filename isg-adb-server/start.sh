#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# isg-adb-server 启动脚本
# 版本: v1.0.0
# 功能: 通过 isgservicemonitor 启动 ADB 连接
# =============================================================================

set -euo pipefail

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
LOG_FILE="$LOG_DIR/start.log"
DISABLED_FLAG="$SERVICE_DIR/.disabled"

ADB_PORT="5555"
ADB_HOST="127.0.0.1"
ADB_DEVICE="${ADB_HOST}:${ADB_PORT}"
MAX_TRIES=30

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
    
    # 如果还没有 MQTT broker,只记录到日志
    if ! nc -z 127.0.0.1 1883 2>/dev/null; then
        echo "[$(date '+%F %T')] [MQTT-PENDING] $topic -> $payload" >> "$LOG_FILE"
        return 0
    fi
    
    load_mqtt_conf
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT_CONFIG" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload" 2>/dev/null || true
    echo "[$(date '+%F %T')] [MQTT] $topic -> $payload" >> "$LOG_FILE"
}

# -----------------------------------------------------------------------------
# 主启动流程
# -----------------------------------------------------------------------------
ensure_directories

log "启动 isg-adb-server 服务"
mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"starting\",\"message\":\"starting service\",\"timestamp\":$(date +%s)}"

# -----------------------------------------------------------------------------
# 移除禁用标志和 down 文件
# -----------------------------------------------------------------------------
if [ -f "$DISABLED_FLAG" ]; then
    rm -f "$DISABLED_FLAG"
    log "已移除 .disabled 标志"
fi

if [ -f "$DOWN_FILE" ]; then
    rm -f "$DOWN_FILE"
    log "已移除 down 文件以启用自启动"
    mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"starting\",\"message\":\"removed down file to enable auto-start\",\"timestamp\":$(date +%s)}"
fi

# -----------------------------------------------------------------------------
# 检查服务是否已经在运行
# -----------------------------------------------------------------------------
if check_adb_connected; then
    log "isg-adb-server 已经在运行 (ADB 已连接)"
    mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"success\",\"message\":\"service already running\",\"timestamp\":$(date +%s)}"
    exit 0
fi

# -----------------------------------------------------------------------------
# 启动服务
# -----------------------------------------------------------------------------
if [ -e "$CONTROL_FILE" ]; then
    echo u > "$CONTROL_FILE"
    log "已发送 'u' 命令到 $CONTROL_FILE"
else
    log "控制文件不存在,尝试直接连接 ADB"
    mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"starting\",\"message\":\"control file not found, connecting ADB directly\",\"timestamp\":$(date +%s)}"
    
    # 直接执行 adb connect
    if adb connect "$ADB_DEVICE" 2>/dev/null; then
        log "ADB 连接成功"
        mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"success\",\"message\":\"ADB connected successfully\",\"timestamp\":$(date +%s)}"
        exit 0
    else
        log "ADB 连接失败"
        mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"failed\",\"message\":\"ADB connection failed\",\"timestamp\":$(date +%s)}"
        exit 1
    fi
fi

# -----------------------------------------------------------------------------
# 等待服务进入运行状态
# -----------------------------------------------------------------------------
log "等待 ADB 连接"
mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"starting\",\"message\":\"waiting for ADB connection\",\"timestamp\":$(date +%s)}"

TRIES=0
while (( TRIES < MAX_TRIES )); do
    # 检查 ADB 是否已连接
    if check_adb_connected; then
        log "isg-adb-server 服务启动成功 (ADB 已连接到 $ADB_DEVICE)"
        mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"success\",\"message\":\"service started successfully\",\"device\":\"$ADB_DEVICE\",\"timestamp\":$(date +%s)}"
        exit 0
    fi
    
    sleep 5
    TRIES=$((TRIES+1))
done

# -----------------------------------------------------------------------------
# 启动失败：恢复禁用状态
# -----------------------------------------------------------------------------
log "服务在 $((MAX_TRIES*5)) 秒内未能启动,恢复禁用状态"
touch "$DISABLED_FLAG"
touch "$DOWN_FILE"
mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"failed\",\"message\":\"service failed to reach running state\",\"timeout\":$((MAX_TRIES*5)),\"timestamp\":$(date +%s)}"

log "提示: 请检查以下问题:"
log "  1. 是否有 root 权限配置 ADB TCP 端口"
log "  2. 手动执行: su -c 'setprop service.adb.tcp.port 5555 && stop adbd && start adbd'"
log "  3. 手动执行: adb connect 127.0.0.1:5555"

exit 1

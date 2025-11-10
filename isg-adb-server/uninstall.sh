#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# isg-adb-server 卸载脚本
# 版本: v1.0.0
# 功能: 完全卸载 android-tools 和相关配置
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

LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/uninstall.log"
BACKUP_DIR="/sdcard/isgbackup/$SERVICE_ID"
INSTALL_HISTORY_FILE="$BACKUP_DIR/.install_history"
DISABLED_FLAG="$SERVICE_DIR/.disabled"

ADB_PORT="5555"
ADB_HOST="127.0.0.1"
ADB_DEVICE="${ADB_HOST}:${ADB_PORT}"

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

record_uninstall_history() {
    local status="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$timestamp UNINSTALL $status" >> "$INSTALL_HISTORY_FILE"
}

# -----------------------------------------------------------------------------
# 主卸载流程
# -----------------------------------------------------------------------------
ensure_directories

log "开始卸载 isg-adb-server"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"uninstalling\",\"message\":\"starting uninstall process\",\"timestamp\":$(date +%s)}"

# -----------------------------------------------------------------------------
# 停止服务
# -----------------------------------------------------------------------------
log "停止服务"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"uninstalling\",\"message\":\"stopping service\",\"timestamp\":$(date +%s)}"

if [ -f "$SERVICE_DIR/stop.sh" ]; then
    bash "$SERVICE_DIR/stop.sh" || true
else
    # 手动停止服务
    log "stop.sh 不存在，手动停止服务"
    
    # 通过 isgservicemonitor 停止
    if [ -e "$SERVICE_CONTROL_DIR/supervise/control" ]; then
        echo d > "$SERVICE_CONTROL_DIR/supervise/control" || true
        touch "$SERVICE_CONTROL_DIR/down" || true
    fi
    
    # 断开 ADB 连接
    if check_adb_connected; then
        log "断开 ADB 连接"
        adb disconnect "$ADB_DEVICE" 2>/dev/null || true
        adb kill-server 2>/dev/null || true
    fi
fi

sleep 3

# 确认 ADB 已断开
if check_adb_connected; then
    log "警告: ADB 仍然连接，尝试强制断开"
    adb disconnect "$ADB_DEVICE" 2>/dev/null || true
    adb kill-server 2>/dev/null || true
    sleep 2
fi

# -----------------------------------------------------------------------------
# 卸载 android-tools
# -----------------------------------------------------------------------------
log "卸载 android-tools 包"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"uninstalling\",\"message\":\"uninstalling android-tools package\",\"timestamp\":$(date +%s)}"

if pkg list-installed 2>/dev/null | grep -q "^android-tools/"; then
    if pkg uninstall -y android-tools; then
        log "android-tools 卸载成功"
    else
        log "警告: android-tools 卸载失败"
    fi
else
    log "android-tools 未安装或已被卸载"
fi

# -----------------------------------------------------------------------------
# 移除服务控制目录
# -----------------------------------------------------------------------------
log "移除服务控制目录"
if [ -d "$SERVICE_CONTROL_DIR" ]; then
    rm -rf "$SERVICE_CONTROL_DIR"
    log "已移除服务控制目录: $SERVICE_CONTROL_DIR"
fi

# -----------------------------------------------------------------------------
# 创建 .disabled 标志
# -----------------------------------------------------------------------------
log "创建 .disabled 标志"
touch "$DISABLED_FLAG"

# -----------------------------------------------------------------------------
# 记录卸载历史
# -----------------------------------------------------------------------------
record_uninstall_history "SUCCESS"

# -----------------------------------------------------------------------------
# 验证卸载完成
# -----------------------------------------------------------------------------
log "验证卸载状态"

UNINSTALL_STATUS="complete"

# 检查 android-tools 是否还存在
if pkg list-installed 2>/dev/null | grep -q "^android-tools/"; then
    log "警告: android-tools 包仍然存在"
    UNINSTALL_STATUS="partial"
else
    log "✅ android-tools 包已移除"
fi

# 检查 ADB 是否还在连接
if check_adb_connected; then
    log "警告: ADB 仍然连接"
    UNINSTALL_STATUS="partial"
else
    log "✅ ADB 连接已断开"
fi

# 检查服务控制目录是否还存在
if [ -d "$SERVICE_CONTROL_DIR" ]; then
    log "警告: 服务控制目录仍然存在"
    UNINSTALL_STATUS="partial"
else
    log "✅ 服务控制目录已移除"
fi

# -----------------------------------------------------------------------------
# 上报卸载完成
# -----------------------------------------------------------------------------
if [ "$UNINSTALL_STATUS" = "complete" ]; then
    log "isg-adb-server 完全卸载成功"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"uninstalled\",\"message\":\"isg-adb-server completely removed\",\"timestamp\":$(date +%s)}"
else
    log "isg-adb-server 部分卸载，可能需要手动清理"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"uninstalled\",\"message\":\"isg-adb-server partially removed, manual cleanup may be required\",\"timestamp\":$(date +%s)}"
fi

log "卸载摘要:"
log "  - 状态: $UNINSTALL_STATUS"
log "  - android-tools: $(pkg list-installed 2>/dev/null | grep -q "^android-tools/" && echo "未完成" || echo "已完成")"
log "  - ADB 连接: $(check_adb_connected && echo "未断开" || echo "已断开")"
log "  - 服务监控: 已清理"

exit 0

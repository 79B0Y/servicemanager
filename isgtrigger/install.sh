#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# isgtrigger 安装脚本
# 版本: v1.0.0
# 功能: 安装 isgtrigger 服务 (.deb 包方式)
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# 路径和变量定义
# -----------------------------------------------------------------------------
SERVICE_ID="isgtrigger"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"
TERMUX_VAR_DIR="/data/data/com.termux/files/usr/var"

CONFIG_FILE="$BASE_DIR/configuration.yaml"
SERVICEUPDATE_FILE="$BASE_DIR/serviceupdate.json"
VERSION_FILE="$SERVICE_DIR/VERSION"

SERVICE_CONTROL_DIR="$TERMUX_VAR_DIR/service/$SERVICE_ID"
CONTROL_FILE="$SERVICE_CONTROL_DIR/supervise/control"
DOWN_FILE="$SERVICE_CONTROL_DIR/down"
RUN_FILE="$SERVICE_CONTROL_DIR/run"

LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/install.log"
BACKUP_DIR="/sdcard/isgbackup/$SERVICE_ID"
INSTALL_HISTORY_FILE="$BACKUP_DIR/.install_history"

INSTALL_URL="https://eucfg.linklinkiot.com/isg/$SERVICE_ID-latest-termux-arm.deb"
PACKAGE_FILE="$SERVICE_ID-latest-termux-arm.deb"
PORT="61833"

MAX_WAIT=60
INTERVAL=3

START_TIME=$(date +%s)

# -----------------------------------------------------------------------------
# 辅助函数
# -----------------------------------------------------------------------------
ensure_directories() {
    mkdir -p "$LOG_DIR" "$BACKUP_DIR" "$SERVICE_CONTROL_DIR"
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

record_install_history() {
    local status="$1"
    local version="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$timestamp INSTALL $status $version" >> "$INSTALL_HISTORY_FILE"
}

get_pid() {
    lsof -i :"$PORT" -sTCP:LISTEN -t 2>/dev/null | head -n1
}

# -----------------------------------------------------------------------------
# 安装流程
# -----------------------------------------------------------------------------
ensure_directories
log "开始安装 $SERVICE_ID"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"starting installation\",\"timestamp\":$(date +%s)}"

# 下载并安装
log "下载 $SERVICE_ID 安装包"
wget "$INSTALL_URL" -O "$PACKAGE_FILE" >> "$LOG_FILE" 2>&1

log "安装 .deb 包"
if ! dpkg -i "$PACKAGE_FILE" >> "$LOG_FILE" 2>&1; then
    log "安装失败"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"dpkg installation failed\",\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

rm -f "$PACKAGE_FILE"*


# -----------------------------------------------------------------------------
# 启动服务进行测试
# -----------------------------------------------------------------------------
log "启动服务测试"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"starting service\",\"timestamp\":$(date +%s)}"

if [ -e "$CONTROL_FILE" ]; then
    echo u > "$CONTROL_FILE"
    rm -f "$DOWN_FILE"
else
    "$SERVICE_ID" > /dev/null 2>&1 &
fi

# -----------------------------------------------------------------------------
# 检查服务端口监听状态
# -----------------------------------------------------------------------------
log "等待服务端口 $PORT"
WAITED=0
while [ "$WAITED" -lt "$MAX_WAIT" ]; do
    if get_pid >/dev/null; then
        log "$SERVICE_ID 启动成功"
        break
    fi
    sleep "$INTERVAL"
    WAITED=$((WAITED + INTERVAL))
done

if [ "$WAITED" -ge "$MAX_WAIT" ]; then
    log "启动超时: $SERVICE_ID 未监听 $PORT"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"service did not start in time\",\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

# -----------------------------------------------------------------------------
# 写入版本信息
# -----------------------------------------------------------------------------
VERSION_STR=$(dpkg -s "$SERVICE_ID" 2>/dev/null | grep '^Version:' | awk '{print $2}' || echo "unknown")
echo "$VERSION_STR" > "$VERSION_FILE"
record_install_history "SUCCESS" "$VERSION_STR"

# -----------------------------------------------------------------------------
# 安装完成
# -----------------------------------------------------------------------------
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
log "$SERVICE_ID 安装完成，耗时 ${DURATION}s"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"installed\",\"version\":\"$VERSION_STR\",\"duration\":$DURATION,\"timestamp\":$END_TIME}"

exit 0

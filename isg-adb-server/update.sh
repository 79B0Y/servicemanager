#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# isg-adb-server 更新脚本
# 版本: v1.0.0
# 功能: 更新 android-tools 包
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# 路径和配置定义
# -----------------------------------------------------------------------------
SERVICE_ID="isg-adb-server"

# 基础目录
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"
CONFIG_FILE="$BASE_DIR/configuration.yaml"

# 日志和状态文件
LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/update.log"
VERSION_FILE="$SERVICE_DIR/VERSION"
UPDATE_HISTORY_FILE="$SERVICE_DIR/.update_history"

# 临时目录
TERMUX_TMP_DIR="/data/data/com.termux/files/usr/tmp"
TEMP_DIR="$TERMUX_TMP_DIR/${SERVICE_ID}_temp"

# 脚本参数
MAX_WAIT="${MAX_WAIT:-300}"
INTERVAL="${INTERVAL:-5}"

# =============================================================================
# 工具函数
# =============================================================================
ensure_directories() {
    mkdir -p "$LOG_DIR"
    mkdir -p "$TEMP_DIR"
    touch "$UPDATE_HISTORY_FILE" 2>/dev/null || true
}

cleanup() {
    rm -rf "$TEMP_DIR" 2>/dev/null || true
}

trap cleanup EXIT

log() {
    echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"
}

load_mqtt_conf() {
    if [[ -f "$CONFIG_FILE" ]]; then
        MQTT_HOST=$(grep -Po '^[[:space:]]*host:[[:space:]]*\K.*' "$CONFIG_FILE" 2>/dev/null | head -n1 || echo "127.0.0.1")
        MQTT_PORT=$(grep -Po '^[[:space:]]*port:[[:space:]]*\K.*' "$CONFIG_FILE" 2>/dev/null | head -n1 || echo "1883")
        MQTT_USER=$(grep -Po '^[[:space:]]*username:[[:space:]]*\K.*' "$CONFIG_FILE" 2>/dev/null | head -n1 || echo "admin")
        MQTT_PASS=$(grep -Po '^[[:space:]]*password:[[:space:]]*\K.*' "$CONFIG_FILE" 2>/dev/null | head -n1 || echo "admin")
    else
        MQTT_HOST="127.0.0.1"
        MQTT_PORT="1883"
        MQTT_USER="admin"
        MQTT_PASS="admin"
    fi
}

mqtt_report() {
    local topic="$1"
    local payload="$2"
    load_mqtt_conf
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload" || true
    log "[MQTT] $topic -> $payload"
}

get_android_tools_version() {
    pkg show android-tools 2>/dev/null | grep -oP '(?<=Version: )[0-9.r\-]+' | head -n1 || echo "unknown"
}

record_update_history() {
    local status="$1"
    local old_version="$2"
    local new_version="$3"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$timestamp UPDATE $status $old_version -> $new_version" >> "$UPDATE_HISTORY_FILE"
}

# =============================================================================
# 主程序开始
# =============================================================================
ensure_directories
START_TIME=$(date +%s)

log "starting isg-adb-server update process"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"message\":\"starting update process\",\"timestamp\":$(date +%s)}"

# -----------------------------------------------------------------------------
# 检查当前版本
# -----------------------------------------------------------------------------
CURRENT_VERSION=$(get_android_tools_version)
log "current android-tools version: $CURRENT_VERSION"

if [ "$CURRENT_VERSION" = "unknown" ]; then
    log "android-tools not installed, please run install.sh first"
    mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"android-tools not installed\",\"timestamp\":$(date +%s)}"
    exit 1
fi

# -----------------------------------------------------------------------------
# 停止服务
# -----------------------------------------------------------------------------
log "stopping service before update"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"message\":\"stopping service\",\"timestamp\":$(date +%s)}"

bash "$SERVICE_DIR/stop.sh" || true
sleep 3

# -----------------------------------------------------------------------------
# 更新 android-tools
# -----------------------------------------------------------------------------
log "updating android-tools package"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"message\":\"updating android-tools package\",\"timestamp\":$(date +%s)}"

if ! pkg update && pkg upgrade -y android-tools; then
    log "failed to update android-tools"
    mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"android-tools update failed\",\"timestamp\":$(date +%s)}"
    record_update_history "FAILED" "$CURRENT_VERSION" "$CURRENT_VERSION"
    exit 1
fi

# -----------------------------------------------------------------------------
# 检查新版本
# -----------------------------------------------------------------------------
NEW_VERSION=$(get_android_tools_version)
log "new android-tools version: $NEW_VERSION"

if [ "$NEW_VERSION" = "$CURRENT_VERSION" ]; then
    log "android-tools is already up to date"
    mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"skipped\",\"message\":\"already up to date\",\"version\":\"$NEW_VERSION\",\"timestamp\":$(date +%s)}"
    record_update_history "SKIPPED" "$CURRENT_VERSION" "$NEW_VERSION"
else
    log "android-tools updated from $CURRENT_VERSION to $NEW_VERSION"
    record_update_history "SUCCESS" "$CURRENT_VERSION" "$NEW_VERSION"
fi

# -----------------------------------------------------------------------------
# 启动服务
# -----------------------------------------------------------------------------
log "starting service after update"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"message\":\"starting service\",\"timestamp\":$(date +%s)}"

bash "$SERVICE_DIR/start.sh" || true

# -----------------------------------------------------------------------------
# 等待服务启动
# -----------------------------------------------------------------------------
log "waiting for service ready"
WAITED=0
while [ "$WAITED" -lt "$MAX_WAIT" ]; do
    if bash "$SERVICE_DIR/status.sh" --quiet; then
        log "service is running after ${WAITED}s"
        break
    fi
    sleep "$INTERVAL"
    WAITED=$((WAITED + INTERVAL))
done

# -----------------------------------------------------------------------------
# 记录新版本
# -----------------------------------------------------------------------------
echo "$NEW_VERSION" > "$VERSION_FILE"

# -----------------------------------------------------------------------------
# 更新完成
# -----------------------------------------------------------------------------
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

log "isg-adb-server update completed in ${DURATION}s"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"updated\",\"old_version\":\"$CURRENT_VERSION\",\"new_version\":\"$NEW_VERSION\",\"duration\":$DURATION,\"timestamp\":$END_TIME}"

log "================================================"
log "更新摘要:"
log "  - 旧版本: $CURRENT_VERSION"
log "  - 新版本: $NEW_VERSION"
log "  - 更新耗时: ${DURATION}s"
log "================================================"

exit 0

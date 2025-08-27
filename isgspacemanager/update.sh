#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# isgspacemanager 升级脚本 - 独立版本
# 版本: v1.0.0
# 功能: 升级 isgspacemanager 到指定版本
# 特点: 完全独立，不依赖 common_paths.sh
# =============================================================================

set -euo pipefail

# 基础配置
SERVICE_ID="isgspacemanager"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"

CONFIG_FILE="$BASE_DIR/configuration.yaml"
SERVICEUPDATE_FILE="$BASE_DIR/serviceupdate.json"
VERSION_FILE="$SERVICE_DIR/VERSION.yaml"

LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/update.log"
TEMP_DIR="/data/data/com.termux/files/usr/tmp"
BACKUP_DIR="${BACKUP_DIR:-/sdcard/isgbackup/$SERVICE_ID}"
UPDATE_HISTORY_FILE="$BACKUP_DIR/.update_history"

DEFAULT_VERSION="latest"

# 从 serviceupdate.json 中获取目标版本
parse_target_version() {
    if [[ -f "$SERVICEUPDATE_FILE" ]]; then
        TARGET_VERSION=$(jq -r ".services[] | select(.id==\"$SERVICE_ID\") | .latest_service_version // empty" "$SERVICEUPDATE_FILE")
        if [[ -z "$TARGET_VERSION" || "$TARGET_VERSION" == "null" ]]; then
            TARGET_VERSION="$DEFAULT_VERSION"
        fi
    else
        TARGET_VERSION="$DEFAULT_VERSION"
    fi
}
ensure_directories() {
    mkdir -p "$LOG_DIR" "$BACKUP_DIR" "$TEMP_DIR" 2>/dev/null || true
}

get_version() {
    if dpkg -s isgspacemanager >/dev/null 2>&1; then
        dpkg -s isgspacemanager | grep '^Version:' | awk '{print $2}' || echo "unknown"
    elif [ -x "$BINARY_PATH" ]; then
        "$BINARY_PATH" --version 2>/dev/null | head -n1 || echo "unknown"
    else
        echo "unknown"
    fi
}


log() {
    echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"
}

load_mqtt_conf() {
    if [[ -f "$CONFIG_FILE" ]]; then
        MQTT_HOST=$(grep -Po '^[[:space:]]*host:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1 || echo "127.0.0.1")
        MQTT_PORT=$(grep -Po '^[[:space:]]*port:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1 || echo "1883")
        MQTT_USER=$(grep -Po '^[[:space:]]*username:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1 || echo "admin")
        MQTT_PASS=$(grep -Po '^[[:space:]]*password:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1 || echo "admin")
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
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload" 2>/dev/null || true
    log "[MQTT] $topic -> $payload"
}

record_update_history() {
    local status="$1"
    local old_version="$2"
    local new_version="$3"
    local reason="$4"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    ensure_directories
    if [ "$status" = "SUCCESS" ]; then
        echo "$timestamp SUCCESS $old_version -> $new_version" >> "$UPDATE_HISTORY_FILE"
    else
        echo "$timestamp FAILED $old_version -> $new_version ($reason)" >> "$UPDATE_HISTORY_FILE"
    fi
}

# =============================================================================
# 主程序
# =============================================================================

START_TIME=$(date +%s)
ensure_directories
parse_target_version
CURRENT_VERSION_FILE="$SERVICE_DIR/.current_version"
CURRENT_VERSION="$(get_version)"

log "starting isgspacemanager upgrade from $CURRENT_VERSION to $TARGET_VERSION"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"target_version\":\"$TARGET_VERSION\",\"message\":\"starting update process\",\"timestamp\":$(date +%s)}"

log "stopping isgspacemanager service"
$SERVICE_DIR/stop.sh || true
sleep 3

log "downloading and installing .deb package"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"downloading and installing .deb\",\"timestamp\":$(date +%s)}"

cd "$TEMP_DIR"

if ! wget -q "https://eucfg.linklinkiot.com/isg/$SERVICE_ID-$TARGET_VERSION-termux-arm.deb" -O "$SERVICE_ID.deb"; then
    log "failed to download .deb file"
    mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"failed to download deb package\",\"timestamp\":$(date +%s)}"
    record_update_history "FAILED" "$CURRENT_VERSION" "$TARGET_VERSION" "download error"
    exit 1
fi

dpkg -i "$SERVICE_ID.deb" >> "$LOG_FILE" 2>&1 || true
rm -f "$SERVICE_ID.deb"

# 版本号记录
UPDATED_VERSION="$(get_version)"
echo "$UPDATED_VERSION" > "$CURRENT_VERSION_FILE"

log "restarting isgspacemanager"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"message\":\"restarting service\",\"timestamp\":$(date +%s)}"
$SERVICE_DIR/start.sh

# 健康检查（监听端口）
log "waiting for port 22102 to be available"
PORT=22102
MAX_WAIT=60
INTERVAL=3
WAITED=0

while [ $WAITED -lt $MAX_WAIT ]; do
    if lsof -i :$PORT >/dev/null 2>&1; then
        DURATION=$(( $(date +%s) - START_TIME ))
        log "isgspacemanager is running (port $PORT detected)"
        record_update_history "SUCCESS" "$CURRENT_VERSION" "$UPDATED_VERSION" ""
        mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"success\",\"old_version\":\"$CURRENT_VERSION\",\"new_version\":\"$UPDATED_VERSION\",\"duration\":$DURATION,\"timestamp\":$(date +%s)}"

        # 写入 VERSION.yaml
        echo "version: $UPDATED_VERSION" > "$VERSION_FILE"
        exit 0
    fi
    sleep $INTERVAL
    WAITED=$((WAITED + INTERVAL))
done

log "service did not start in time"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"port $PORT not ready in time\",\"timestamp\":$(date +%s)}"
record_
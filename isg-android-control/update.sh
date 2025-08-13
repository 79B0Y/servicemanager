#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# isg-android-control 升级脚本
# 版本: v1.0.0
# 功能: 升级 isg-android-control 服务
# 注意: 根据基础设计要求，isg-android-control 没有升级功能
# =============================================================================

set -euo pipefail

# ------------------- 路径与变量 -------------------
SERVICE_ID="isg-android-control"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"
CONFIG_FILE="$BASE_DIR/configuration.yaml"

LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/update.log"

START_TIME=$(date +%s)

# ------------------- 工具函数 -------------------
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

mqtt_report() {
    local topic="$1"
    local payload="$2"
    if ! nc -z 127.0.0.1 1883 2>/dev/null; then
        echo "[$(date '+%F %T')] [MQTT-OFFLINE] $topic -> $payload" >> "$LOG_FILE"
        return
    fi
    load_mqtt_conf
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT_CONFIG" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload" 2>/dev/null || true
    echo "[$(date '+%F %T')] [MQTT] $topic -> $payload" >> "$LOG_FILE"
}

# ------------------- 主流程 -------------------
ensure_directories

log "isg-android-control 升级请求"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"not_supported\",\"message\":\"update not supported for isg-android-control\",\"timestamp\":$(date +%s)}"

# 根据基础设计要求，isg-android-control 没有升级功能
log "isg-android-control 服务不支持升级功能"
log "如需更新，请使用以下步骤："
log "1. 卸载当前版本: bash uninstall.sh"
log "2. 重新安装新版本: bash install.sh"

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

mqtt_report "isg/update/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"skipped\",\"message\":\"upgrade not supported, manual reinstall required\",\"duration\":$DURATION,\"timestamp\":$END_TIME}"

log "升级操作完成 - 不支持自动升级"
exit 0

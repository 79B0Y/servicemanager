#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Z-Wave JS UI 还原脚本（重构版 with 完整配置 & 支持 zip 备份）
# =============================================================================

set -euo pipefail

SERVICE_ID="zwave-js-ui"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"
CONFIG_FILE="$BASE_DIR/configuration.yaml"
BACKUP_DIR="/sdcard/isgbackup/$SERVICE_ID"
PROOT_DISTRO="ubuntu"
ZUI_DATA_DIR="/usr/src/app/store"
ZUI_CONFIG_FILE="$ZUI_DATA_DIR/settings.json"
TERMUX_TMP_DIR="/data/data/com.termux/files/usr/tmp"
CUSTOM_BACKUP_FILE="${RESTORE_FILE:-}"
CUSTOM_CFG_DIR="/sdcard/isgbackup/zwave-js-ui/custom-device-configs"
SERIAL_RESULT_FILE="/sdcard/isgbackup/serialport/latest.json"

log() { echo "[$(date '+%F %T')] $*"; }

mqtt_report() {
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$1" -m "$2" || true
}

is_service_running() {
    bash "$SERVICE_DIR/status.sh" | grep -q "running"
}

generate_random_key() {
    openssl rand -hex 16 || date +%s | md5sum | cut -d' ' -f1
}

load_mqtt_conf() {
    if [ -f "$CONFIG_FILE" ]; then
        MQTT_HOST=$(grep -Po '^[[:space:]]*host:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1 || echo "127.0.0.1")
        MQTT_PORT=$(grep -Po '^[[:space:]]*port:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1 || echo "1883")
        MQTT_USER=$(grep -Po '^[[:space:]]*username:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1 || echo "admin")
        MQTT_PASS=$(grep -Po '^[[:space:]]*password:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1 || echo "admin")
    else
        MQTT_HOST="127.0.0.1"
        MQTT_PORT="1883"
        MQTT_USER="admin"
        MQTT_PASS="admin"
        log "⚠️ 未找到配置文件，使用默认 MQTT 配置"
    fi
    log "✅ MQTT配置: host=$MQTT_HOST, port=$MQTT_PORT, username=$MQTT_USER, password=$MQTT_PASS"
}

probe_serial_port() {
    if [ -f "$SERIAL_RESULT_FILE" ]; then
        PORT=$(jq -r '.results[] | select(.type=="zwave") | .port' "$SERIAL_RESULT_FILE" | head -n1)
        if [ -n "$PORT" ]; then
            echo "$PORT"
            return
        fi

        PORT=$(jq -r '.results[] | select(.occupied_processes != null) | select(.occupied_processes[] | contains("zwave-js-ui")) | .port' "$SERIAL_RESULT_FILE" | head -n1)
        if [ -n "$PORT" ]; then
            log "⚠️ Z-Wave 端口被 zwave-js-ui 占用: $PORT"
            echo "$PORT"
            return
        fi
    else
        log "⚠️ $SERIAL_RESULT_FILE 不存在或无有效数据，无法探测串口"
    fi
    log "❌ 未找到有效的 Z-Wave 串口，配置中止"
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"No valid Z-Wave serial port detected, restore aborted\",\"timestamp\":$(date +%s)}"
    exit 1
}

extract_backup() {
    local backup_file="$1"
    local extension="${backup_file##*.}"

    rm -rf "$TERMUX_TMP_DIR" && mkdir -p "$TERMUX_TMP_DIR"

    if [[ "$extension" == "zip" ]]; then
        log "🗜️ 解压 zip 备份文件: $backup_file"
        unzip -q "$backup_file" -d "$TERMUX_TMP_DIR"
    elif [[ "$extension" == "gz" ]]; then
        log "🗜️ 解压 tar.gz 备份文件: $backup_file"
        tar -xzf "$backup_file" -C "$TERMUX_TMP_DIR"
    else
        log "❌ 不支持的备份文件格式: $backup_file"
        exit 1
    fi

    if [ ! -d "$TERMUX_TMP_DIR/store" ]; then
        log "❌ 备份文件无效，未找到 store 目录"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"Backup invalid: store dir missing\",\"timestamp\":$(date +%s)}"
        exit 1
    fi
}

generate_default_config() {
    log "🔍 生成完整默认配置"
    SERIAL_PORT=$(probe_serial_port)
    log "✅ 串口设备: $SERIAL_PORT"

    load_mqtt_conf

    S2_UNAUTH_KEY=$(generate_random_key)
    S2_AUTH_KEY=$(generate_random_key)
    S2_ACCESS_KEY=$(generate_random_key)
    S0_LEGACY_KEY=$(generate_random_key)
    S2_LR_AUTH_KEY=$(generate_random_key)
    S2_LR_ACCESS_KEY=$(generate_random_key)

    settings_json=$(cat <<EOF
{
  "mqtt": {
    "name": "zwave-js-ui",
    "host": "$MQTT_HOST",
    "port": $MQTT_PORT,
    "qos": 1,
    "prefix": "zwave",
    "reconnectPeriod": 3000,
    "retain": true,
    "clean": true,
    "auth": true,
    "username": "$MQTT_USER",
    "password": "$MQTT_PASS"
  },
  "gateway": {
    "type": 1,
    "plugins": [],
    "authEnabled": false,
    "payloadType": 0,
    "nodeNames": true,
    "hassDiscovery": true,
    "discoveryPrefix": "homeassistant",
    "logEnabled": false,
    "logLevel": "debug",
    "logToFile": false,
    "values": [],
    "jobs": [],
    "disableChangelog": false,
    "notifyNewVersions": false,
    "versions": {}
  },
  "zwave": {
    "enabled": true,
    "port": "$SERIAL_PORT",
    "securityKeys": {
      "S2_Unauthenticated": "$S2_UNAUTH_KEY",
      "S2_Authenticated": "$S2_AUTH_KEY",
      "S2_AccessControl": "$S2_ACCESS_KEY",
      "S0_Legacy": "$S0_LEGACY_KEY"
    },
    "securityKeysLongRange": {
      "S2_Authenticated": "$S2_LR_AUTH_KEY",
      "S2_AccessControl": "$S2_LR_ACCESS_KEY"
    },
    "deviceConfigPriorityDir": "$CUSTOM_CFG_DIR",
    "logEnabled": true,
    "logToFile": true,
    "maxFiles": 7,
    "serverEnabled": true,
    "serverPort": 3000
  },
  "backup": {
    "storeBackup": false,
    "storeCron": "0 0 * * *",
    "storeKeep": 7,
    "nvmBackup": false,
    "nvmBackupOnEvent": false,
    "nvmCron": "0 0 * * *",
    "nvmKeep": 7
  },
  "zniffer": {
    "enabled": false,
    "port": "",
    "logEnabled": true,
    "logToFile": true,
    "maxFiles": 7,
    "convertRSSI": false
  },
  "ui": {
    "darkMode": false,
    "navTabs": false,
    "compactMode": false,
    "streamerMode": false
  }
}
EOF
)

    proot-distro login "$PROOT_DISTRO" -- bash -c "\
    mkdir -p '$ZUI_DATA_DIR' '$CUSTOM_CFG_DIR' && \
    echo '$settings_json' > '$ZUI_CONFIG_FILE'"

    log "✅ 完整配置已写入: $ZUI_CONFIG_FILE"
}

log "🚀 执行还原流程"
load_mqtt_conf
mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"running\",\"timestamp\":$(date +%s)}"

if [ -n "$CUSTOM_BACKUP_FILE" ] && [ -f "$CUSTOM_BACKUP_FILE" ]; then
    log "📦 还原自用户指定文件: $CUSTOM_BACKUP_FILE"
    extract_backup "$CUSTOM_BACKUP_FILE"
    proot-distro login "$PROOT_DISTRO" -- bash -c "cp -r '$TERMUX_TMP_DIR/store' '$ZUI_DATA_DIR'"
elif LATEST_BACKUP=$(ls -1t "$BACKUP_DIR"/*.{tar.gz,zip} 2>/dev/null | head -n1); then
    log "📦 还原自最新备份: $LATEST_BACKUP"
    extract_backup "$LATEST_BACKUP"
    proot-distro login "$PROOT_DISTRO" -- bash -c "cp -r '$TERMUX_TMP_DIR/store' '$ZUI_DATA_DIR'"
elif is_service_running; then
    log "✅ zwave-js-ui 已在运行，跳过配置生成"
else
    log "⚠️ 无备份，执行配置生成"
    if [ -f "$BASE_DIR/detect_serial_adapters.py" ]; then
        log "🔍 执行串口探测"
        python3 "$BASE_DIR/detect_serial_adapters.py"
    else
        log "⚠️ 缺少探测脚本 detect_serial_adapters.py，无法探测串口"
    fi
    generate_default_config
fi

log "🔄 重启服务"
bash "$SERVICE_DIR/stop.sh" || true
sleep 2
bash "$SERVICE_DIR/start.sh"

if is_service_running; then
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"success\",\"timestamp\":$(date +%s)}"
    log "✅ 还原及配置流程完成"
else
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"zwave-js-ui failed to start\",\"timestamp\":$(date +%s)}"
    log "❌ zwave-js-ui 服务启动失败"
    exit 1
fi

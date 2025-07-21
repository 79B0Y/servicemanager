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
ZUI_DATA_DIR="/root/.pnpm-global/global/5/node_modules/zwave-js-ui/store"
ZUI_CONFIG_FILE="$ZUI_DATA_DIR/settings.json"
TERMUX_TMP_DIR="/data/data/com.termux/files/usr/tmp"
CUSTOM_BACKUP_FILE="${RESTORE_FILE:-}"
CUSTOM_CFG_DIR="/sdcard/isgbackup/zwave-js-ui/custom-device-configs"
SERIAL_RESULT_FILE="/sdcard/isgbackup/serialport/latest.json"

log() { echo "[$(date '+%F %T')] $*"; }

mqtt_report() {
    local topic="$1"
    local payload="$2"
    
    # 检查 MQTT broker 是否可用
    if ! nc -z "$MQTT_HOST" "$MQTT_PORT" 2>/dev/null; then
        echo "[$(date '+%F %T')] [MQTT-OFFLINE] $topic -> $payload" 
        return 0
    fi
    
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload" 2>/dev/null || true
    echo "[$(date '+%F %T')] [MQTT] $topic -> $payload"
}

is_service_running() {
    bash "$SERVICE_DIR/status.sh" --simple | grep -q "running"
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
    log "🔍 开始串口探测"
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"detecting_serial\",\"message\":\"probing serial ports\",\"timestamp\":$(date +%s)}"
    
    if [ -f "$SERIAL_RESULT_FILE" ]; then
        log "📋 读取串口探测结果文件: $SERIAL_RESULT_FILE"
        
        PORT=$(jq -r '.results[] | select(.type=="zwave") | .port' "$SERIAL_RESULT_FILE" | head -n1)
        if [ -n "$PORT" ] && [ "$PORT" != "null" ]; then
            log "✅ 发现 Z-Wave 控制器: $PORT"
            mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"serial_detected\",\"serial_port\":\"$PORT\",\"detection_method\":\"file\",\"timestamp\":$(date +%s)}"
            echo "$PORT"
            return
        fi

        PORT=$(jq -r '.results[] | select(.occupied_processes != null) | select(.occupied_processes[] | contains("zwave-js-ui")) | .port' "$SERIAL_RESULT_FILE" | head -n1)
        if [ -n "$PORT" ] && [ "$PORT" != "null" ]; then
            log "⚠️ Z-Wave 端口被 zwave-js-ui 占用: $PORT"
            mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"serial_occupied\",\"serial_port\":\"$PORT\",\"occupied_by\":\"zwave-js-ui\",\"timestamp\":$(date +%s)}"
            echo "$PORT"
            return
        fi
        
        log "⚠️ 串口探测文件存在但未找到 Z-Wave 设备"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"serial_not_found\",\"message\":\"no zwave devices in detection results\",\"timestamp\":$(date +%s)}"
    else
        log "⚠️ $SERIAL_RESULT_FILE 不存在或无有效数据，无法探测串口"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"serial_file_missing\",\"message\":\"serial detection file not found\",\"file\":\"$SERIAL_RESULT_FILE\",\"timestamp\":$(date +%s)}"
    fi
    
    log "❌ 未找到有效的 Z-Wave 串口，配置中止"
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"No valid Z-Wave serial port detected, restore aborted\",\"timestamp\":$(date +%s)}"
    exit 1
}

extract_backup() {
    local backup_file="$1"
    local extension="${backup_file##*.}"
    local file_size=$(du -k "$backup_file" | awk '{print $1}')

    log "📦 开始解压备份文件: $(basename "$backup_file") (${file_size}KB)"
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"extracting_backup\",\"file\":\"$(basename "$backup_file")\",\"size_kb\":$file_size,\"format\":\"$extension\",\"timestamp\":$(date +%s)}"

    rm -rf "$TERMUX_TMP_DIR" && mkdir -p "$TERMUX_TMP_DIR"

    if [[ "$extension" == "zip" ]]; then
        log "🗜️ 解压 zip 备份文件: $backup_file"
        if ! unzip -q "$backup_file" -d "$TERMUX_TMP_DIR"; then
            log "❌ ZIP 文件解压失败"
            mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"ZIP extraction failed\",\"file\":\"$(basename "$backup_file")\",\"timestamp\":$(date +%s)}"
            exit 1
        fi
    elif [[ "$extension" == "gz" ]]; then
        log "🗜️ 解压 tar.gz 备份文件: $backup_file"
        if ! tar -xzf "$backup_file" -C "$TERMUX_TMP_DIR"; then
            log "❌ TAR.GZ 文件解压失败"
            mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"TAR.GZ extraction failed\",\"file\":\"$(basename "$backup_file")\",\"timestamp\":$(date +%s)}"
            exit 1
        fi
    else
        log "❌ 不支持的备份文件格式: $backup_file"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"Unsupported backup format\",\"file\":\"$(basename "$backup_file")\",\"format\":\"$extension\",\"timestamp\":$(date +%s)}"
        exit 1
    fi

    if [ ! -d "$TERMUX_TMP_DIR/store" ]; then
        log "❌ 备份文件无效，未找到 store 目录"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"Backup invalid: store dir missing\",\"file\":\"$(basename "$backup_file")\",\"timestamp\":$(date +%s)}"
        exit 1
    fi
    
    # 统计备份内容
    local config_files=$(find "$TERMUX_TMP_DIR/store" -name "*.json" | wc -l)
    local total_files=$(find "$TERMUX_TMP_DIR/store" -type f | wc -l)
    
    log "✅ 备份解压成功: $total_files 个文件，包含 $config_files 个配置文件"
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"backup_extracted\",\"file\":\"$(basename "$backup_file")\",\"total_files\":$total_files,\"config_files\":$config_files,\"timestamp\":$(date +%s)}"
}

generate_default_config() {
    log "🔍 生成完整默认配置"
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"generating_config\",\"message\":\"creating default configuration\",\"timestamp\":$(date +%s)}"
    
    SERIAL_PORT=$(probe_serial_port)
    log "✅ 串口设备: $SERIAL_PORT"

    load_mqtt_conf

    log "🔐 生成安全密钥"
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"generating_keys\",\"message\":\"generating security keys\",\"serial_port\":\"$SERIAL_PORT\",\"timestamp\":$(date +%s)}"
    
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

    log "📝 写入配置文件"
    if proot-distro login "$PROOT_DISTRO" -- bash -c "mkdir -p '$ZUI_DATA_DIR' '$CUSTOM_CFG_DIR' && echo '$settings_json' > '$ZUI_CONFIG_FILE'"; then
        log "✅ 完整配置已写入: $ZUI_CONFIG_FILE"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"config_generated\",\"message\":\"default configuration created successfully\",\"serial_port\":\"$SERIAL_PORT\",\"mqtt_host\":\"$MQTT_HOST\",\"mqtt_port\":$MQTT_PORT,\"hass_discovery\":true,\"timestamp\":$(date +%s)}"
    else
        log "❌ 配置文件写入失败"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"failed to write configuration file\",\"timestamp\":$(date +%s)}"
        exit 1
    fi
}

log "🚀 执行还原流程"
START_TIME=$(date +%s)
load_mqtt_conf
mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"started\",\"message\":\"restore process initiated\",\"timestamp\":$START_TIME}"

if [ -n "$CUSTOM_BACKUP_FILE" ] && [ -f "$CUSTOM_BACKUP_FILE" ]; then
    log "📦 还原自用户指定文件: $CUSTOM_BACKUP_FILE"
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"user_backup\",\"message\":\"restoring from user specified file\",\"file\":\"$(basename "$CUSTOM_BACKUP_FILE")\",\"timestamp\":$(date +%s)}"
    extract_backup "$CUSTOM_BACKUP_FILE"
    log "🔄 停止服务进行还原"
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"stopping_service\",\"message\":\"stopping service for restore\",\"timestamp\":$(date +%s)}"
    bash "$SERVICE_DIR/stop.sh" || true
    sleep 10
    log "📂 清理旧数据并还原备份"
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"restoring_data\",\"message\":\"copying backup data to target directory\",\"timestamp\":$(date +%s)}"
    proot-distro login "$PROOT_DISTRO" -- bash -c "rm -rf '$ZUI_DATA_DIR' && mkdir -p '$(dirname $ZUI_DATA_DIR)' && cp -r '$TERMUX_TMP_DIR/store' '$ZUI_DATA_DIR'"
    RESTORE_METHOD="user_backup"
elif LATEST_BACKUP=$(ls -1t "$BACKUP_DIR"/*.{tar.gz,zip} 2>/dev/null | head -n1); then
    log "📦 还原自最新备份: $LATEST_BACKUP"
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"latest_backup\",\"message\":\"restoring from latest backup\",\"file\":\"$(basename "$LATEST_BACKUP")\",\"timestamp\":$(date +%s)}"
    extract_backup "$LATEST_BACKUP"
    log "🔄 停止服务进行还原"
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"stopping_service\",\"message\":\"stopping service for restore\",\"timestamp\":$(date +%s)}"
    bash "$SERVICE_DIR/stop.sh" || true
    sleep 10
    log "📂 清理旧数据并还原备份"
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"restoring_data\",\"message\":\"copying backup data to target directory\",\"timestamp\":$(date +%s)}"
    proot-distro login "$PROOT_DISTRO" -- bash -c "rm -rf '$ZUI_DATA_DIR' && mkdir -p '$(dirname $ZUI_DATA_DIR)' && cp -r '$TERMUX_TMP_DIR/store' '$ZUI_DATA_DIR'"
    RESTORE_METHOD="latest_backup"
elif is_service_running; then
    log "✅ zwave-js-ui 已在运行，跳过配置生成"
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"skipped\",\"message\":\"service already running, no backup files found, skipping restore\",\"timestamp\":$(date +%s)}"
    exit 0
else
    log "⚠️ 无备份，执行配置生成"
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"no_backup\",\"message\":\"no backup files found, generating default configuration\",\"timestamp\":$(date +%s)}"
    if [ -f "$BASE_DIR/detect_serial_adapters.py" ]; then
        log "🔍 执行串口探测"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"detecting_serial\",\"message\":\"running serial port detection script\",\"timestamp\":$(date +%s)}"
        python3 "$BASE_DIR/detect_serial_adapters.py"
    else
        log "⚠️ 缺少探测脚本 detect_serial_adapters.py，无法探测串口"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"script_missing\",\"message\":\"detect_serial_adapters.py not found, manual configuration required\",\"timestamp\":$(date +%s)}"
    fi
    generate_default_config
    RESTORE_METHOD="default_config"
fi

log "🔄 重启服务"
mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"restarting\",\"message\":\"restarting zwave-js-ui service\",\"timestamp\":$(date +%s)}"
bash "$SERVICE_DIR/stop.sh" || true
sleep 10
bash "$SERVICE_DIR/start.sh"

# 等待服务启动
log "⏳ 等待服务启动"
mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"waiting_startup\",\"message\":\"waiting for service to start\",\"timestamp\":$(date +%s)}"
MAX_WAIT=120
WAIT_TIME=0
while [ $WAIT_TIME -lt $MAX_WAIT ]; do
    if is_service_running; then
        break
    fi
    sleep 5
    WAIT_TIME=$((WAIT_TIME + 5))
done

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

if is_service_running; then
    log "✅ 还原及配置流程完成"
    
    # 获取服务详细信息用于上报
    ZUI_PID=$(ps aux | grep zwave-js-ui | grep -v grep | awk '{print $2}' | head -n1 || echo "unknown")
    HTTP_CHECK=$(timeout 5 nc -z 127.0.0.1 8091 && echo "online" || echo "starting")
    
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"success\",\"method\":\"$RESTORE_METHOD\",\"duration\":$DURATION,\"startup_time\":$WAIT_TIME,\"pid\":\"$ZUI_PID\",\"http_status\":\"$HTTP_CHECK\",\"port\":8091,\"timestamp\":$END_TIME}"
    log "📊 还原统计: 方法=$RESTORE_METHOD, 耗时=${DURATION}s, 启动时间=${WAIT_TIME}s"
else
    log "❌ zwave-js-ui 服务启动失败"
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"zwave-js-ui failed to start after restore\",\"method\":\"$RESTORE_METHOD\",\"duration\":$DURATION,\"wait_time\":$WAIT_TIME,\"timestamp\":$END_TIME}"
    exit 1
fi

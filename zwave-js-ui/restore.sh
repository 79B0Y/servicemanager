#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Z-Wave JS UI 还原脚本（增强版 with 完整配置 & 支持 zip 备份）
# 版本: v2.0.0 - 增强版 + 强制配置模式 + Python JSON 解析
# 功能: 还原备份文件或生成默认配置
# 
# 用法:
#   bash restore.sh              # 自动选择备份文件或生成默认配置
#   bash restore.sh --config     # 强制生成默认配置，跳过备份文件检查
#   bash restore.sh -c           # 同上，短参数形式
#   bash restore.sh --help       # 显示帮助信息
#   RESTORE_FILE=xxx bash restore.sh  # 使用指定的备份文件
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# 路径和变量定义
# -----------------------------------------------------------------------------
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

# 日志和状态文件
LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/restore.log"
DISABLED_FLAG="$SERVICE_DIR/.disabled"

# 网络配置
ZUI_PORT="8091"

# 脚本运行模式
FORCE_CONFIG_MODE=false

# -----------------------------------------------------------------------------
# 显示帮助信息
# -----------------------------------------------------------------------------
show_usage() {
    cat << EOF
Z-Wave JS UI 还原脚本 v2.0.0

用法:
    bash restore.sh [选项]

选项:
    --config, -c    强制生成默认配置（跳过备份文件检查）
    --help, -h      显示此帮助信息

环境变量:
    RESTORE_FILE    指定要还原的备份文件路径

示例:
    bash restore.sh                    # 自动选择最新备份或生成默认配置
    bash restore.sh --config           # 强制生成默认配置
    RESTORE_FILE=/path/to/backup.tar.gz bash restore.sh  # 使用指定备份文件

说明:
    1. 如果存在备份文件且未使用 --config 参数，将自动还原最新备份
    2. 如果不存在备份文件或使用 --config 参数，将生成默认配置
    3. 生成默认配置需要先运行串口探测脚本来识别 Z-Wave 控制器
    4. 支持 .tar.gz 和 .zip 格式的备份文件

EOF
}

# -----------------------------------------------------------------------------
# 辅助函数
# -----------------------------------------------------------------------------
ensure_directories() {
    mkdir -p "$LOG_DIR"
    mkdir -p "$BACKUP_DIR"
    mkdir -p "$CUSTOM_CFG_DIR"
    mkdir -p "$(dirname "$SERIAL_RESULT_FILE")"
    mkdir -p "$TERMUX_TMP_DIR"
    
    # 确保备份目录下的历史记录文件可以被创建
    touch "$BACKUP_DIR/.install_history" 2>/dev/null || true
    touch "$BACKUP_DIR/.update_history" 2>/dev/null || true
    
    # 确保容器内目录存在
    proot-distro login "$PROOT_DISTRO" -- bash -c "mkdir -p '$ZUI_DATA_DIR' '$CUSTOM_CFG_DIR'" 2>/dev/null || true
}

log() { 
    echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"
}

load_mqtt_conf() {
    if [ -f "$CONFIG_FILE" ]; then
        # 使用更可靠的方式解析YAML配置
        MQTT_HOST=$(grep -A 10 '^mqtt:' "$CONFIG_FILE" | grep 'host:' | awk '{print $2}' | tr -d '"' | head -n1)
        MQTT_PORT=$(grep -A 10 '^mqtt:' "$CONFIG_FILE" | grep 'port:' | awk '{print $2}' | tr -d '"' | head -n1)
        MQTT_USER=$(grep -A 10 '^mqtt:' "$CONFIG_FILE" | grep 'username:' | awk '{print $2}' | tr -d '"' | head -n1)
        MQTT_PASS=$(grep -A 10 '^mqtt:' "$CONFIG_FILE" | grep 'password:' | awk '{print $2}' | tr -d '"' | head -n1)
        
        # 设置默认值
        MQTT_HOST="${MQTT_HOST:-127.0.0.1}"
        MQTT_PORT="${MQTT_PORT:-1883}"
        MQTT_USER="${MQTT_USER:-admin}"
        MQTT_PASS="${MQTT_PASS:-admin}"
    else
        MQTT_HOST="127.0.0.1"
        MQTT_PORT="1883"
        MQTT_USER="admin"
        MQTT_PASS="admin"
        log "⚠️ 未找到配置文件，使用默认 MQTT 配置"
    fi
    log "✅ MQTT配置: host=$MQTT_HOST, port=$MQTT_PORT, username=$MQTT_USER"
}

mqtt_report() {
    local topic="$1"
    local payload="$2"
    
    # 检查 MQTT broker 是否可用
    if ! nc -z "$MQTT_HOST" "$MQTT_PORT" 2>/dev/null; then
        echo "[$(date '+%F %T')] [MQTT-OFFLINE] $topic -> $payload" >> "$LOG_FILE"
        return 0
    fi
    
    if command -v mosquitto_pub >/dev/null 2>&1; then
        mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload" 2>/dev/null || true
    fi
    echo "[$(date '+%F %T')] [MQTT] $topic -> $payload" >> "$LOG_FILE"
}

is_service_running() {
    bash "$SERVICE_DIR/status.sh" --quiet 2>/dev/null
}

generate_random_key() {
    openssl rand -hex 16 2>/dev/null || date +%s | md5sum | cut -d' ' -f1
}

# -----------------------------------------------------------------------------
# 增强的串口探测函数 - 使用 Python JSON 解析
# -----------------------------------------------------------------------------
probe_serial_port() {
    log "🔍 开始串口探测"
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"detecting_serial\",\"message\":\"probing serial ports\",\"timestamp\":$(date +%s)}"
    
    if [ ! -f "$SERIAL_RESULT_FILE" ]; then
        log "⚠️ $SERIAL_RESULT_FILE 不存在，无法探测串口"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"serial_file_missing\",\"message\":\"serial detection file not found\",\"file\":\"$SERIAL_RESULT_FILE\",\"timestamp\":$(date +%s)}"
        return 1
    fi
    
    log "📋 读取串口探测结果文件: $SERIAL_RESULT_FILE"
    
    # 使用 Python 脚本进行健壮的 JSON 解析
    local zwave_info=$(python3 -c "
import json
import sys

try:
    with open('$SERIAL_RESULT_FILE', 'r') as f:
        data = json.load(f)
    
    # 处理新格式的results数组
    if 'results' in data and isinstance(data['results'], list):
        ports = data['results']
    # 处理旧格式的ports数组  
    elif 'ports' in data and isinstance(data['ports'], list):
        ports = data['ports']
    else:
        ports = []
    
    # 查找 Z-Wave 设备
    for port in ports:
        if port.get('type') == 'zwave' and not port.get('busy', False):
            print(f\"{port['port']}|available|file\")
            sys.exit(0)
    
    # 查找被 zwave-js-ui 占用的端口
    for port in ports:
        occupied_processes = port.get('occupied_processes', {})
        if isinstance(occupied_processes, dict):
            for pid, cmdline in occupied_processes.items():
                if 'zwave-js-ui' in str(cmdline):
                    print(f\"{port['port']}|occupied|process\")
                    sys.exit(0)
        elif isinstance(occupied_processes, list):
            for process in occupied_processes:
                if 'zwave-js-ui' in str(process):
                    print(f\"{port['port']}|occupied|process\")
                    sys.exit(0)
    
    # 查找任何类型的 Z-Wave 设备（包括被其他进程占用的）
    for port in ports:
        if port.get('type') == 'zwave':
            occupied = port.get('occupied_processes', {})
            status = 'busy' if occupied else 'unknown'
            print(f\"{port['port']}|{status}|fallback\")
            sys.exit(0)
    
    print('NO_ZWAVE_FOUND')
    
except json.JSONDecodeError as e:
    print(f'JSON_PARSE_ERROR: {e}')
    sys.exit(1)
except Exception as e:
    print(f'GENERAL_ERROR: {e}')
    sys.exit(1)
" 2>/dev/null)
    
    # 解析 Python 脚本的输出
    case "$zwave_info" in
        *"|available|"*)
            local port=$(echo "$zwave_info" | cut -d'|' -f1)
            log "✅ 发现可用的 Z-Wave 控制器: $port"
            mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"serial_detected\",\"serial_port\":\"$port\",\"detection_method\":\"file\",\"port_status\":\"available\",\"timestamp\":$(date +%s)}"
            echo "$port"
            return 0
            ;;
        *"|occupied|"*)
            local port=$(echo "$zwave_info" | cut -d'|' -f1)
            log "⚠️ Z-Wave 端口被 zwave-js-ui 占用: $port"
            mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"serial_occupied\",\"serial_port\":\"$port\",\"occupied_by\":\"zwave-js-ui\",\"timestamp\":$(date +%s)}"
            echo "$port"
            return 0
            ;;
        *"|busy|"*|*"|unknown|"*)
            local port=$(echo "$zwave_info" | cut -d'|' -f1)
            local status=$(echo "$zwave_info" | cut -d'|' -f2)
            log "⚠️ 发现 Z-Wave 设备但状态为 $status: $port"
            mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"serial_detected\",\"serial_port\":\"$port\",\"port_status\":\"$status\",\"timestamp\":$(date +%s)}"
            echo "$port"
            return 0
            ;;
        "NO_ZWAVE_FOUND")
            log "❌ 未找到 Z-Wave 设备"
            mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"serial_not_found\",\"message\":\"no zwave devices in detection results\",\"timestamp\":$(date +%s)}"
            return 1
            ;;
        JSON_PARSE_ERROR*|GENERAL_ERROR*)
            log "❌ 解析串口检测结果时出错: $zwave_info"
            mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"error parsing serial detection results\",\"error\":\"$zwave_info\",\"timestamp\":$(date +%s)}"
            return 1
            ;;
        *)
            log "❌ 未知的串口检测结果: $zwave_info"
            mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"unknown serial detection result\",\"result\":\"$zwave_info\",\"timestamp\":$(date +%s)}"
            return 1
            ;;
    esac
}

# -----------------------------------------------------------------------------
# 增强的备份文件提取函数
# -----------------------------------------------------------------------------
extract_backup() {
    local backup_file="$1"
    local extension="${backup_file##*.}"
    local file_size=$(du -k "$backup_file" | awk '{print $1}')

    log "📦 开始解压备份文件: $(basename "$backup_file") (${file_size}KB)"
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"extracting_backup\",\"file\":\"$(basename "$backup_file")\",\"size_kb\":$file_size,\"format\":\"$extension\",\"timestamp\":$(date +%s)}"

    local temp_dir="$TERMUX_TMP_DIR/zwave_restore_$$"
    rm -rf "$temp_dir" && mkdir -p "$temp_dir"

    case "${extension,,}" in
        "zip")
            log "🗜️ 解压 ZIP 备份文件"
            if ! unzip -q "$backup_file" -d "$temp_dir"; then
                log "❌ ZIP 文件解压失败"
                mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"ZIP extraction failed\",\"file\":\"$(basename "$backup_file")\",\"timestamp\":$(date +%s)}"
                rm -rf "$temp_dir"
                return 1
            fi
            ;;
        "gz")
            log "🗜️ 解压 TAR.GZ 备份文件"
            if ! tar -xzf "$backup_file" -C "$temp_dir"; then
                log "❌ TAR.GZ 文件解压失败"
                mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"TAR.GZ extraction failed\",\"file\":\"$(basename "$backup_file")\",\"timestamp\":$(date +%s)}"
                rm -rf "$temp_dir"
                return 1
            fi
            ;;
        *)
            log "❌ 不支持的备份文件格式: $extension"
            mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"Unsupported backup format\",\"file\":\"$(basename "$backup_file")\",\"format\":\"$extension\",\"timestamp\":$(date +%s)}"
            rm -rf "$temp_dir"
            return 1
            ;;
    esac

    # 检查解压结果
    if [ ! -d "$temp_dir/store" ]; then
        log "❌ 备份文件无效，未找到 store 目录"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"Backup invalid: store dir missing\",\"file\":\"$(basename "$backup_file")\",\"timestamp\":$(date +%s)}"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # 统计备份内容
    local config_files=$(find "$temp_dir/store" -name "*.json" | wc -l)
    local total_files=$(find "$temp_dir/store" -type f | wc -l)
    
    log "✅ 备份解压成功: $total_files 个文件，包含 $config_files 个配置文件"
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"backup_extracted\",\"file\":\"$(basename "$backup_file")\",\"total_files\":$total_files,\"config_files\":$config_files,\"timestamp\":$(date +%s)}"
    
    # 将临时目录路径存储到全局变量
    EXTRACTED_TEMP_DIR="$temp_dir"
    return 0
}

# -----------------------------------------------------------------------------
# 增强的默认配置生成函数
# -----------------------------------------------------------------------------
generate_default_config() {
    log "🔍 生成完整默认配置"
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"generating_config\",\"message\":\"creating default configuration\",\"timestamp\":$(date +%s)}"
    
    # 探测串口设备
    if ! SERIAL_PORT=$(probe_serial_port); then
        log "❌ 未找到有效的 Z-Wave 串口，配置中止"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"No valid Z-Wave serial port detected, restore aborted\",\"timestamp\":$(date +%s)}"
        return 1
    fi
    
    log "✅ 使用串口设备: $SERIAL_PORT"

    # 加载 MQTT 配置
    load_mqtt_conf

    log "🔐 生成安全密钥"
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"generating_keys\",\"message\":\"generating security keys\",\"serial_port\":\"$SERIAL_PORT\",\"timestamp\":$(date +%s)}"
    
    local s2_unauth_key=$(generate_random_key)
    local s2_auth_key=$(generate_random_key)
    local s2_access_key=$(generate_random_key)
    local s0_legacy_key=$(generate_random_key)
    local s2_lr_auth_key=$(generate_random_key)
    local s2_lr_access_key=$(generate_random_key)

    # 生成完整的 Z-Wave JS UI 配置
    local settings_json=$(cat <<EOF
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
      "S2_Unauthenticated": "$s2_unauth_key",
      "S2_Authenticated": "$s2_auth_key",
      "S2_AccessControl": "$s2_access_key",
      "S0_Legacy": "$s0_legacy_key"
    },
    "securityKeysLongRange": {
      "S2_Authenticated": "$s2_lr_auth_key",
      "S2_AccessControl": "$s2_lr_access_key"
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

    log "📝 写入配置文件到容器内"
    if proot-distro login "$PROOT_DISTRO" -- bash -c "mkdir -p '$ZUI_DATA_DIR' '$CUSTOM_CFG_DIR' && echo '$settings_json' > '$ZUI_CONFIG_FILE'"; then
        log "✅ 完整配置已写入: $ZUI_CONFIG_FILE"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"config_generated\",\"message\":\"default configuration created successfully\",\"serial_port\":\"$SERIAL_PORT\",\"mqtt_host\":\"$MQTT_HOST\",\"mqtt_port\":$MQTT_PORT,\"hass_discovery\":true,\"timestamp\":$(date +%s)}"
        return 0
    else
        log "❌ 配置文件写入失败"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"failed to write configuration file\",\"timestamp\":$(date +%s)}"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# 主流程开始
# -----------------------------------------------------------------------------

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --config|-c)
            FORCE_CONFIG_MODE=true
            log "强制配置模式: 将直接生成默认配置"
            shift
            ;;
        --help|-h)
            show_usage
            exit 0
            ;;
        *)
            echo "错误: 未知参数 '$1'"
            echo "使用 --help 查看帮助信息"
            exit 1
            ;;
    esac
done

# 初始化
log "🚀 执行还原流程"
START_TIME=$(date +%s)
ensure_directories
load_mqtt_conf
mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"started\",\"message\":\"restore process initiated\",\"timestamp\":$START_TIME}"

# 检查备份文件
log "🔍 检查备份文件"
LATEST_BACKUP=""
if ls "$BACKUP_DIR"/*.tar.gz >/dev/null 2>&1; then
    LATEST_BACKUP=$(ls -1t "$BACKUP_DIR"/*.tar.gz 2>/dev/null | head -n1)
fi
log "📋 备份文件检查结果: LATEST_BACKUP=[$LATEST_BACKUP]"
log "📋 用户指定备份: CUSTOM_BACKUP_FILE=[$CUSTOM_BACKUP_FILE]"

# 确定还原方法
if [ "$FORCE_CONFIG_MODE" = true ]; then
    RESTORE_METHOD="forced_default_config"
    BACKUP_FILE=""
elif [ -n "$CUSTOM_BACKUP_FILE" ] && [ -f "$CUSTOM_BACKUP_FILE" ]; then
    RESTORE_METHOD="user_backup"
    BACKUP_FILE="$CUSTOM_BACKUP_FILE"
elif [ -n "$LATEST_BACKUP" ] && [ -f "$LATEST_BACKUP" ]; then
    RESTORE_METHOD="latest_backup"
    BACKUP_FILE="$LATEST_BACKUP"
else
    RESTORE_METHOD="default_config"
    BACKUP_FILE=""
fi

# 执行相应的还原流程
if [ -n "$BACKUP_FILE" ] && [ "$FORCE_CONFIG_MODE" = false ]; then
    # 备份文件还原流程
    if [ "$RESTORE_METHOD" = "user_backup" ]; then
        log "📦 还原自用户指定文件: $BACKUP_FILE"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"user_backup\",\"message\":\"restoring from user specified file\",\"file\":\"$(basename "$BACKUP_FILE")\",\"timestamp\":$(date +%s)}"
    else
        log "📦 还原自最新备份: $BACKUP_FILE"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"latest_backup\",\"message\":\"restoring from latest backup\",\"file\":\"$(basename "$BACKUP_FILE")\",\"timestamp\":$(date +%s)}"
    fi
    
    # 提取备份文件
    if ! extract_backup "$BACKUP_FILE"; then
        exit 1
    fi
    
    # 停止服务
    log "🔄 停止服务进行还原"
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"stopping_service\",\"message\":\"stopping service for restore\",\"timestamp\":$(date +%s)}"
    bash "$SERVICE_DIR/stop.sh" || true
    sleep 10
    
    # 还原数据
    log "📂 清理旧数据并还原备份"
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"restoring_data\",\"message\":\"copying backup data to target directory\",\"timestamp\":$(date +%s)}"
    if ! proot-distro login "$PROOT_DISTRO" -- bash -c "rm -rf '$ZUI_DATA_DIR' && mkdir -p '$(dirname $ZUI_DATA_DIR)' && cp -r '$EXTRACTED_TEMP_DIR/store' '$ZUI_DATA_DIR'"; then
        log "❌ 数据还原失败"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"data restore failed\",\"timestamp\":$(date +%s)}"
        rm -rf "$EXTRACTED_TEMP_DIR" 2>/dev/null || true
        exit 1
    fi
    
    # 清理临时目录
    rm -rf "$EXTRACTED_TEMP_DIR" 2>/dev/null || true
    
else
    # 默认配置生成流程
    if [ "$FORCE_CONFIG_MODE" = true ]; then
        log "⚠️ 强制配置模式: 执行配置生成"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"forced_config\",\"message\":\"forced configuration generation mode\",\"timestamp\":$(date +%s)}"
    else
        log "⚠️ 无备份，执行配置生成"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"no_backup\",\"message\":\"no backup files found, generating default configuration\",\"timestamp\":$(date +%s)}"
    fi
    
    # 如果检测脚本存在，运行串口检测
    if [ -f "$BASE_DIR/detect_serial_adapters.py" ]; then
        log "🔍 执行串口探测"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"detecting_serial\",\"message\":\"running serial port detection script\",\"timestamp\":$(date +%s)}"
        
        # 停止服务以释放串口
        bash "$SERVICE_DIR/stop.sh" || true
        sleep 5
        
        python3 "$BASE_DIR/detect_serial_adapters.py" || {
            log "⚠️ 串口探测脚本执行失败，但继续尝试配置生成"
        }
        
        # 等待检测完成
        sleep 3
    else
        log "⚠️ 缺少探测脚本 detect_serial_adapters.py"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"script_missing\",\"message\":\"detect_serial_adapters.py not found, manual configuration required\",\"timestamp\":$(date +%s)}"
    fi
    
    # 生成默认配置
    if ! generate_default_config; then
        exit 1
    fi
fi

# 重启服务
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

# 生成最终结果
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

if is_service_running; then
    log "✅ 还原及配置流程完成"
    
    # 获取服务详细信息用于上报
    ZUI_PID=$(ps aux | grep zwave-js-ui | grep -v grep | awk '{print $2}' | head -n1 || echo "unknown")
    HTTP_CHECK=$(timeout 5 nc -z 127.0.0.1 8091 && echo "online" || echo "starting")
    
    # 根据还原方法构建不同的成功消息
    case "$RESTORE_METHOD" in
        "user_backup"|"latest_backup")
            SIZE_KB=$(du -k "$BACKUP_FILE" | awk '{print $1}')
            mqtt_report "isg/restore/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"success\",\"method\":\"$RESTORE_METHOD\",\"file\":\"$(basename "$BACKUP_FILE")\",\"size_kb\":$SIZE_KB,\"duration\":$DURATION,\"startup_time\":$WAIT_TIME,\"pid\":\"$ZUI_PID\",\"http_status\":\"$HTTP_CHECK\",\"port\":8091,\"timestamp\":$END_TIME}"
            log "📊 备份还原统计: 文件=$(basename "$BACKUP_FILE"), 大小=${SIZE_KB}KB, 耗时=${DURATION}s, 启动时间=${WAIT_TIME}s"
            ;;
        "forced_default_config")
            mqtt_report "isg/restore/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"success\",\"method\":\"forced_default_config\",\"serial_port\":\"$SERIAL_PORT\",\"duration\":$DURATION,\"startup_time\":$WAIT_TIME,\"pid\":\"$ZUI_PID\",\"http_status\":\"$HTTP_CHECK\",\"port\":8091,\"timestamp\":$END_TIME}"
            log "📊 强制配置统计: 串口=$SERIAL_PORT, 耗时=${DURATION}s, 启动时间=${WAIT_TIME}s"
            ;;
        "default_config")
            mqtt_report "isg/restore/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"success\",\"method\":\"default_config\",\"serial_port\":\"$SERIAL_PORT\",\"duration\":$DURATION,\"startup_time\":$WAIT_TIME,\"pid\":\"$ZUI_PID\",\"http_status\":\"$HTTP_CHECK\",\"port\":8091,\"timestamp\":$END_TIME}"
            log "📊 默认配置统计: 串口=$SERIAL_PORT, 耗时=${DURATION}s, 启动时间=${WAIT_TIME}s"
            ;;
    esac
    
    log "🎉 Z-Wave JS UI 还原流程成功完成!"
else
    log "❌ Z-Wave JS UI 服务启动失败"
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"zwave-js-ui failed to start after restore\",\"method\":\"$RESTORE_METHOD\",\"duration\":$DURATION,\"wait_time\":$WAIT_TIME,\"timestamp\":$END_TIME}"
    exit 1
fi

# 清理工作
rm -rf "$TERMUX_TMP_DIR"/zwave_restore_* 2>/dev/null || true

log "🏁 还原脚本执行完成"
exit 0

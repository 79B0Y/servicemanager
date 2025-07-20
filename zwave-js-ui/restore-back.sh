#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Z-Wave JS UI 还原脚本
# 版本: v1.0.0
# 功能: 还原备份文件或生成默认配置，探测串口设备
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# 路径和变量定义
# -----------------------------------------------------------------------------
SERVICE_ID="zwave-js-ui"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"
TERMUX_TMP_DIR="/data/data/com.termux/files/usr/tmp"

CONFIG_FILE="$BASE_DIR/configuration.yaml"

LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/restore.log"
BACKUP_DIR="/sdcard/isgbackup/$SERVICE_ID"

PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
ZUI_DATA_DIR="/usr/src/app/store"
ZUI_CONFIG_FILE="$ZUI_DATA_DIR/settings.json"
ZUI_PORT="8091"

# 环境变量：用户可以指定要还原的备份文件
CUSTOM_BACKUP_FILE="${RESTORE_FILE:-}"

# -----------------------------------------------------------------------------
# 辅助函数
# -----------------------------------------------------------------------------
ensure_directories() {
    mkdir -p "$LOG_DIR"
    mkdir -p "$BACKUP_DIR"
    mkdir -p "$TERMUX_TMP_DIR"
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

get_zui_pid() {
    local port_pid=$(netstat -tnlp 2>/dev/null | grep ":$ZUI_PORT " | awk '{print $7}' | cut -d'/' -f1 | head -n1)
    
    if [ -n "$port_pid" ] && [ "$port_pid" != "-" ]; then
        local cwd=$(ls -l /proc/$port_pid/cwd 2>/dev/null | grep -o 'zwave\|node' || true)
        if [ -n "$cwd" ]; then
            echo "$port_pid"
            return 0
        fi
    fi
    return 1
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

detect_serial_ports() {
    log "探测可用的串口设备"
    
    # 使用 detect_serial_adapters.py 进行串口探测
    local detection_script="/data/data/com.termux/files/home/servicemanager/detect_serial_adapters.py"
    
    if [ -f "$detection_script" ]; then
        log "使用 detect_serial_adapters.py 进行串口探测"
        
        # 运行串口探测脚本并获取结果
        local detection_result=$(python3 "$detection_script" 2>/dev/null || echo "")
        
        if [ -n "$detection_result" ]; then
            # 解析探测结果，提取第一个可用的串口设备
            # detect_serial_adapters.py 通常输出设备路径
            local serial_port=$(echo "$detection_result" | grep -E "^/dev/" | head -n1 | tr -d '\r\n\t ')
            
            if [ -n "$serial_port" ] && [ -e "$serial_port" ]; then
                log "串口探测成功: $serial_port"
                echo "$serial_port"
                return 0
            fi
        fi
        
        log "detect_serial_adapters.py 未发现可用串口设备"
    else
        log "detect_serial_adapters.py 不存在，使用备用探测方法"
    fi
    
    # 备用探测方法：检查常见的串口设备路径
    local serial_ports=()
    
    # 常见的串口设备路径
    for port_path in /dev/ttyUSB* /dev/ttyACM* /dev/ttyS* /dev/serial/by-id/* /dev/zwave; do
        if [ -e "$port_path" ]; then
            serial_ports+=("$port_path")
        fi
    done
    
    if [ ${#serial_ports[@]} -eq 0 ]; then
        log "未发现串口设备"
        return 1
    fi
    
    log "发现串口设备: ${serial_ports[*]}"
    
    # 返回第一个找到的设备
    echo "${serial_ports[0]}"
    return 0
}

generate_default_config() {
    log "生成默认 Z-Wave JS UI 配置"
    
    # 探测串口设备
    SERIAL_PORT=$(detect_serial_ports || echo "")
    DETECTION_METHOD=""
    
    if [ -z "$SERIAL_PORT" ]; then
        log "警告: 未发现串口设备，使用默认串口路径"
        SERIAL_PORT="/dev/zwave"
        SERIAL_PORT_FOUND=false
        DETECTION_METHOD="default"
    else
        log "使用串口设备: $SERIAL_PORT"
        SERIAL_PORT_FOUND=true
        
        # 判断探测方法
        if [ -f "/data/data/com.termux/files/home/servicemanager/detect_serial_adapters.py" ]; then
            DETECTION_METHOD="script"
        else
            DETECTION_METHOD="manual"
        fi
    fi
    
    # 读取 MQTT 配置
    load_mqtt_conf
    
    # 生成随机安全密钥 (32位十六进制)
    generate_random_key() {
        openssl rand -hex 16 2>/dev/null || echo "$(date +%s)$(shuf -i 1000-9999 -n 1)" | md5sum | cut -d' ' -f1
    }
    
    S2_UNAUTH_KEY=$(generate_random_key)
    S2_AUTH_KEY=$(generate_random_key)
    S2_ACCESS_KEY=$(generate_random_key)
    S0_LEGACY_KEY=$(generate_random_key)
    S2_LR_AUTH_KEY=$(generate_random_key)
    S2_LR_ACCESS_KEY=$(generate_random_key)
    
    # 创建自定义设备配置目录
    CUSTOM_CONFIG_DIR="/sdcard/isgbackup/zwave/custom-device-configs"
    mkdir -p "$CUSTOM_CONFIG_DIR"
    
    # 生成完整的 settings.json 配置文件
    proot-distro login "$PROOT_DISTRO" -- bash -c "
        mkdir -p '$ZUI_DATA_DIR'
        cat > '$ZUI_CONFIG_FILE' << 'EOF'
{
  \"mqtt\": {
    \"name\": \"zwave-js-ui\",
    \"host\": \"$MQTT_HOST\",
    \"port\": $MQTT_PORT_CONFIG,
    \"qos\": 1,
    \"prefix\": \"zwave\",
    \"reconnectPeriod\": 3000,
    \"retain\": true,
    \"clean\": true,
    \"auth\": true,
    \"_ca\": \"\",
    \"ca\": \"\",
    \"_cert\": \"\",
    \"cert\": \"\",
    \"_key\": \"\",
    \"key\": \"\",
    \"username\": \"$MQTT_USER\",
    \"password\": \"$MQTT_PASS\"
  },
  \"gateway\": {
    \"type\": 1,
    \"plugins\": [],
    \"authEnabled\": false,
    \"payloadType\": 0,
    \"nodeNames\": true,
    \"hassDiscovery\": true,
    \"discoveryPrefix\": \"homeassistant\",
    \"logEnabled\": false,
    \"logLevel\": \"debug\",
    \"logToFile\": false,
    \"values\": [],
    \"jobs\": [],
    \"disableChangelog\": false,
    \"notifyNewVersions\": false,
    \"versions\": {
      \"app\": \"9.18.1\",
      \"driver\": \"15.8.0\",
      \"server\": \"3.1.0\"
    }
  },
  \"zwave\": {
    \"enabled\": true,
    \"port\": \"$SERIAL_PORT\",
    \"allowBootloaderOnly\": false,
    \"commandsTimeout\": 30,
    \"logLevel\": \"debug\",
    \"rf\": {
      \"txPower\": {}
    },
    \"securityKeys\": {
      \"S2_Unauthenticated\": \"$S2_UNAUTH_KEY\",
      \"S2_Authenticated\": \"$S2_AUTH_KEY\",
      \"S2_AccessControl\": \"$S2_ACCESS_KEY\",
      \"S0_Legacy\": \"$S0_LEGACY_KEY\"
    },
    \"securityKeysLongRange\": {
      \"S2_Authenticated\": \"$S2_LR_AUTH_KEY\",
      \"S2_AccessControl\": \"$S2_LR_ACCESS_KEY\"
    },
    \"deviceConfigPriorityDir\": \"$CUSTOM_CONFIG_DIR\",
    \"logEnabled\": true,
    \"logToFile\": true,
    \"maxFiles\": 7,
    \"serverEnabled\": true,
    \"serverServiceDiscoveryDisabled\": false,
    \"enableSoftReset\": true,
    \"disableOptimisticValueUpdate\": false,
    \"enableStatistics\": true,
    \"serverPort\": 3000,
    \"maxNodeEventsQueueSize\": 100,
    \"higherReportsTimeout\": false,
    \"disableControllerRecovery\": false,
    \"disableWatchdog\": false,
    \"disclaimerVersion\": 1
  },
  \"backup\": {
    \"storeBackup\": false,
    \"storeCron\": \"0 0 * * *\",
    \"storeKeep\": 7,
    \"nvmBackup\": false,
    \"nvmBackupOnEvent\": false,
    \"nvmCron\": \"0 0 * * *\",
    \"nvmKeep\": 7
  },
  \"zniffer\": {
    \"enabled\": false,
    \"port\": \"\",
    \"logEnabled\": true,
    \"logToFile\": true,
    \"maxFiles\": 7,
    \"securityKeys\": {
      \"S2_Unauthenticated\": \"$S2_UNAUTH_KEY\",
      \"S2_Authenticated\": \"$S2_AUTH_KEY\",
      \"S2_AccessControl\": \"$S2_ACCESS_KEY\",
      \"S0_Legacy\": \"$S0_LEGACY_KEY\"
    },
    \"securityKeysLongRange\": {
      \"S2_Authenticated\": \"$S2_LR_AUTH_KEY\",
      \"S2_AccessControl\": \"$S2_LR_ACCESS_KEY\"
    },
    \"convertRSSI\": false
  },
  \"ui\": {
    \"darkMode\": false,
    \"navTabs\": false,
    \"compactMode\": false,
    \"streamerMode\": false
  }
}
EOF
    "
    
    log "默认 Z-Wave JS UI 配置生成完成"
    log "配置详情:"
    log "  - 串口设备: $SERIAL_PORT (探测方法: $DETECTION_METHOD)"
    log "  - MQTT 主机: $MQTT_HOST:$MQTT_PORT_CONFIG"
    log "  - MQTT 用户: $MQTT_USER"
    log "  - Home Assistant 发现: 启用"
    log "  - 自定义设备配置目录: $CUSTOM_CONFIG_DIR"
    log "  - 安全密钥: 已生成随机密钥"
    
    # 上报串口探测结果和 MQTT 配置状态
    if [ "$SERIAL_PORT_FOUND" = true ]; then
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"restoring\",\"method\":\"default_config\",\"serial_port\":\"$SERIAL_PORT\",\"serial_detected\":true,\"detection_method\":\"$DETECTION_METHOD\",\"mqtt_host\":\"$MQTT_HOST\",\"mqtt_user\":\"$MQTT_USER\",\"timestamp\":$(date +%s)}"
    else
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"restoring\",\"method\":\"default_config\",\"serial_port\":\"$SERIAL_PORT\",\"serial_detected\":false,\"detection_method\":\"$DETECTION_METHOD\",\"mqtt_host\":\"$MQTT_HOST\",\"mqtt_user\":\"$MQTT_USER\",\"message\":\"no serial ports detected by detect_serial_adapters.py\",\"timestamp\":$(date +%s)}"
    fi
}

START_TIME=$(date +%s)

# -----------------------------------------------------------------------------
# 主还原流程
# -----------------------------------------------------------------------------
ensure_directories

# 确保数据目录存在
proot-distro login "$PROOT_DISTRO" -- mkdir -p "$ZUI_DATA_DIR"

# -----------------------------------------------------------------------------
# 确定还原文件
# -----------------------------------------------------------------------------
if [ -n "$CUSTOM_BACKUP_FILE" ]; then
    RESTORE_FILE="$CUSTOM_BACKUP_FILE"
    if [ -f "$RESTORE_FILE" ]; then
        log "使用用户指定文件: $RESTORE_FILE"
        METHOD="user_specified"
    else
        log "用户指定文件不存在: $RESTORE_FILE"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"user specified file not found\",\"file\":\"$RESTORE_FILE\",\"timestamp\":$(date +%s)}"
        exit 1
    fi
else
    RESTORE_FILE=$(ls -1t "$BACKUP_DIR"/zwave-js-ui_backup_*.tar.gz 2>/dev/null | head -n1 || true)
    if [ -n "$RESTORE_FILE" ] && [ -f "$RESTORE_FILE" ]; then
        log "使用最新备份: $RESTORE_FILE"
        METHOD="latest_backup"
    else
        RESTORE_FILE=""
        METHOD="default_config"
    fi
fi

# -----------------------------------------------------------------------------
# 处理无备份文件的情况 - 生成默认配置
# -----------------------------------------------------------------------------
if [ -z "$RESTORE_FILE" ]; then
    log "未找到备份文件，将生成默认配置"
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"restoring\",\"method\":\"default_config\",\"timestamp\":$(date +%s)}"
    
    # 停止服务
    if get_zui_pid > /dev/null 2>&1; then
        log "停止 Z-Wave JS UI 服务"
        bash "$SERVICE_DIR/stop.sh" || true
        sleep 3
    fi
    
    # 生成默认配置
    generate_default_config
    
    # 启动服务验证配置
    log "启动服务验证配置"
    bash "$SERVICE_DIR/start.sh"
    
    # 等待服务启动
    MAX_WAIT=120
    INTERVAL=5
    WAITED=0
    log "等待 Z-Wave JS UI 服务启动"
    
    while [ "$WAITED" -lt "$MAX_WAIT" ]; do
        if bash "$SERVICE_DIR/status.sh" --quiet; then
            log "服务启动成功，耗时 ${WAITED}s"
            break
        fi
        sleep "$INTERVAL"
        WAITED=$((WAITED + INTERVAL))
    done
    
    if bash "$SERVICE_DIR/status.sh" --quiet; then
        END_TIME=$(date +%s)
        DURATION=$((END_TIME - START_TIME))
        
        # 获取串口探测结果
        SERIAL_PORT=$(detect_serial_ports || echo "/dev/zwave")
        SERIAL_DETECTED=$([ -e "$SERIAL_PORT" ] && echo "true" || echo "false")
        
        # 读取 MQTT 配置用于上报
        load_mqtt_conf
        
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"success\",\"method\":\"default_config\",\"duration\":$DURATION,\"startup_time\":$WAITED,\"serial_port\":\"$SERIAL_PORT\",\"serial_detected\":$SERIAL_DETECTED,\"mqtt_host\":\"$MQTT_HOST\",\"mqtt_user\":\"$MQTT_USER\",\"config_features\":[\"homeassistant_discovery\",\"security_keys\",\"custom_device_configs\"],\"timestamp\":$END_TIME}"
        log "默认配置生成并启动成功，总耗时 ${DURATION}s"
        
        if [ "$SERIAL_DETECTED" = "false" ]; then
            log "警告: 未检测到串口设备，可能需要手动配置 Z-Wave 控制器"
        fi
    else
        log "服务启动失败，超时 ${MAX_WAIT}s"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"service failed to start after config generation\",\"method\":\"default_config\",\"timestamp\":$(date +%s)}"
        exit 1
    fi
    
    exit 0
fi

# -----------------------------------------------------------------------------
# 处理备份文件还原
# -----------------------------------------------------------------------------
log "开始从备份文件还原: $RESTORE_FILE"

# 检查文件格式并处理zip转换
BASENAME=$(basename -- "$RESTORE_FILE")
EXT="${BASENAME##*.}"
EXT_LOWER=$(echo "$EXT" | tr '[:upper:]' '[:lower:]')
FINAL_RESTORE_FILE="$RESTORE_FILE"
CONVERTED_FROM_ZIP=false

if [[ "$EXT_LOWER" == "zip" ]]; then
    log "检测到 zip 文件，转换为 tar.gz"
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"restoring\",\"method\":\"$METHOD\",\"file\":\"$RESTORE_FILE\",\"converting_zip\":true}"
    
    TEMP_DIR="$TERMUX_TMP_DIR/zwave-js-ui_zip_convert_$$"
    CONVERTED_FILE="$BACKUP_DIR/zwave-js-ui_converted_$(date +%Y%m%d-%H%M%S).tar.gz"
    
    rm -rf "$TEMP_DIR" && mkdir -p "$TEMP_DIR"
    if ! unzip -q "$RESTORE_FILE" -d "$TEMP_DIR"; then
        log "解压 zip 文件失败"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"failed to extract zip file\",\"timestamp\":$(date +%s)}"
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    
    # 查找解压后的数据目录
    DATA_DIR_IN_ZIP=""
    if [ -d "$TEMP_DIR/store" ]; then
        DATA_DIR_IN_ZIP="store"
    elif [ -f "$TEMP_DIR/settings.json" ]; then
        # 如果直接是配置文件，创建store目录结构
        mkdir -p "$TEMP_DIR/store"
        mv "$TEMP_DIR"/*.json "$TEMP_DIR/store/" 2>/dev/null || true
        DATA_DIR_IN_ZIP="store"
    else
        # 查找包含settings.json的目录
        DATA_DIR_IN_ZIP=$(find "$TEMP_DIR" -name "settings.json" -type f | head -n1 | xargs dirname | sed "s|$TEMP_DIR/||" || true)
    fi
    
    if [ -z "$DATA_DIR_IN_ZIP" ]; then
        log "zip 文件中未找到有效的 Z-Wave JS UI 数据"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"invalid zip structure\",\"timestamp\":$(date +%s)}"
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    
    # 创建标准的tar.gz格式
    if tar -czf "$CONVERTED_FILE" -C "$TEMP_DIR" "$DATA_DIR_IN_ZIP"; then
        FINAL_RESTORE_FILE="$CONVERTED_FILE"
        CONVERTED_FROM_ZIP=true
        log "zip 转换为: $(basename "$CONVERTED_FILE")"
    else
        log "从 zip 创建 tar.gz 失败"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"failed to create tar.gz from zip\",\"timestamp\":$(date +%s)}"
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    
    rm -rf "$TEMP_DIR"
elif [[ "$BASENAME" != *.tar.gz ]]; then
    log "不支持的文件格式: $EXT"
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"unsupported file format. only .tar.gz and .zip are supported\",\"file\":\"$BASENAME\",\"timestamp\":$(date +%s)}"
    exit 1
fi

# 上报开始还原
mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"restoring\",\"method\":\"$METHOD\",\"file\":\"$(basename "$FINAL_RESTORE_FILE")\"}"

# -----------------------------------------------------------------------------
# 停止服务
# -----------------------------------------------------------------------------
if get_zui_pid > /dev/null 2>&1; then
    log "停止 Z-Wave JS UI 服务"
    bash "$SERVICE_DIR/stop.sh" || true
    sleep 3
fi

# -----------------------------------------------------------------------------
# 执行还原
# -----------------------------------------------------------------------------
TEMP_RESTORE_DIR="$TERMUX_TMP_DIR/zwave-js-ui_restore_$$"
rm -rf "$TEMP_RESTORE_DIR" && mkdir -p "$TEMP_RESTORE_DIR"

if tar -xzf "$FINAL_RESTORE_FILE" -C "$TEMP_RESTORE_DIR"; then
    log "备份文件解压成功"
    
    # 查找数据目录
    DATA_DIR_IN_BACKUP=""
    if [ -d "$TEMP_RESTORE_DIR/store" ]; then
        DATA_DIR_IN_BACKUP="store"
    elif [ -f "$TEMP_RESTORE_DIR/zwave-js-ui-data.tar.gz" ]; then
        # 如果是包含数据压缩包的备份，先解压
        tar -xzf "$TEMP_RESTORE_DIR/zwave-js-ui-data.tar.gz" -C "$TEMP_RESTORE_DIR"
        if [ -d "$TEMP_RESTORE_DIR/store" ]; then
            DATA_DIR_IN_BACKUP="store"
        fi
    else
        # 查找包含 settings.json 的目录
        SETTINGS_PATH=$(find "$TEMP_RESTORE_DIR" -name "settings.json" -type f | head -n1)
        if [ -n "$SETTINGS_PATH" ]; then
            DATA_DIR_IN_BACKUP=$(dirname "$SETTINGS_PATH" | sed "s|$TEMP_RESTORE_DIR/||")
        fi
    fi
    
    if [ -n "$DATA_DIR_IN_BACKUP" ]; then
        # 还原数据文件
        log "还原数据文件"
        proot-distro login "$PROOT_DISTRO" -- bash -c "
            rm -rf '$ZUI_DATA_DIR'
            mkdir -p '$(dirname $ZUI_DATA_DIR)'
        "
        
        # 复制数据到容器内
        cp -r "$TEMP_RESTORE_DIR/$DATA_DIR_IN_BACKUP" "/tmp/zwave-js-ui-restore"
        proot-distro login "$PROOT_DISTRO" -- bash -c "
            mv '/tmp/zwave-js-ui-restore' '$ZUI_DATA_DIR'
        "
    else
        log "备份中未找到有效的数据目录，生成默认配置"
        generate_default_config
    fi
    
    # 清理临时目录
    rm -rf "$TEMP_RESTORE_DIR"
    
    log "还原完成，重启服务"
    bash "$SERVICE_DIR/start.sh"
    
    # 等待服务启动
    MAX_WAIT=120
    INTERVAL=5
    WAITED=0
    log "等待服务启动完成"
    
    while [ "$WAITED" -lt "$MAX_WAIT" ]; do
        if bash "$SERVICE_DIR/status.sh" --quiet; then
            log "服务启动成功，耗时 ${WAITED}s"
            break
        fi
        sleep "$INTERVAL"
        WAITED=$((WAITED + INTERVAL))
    done
    
    # 验证服务状态
    if bash "$SERVICE_DIR/status.sh" --quiet; then
        END_TIME=$(date +%s)
        DURATION=$((END_TIME - START_TIME))
        SIZE_KB=$(du -k "$FINAL_RESTORE_FILE" | awk '{print $1}')
        
        # 构建成功消息
        if [ "$CONVERTED_FROM_ZIP" = true ]; then
            mqtt_report "isg/restore/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"success\",\"method\":\"$METHOD\",\"original_file\":\"$(basename "$RESTORE_FILE")\",\"restore_file\":\"$(basename "$FINAL_RESTORE_FILE")\",\"size_kb\":$SIZE_KB,\"duration\":$DURATION,\"converted_from_zip\":true,\"timestamp\":$END_TIME}"
            log "还原 + 重启完成: $(basename "$FINAL_RESTORE_FILE") ($SIZE_KB KB, ${DURATION}s)"
            log "转换自: $(basename "$RESTORE_FILE")"
        else
            mqtt_report "isg/restore/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"success\",\"method\":\"$METHOD\",\"file\":\"$(basename "$FINAL_RESTORE_FILE")\",\"size_kb\":$SIZE_KB,\"duration\":$DURATION,\"timestamp\":$END_TIME}"
            log "还原 + 重启完成: $(basename "$FINAL_RESTORE_FILE") ($SIZE_KB KB, ${DURATION}s)"
        fi
        
        log "✅ 还原成功"
        
    else
        log "还原成功但服务启动失败，耗时 ${MAX_WAIT}s"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"service failed to start after restore\",\"method\":\"$METHOD\",\"timestamp\":$(date +%s)}"
        exit 1
    fi
else
    log "备份文件解压失败"
    rm -rf "$TEMP_RESTORE_DIR"
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"backup file extraction failed\",\"timestamp\":$(date +%s)}"
    exit 1
fi

exit 0

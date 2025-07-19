#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Z-Wave JS UI 还原脚本
# 版本: v1.0.0
# 功能: 还原备份文件或生成默认配置
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# 路径和变量定义
# -----------------------------------------------------------------------------
SERVICE_ID="zwave-js-ui"
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"
TERMUX_TMP_DIR="/data/data/com.termux/files/usr/tmp"

CONFIG_FILE="$BASE_DIR/configuration.yaml"
DETECT_SCRIPT="$BASE_DIR/detect_serial_adapters.py"
ZWAVE_INSTALL_DIR="/root/.local/share/pnpm/global/5/node_modules/zwave-js-ui"
ZWAVE_STORE_DIR="$ZWAVE_INSTALL_DIR/store"
ZWAVE_CONFIG_FILE="$ZWAVE_STORE_DIR/settings.json"

LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/restore.log"
BACKUP_DIR="/sdcard/isgbackup/$SERVICE_ID"
SERIAL_RESULT_FILE="/sdcard/isgbackup/serialport/latest.json"
DEFAULT_CONFIG_FILE="$BACKUP_DIR/settings_default.json"

ZWAVE_PORT="8091"

# 环境变量：用户可以指定要还原的备份文件
CUSTOM_BACKUP_FILE="${RESTORE_FILE:-}"

# -----------------------------------------------------------------------------
# 辅助函数
# -----------------------------------------------------------------------------
ensure_directories() {
    mkdir -p "$LOG_DIR"
    mkdir -p "$BACKUP_DIR"
    mkdir -p "$(dirname "$SERIAL_RESULT_FILE")"
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

get_zwave_pid() {
    local port_pid=$(netstat -tnlp 2>/dev/null | grep ":$ZWAVE_PORT " | awk '{print $7}' | cut -d'/' -f1 | head -n1)
    
    if [ -n "$port_pid" ] && [ "$port_pid" != "-" ]; then
        local cwd=$(ls -l /proc/$port_pid/cwd 2>/dev/null | grep -o 'zwave-js-ui' || true)
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
    
    if ! get_zwave_pid > /dev/null 2>&1; then
        echo "[$(date '+%F %T')] [MQTT-OFFLINE] $topic -> $payload" >> "$LOG_FILE"
        return 0
    fi
    
    load_mqtt_conf
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT_CONFIG" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload" 2>/dev/null || true
    echo "[$(date '+%F %T')] [MQTT] $topic -> $payload" >> "$LOG_FILE"
}

# -----------------------------------------------------------------------------
# 生成默认配置文件
# -----------------------------------------------------------------------------
generate_default_config() {
    log "从检测到的设备生成默认配置"
    
    # 读取检测结果
    SERIAL_PORT=""
    
    # 使用 jq 解析 JSON 并查找第一个可用的 zwave 设备
    ZWAVE_DEVICE=$(jq -r '
        .ports[] 
        | select(.type == "zwave" and (.busy == false or .busy == null))
        | "\(.port)|\(.baudrate // 115200)"
    ' "$SERIAL_RESULT_FILE" 2>/dev/null | head -n1)
    
    if [ -n "$ZWAVE_DEVICE" ]; then
        SERIAL_PORT=$(echo "$ZWAVE_DEVICE" | cut -d'|' -f1)
        BAUDRATE=$(echo "$ZWAVE_DEVICE" | cut -d'|' -f2)
        log "选择 zwave 适配器: $SERIAL_PORT ($BAUDRATE baud)"
    else
        log "内部错误: 配置生成期间未找到 zwave 设备"
        return 1
    fi
    
    # 获取 MQTT 配置
    load_mqtt_conf
    
    # 生成标准格式的配置文件到备份目录
    cat > "$DEFAULT_CONFIG_FILE" << EOF
{
  "zwave": {
    "port": "$SERIAL_PORT",
    "networkKey": "",
    "enableSoftReset": true,
    "securityKeys": {
      "S0_Legacy": "",
      "S2_Unauthenticated": "",
      "S2_Authenticated": "",
      "S2_AccessControl": ""
    }
  },
  "mqtt": {
    "enabled": true,
    "host": "$MQTT_HOST",
    "port": $MQTT_PORT_CONFIG,
    "username": "$MQTT_USER",
    "password": "$MQTT_PASS",
    "prefix": "zwave",
    "qos": 1,
    "retain": false
  },
  "gateway": {
    "type": "named",
    "authEnabled": false,
    "payloadType": "json_time_value",
    "nodeNames": true,
    "hassDiscovery": true,
    "discoveryPrefix": "homeassistant",
    "retainedDiscovery": true,
    "port": 8091,
    "host": "0.0.0.0"
  },
  "ui": {
    "darkMode": false,
    "navTabs": true,
    "showHints": true
  },
  "session": {
    "secret": "$(openssl rand -hex 32)"
  }
}
EOF
    
    # 确保容器内存储目录存在并复制配置
    log "复制配置到容器内"
    if ! proot-distro login "$PROOT_DISTRO" -- bash -c "
        mkdir -p '$ZWAVE_STORE_DIR'
        cp '$DEFAULT_CONFIG_FILE' '$ZWAVE_CONFIG_FILE'
    "; then
        log "配置复制到容器内失败"
        return 1
    fi
    
    log "默认配置生成成功"
}

START_TIME=$(date +%s)

# -----------------------------------------------------------------------------
# 主还原流程
# -----------------------------------------------------------------------------
ensure_directories

# -----------------------------------------------------------------------------
# 确定恢复文件
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
    
    # 停止服务以释放串口资源
    log "停止 zwave-js-ui 以释放串口资源"
    bash "$SERVICE_DIR/stop.sh" || true
    sleep 5
    
    # 运行串口检测脚本
    log "运行串口检测"
    if [ -f "$DETECT_SCRIPT" ]; then
        python3 "$DETECT_SCRIPT" || log "串口检测脚本执行失败"
    else
        log "串口检测脚本不存在: $DETECT_SCRIPT"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"serial detection script not found\",\"timestamp\":$(date +%s)}"
        exit 1
    fi
    
    # 检查是否检测到 Z-Wave 设备
    if [ ! -f "$SERIAL_RESULT_FILE" ]; then
        log "串口检测结果文件不存在"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"serial detection failed - no result file\",\"timestamp\":$(date +%s)}"
        exit 1
    fi
    
    # 使用 jq 检查是否有可用的 Z-Wave 设备
    ZWAVE_DEVICES=$(jq -r '.ports[] | select(.type == "zwave" and (.busy == false or .busy == null)) | .port' "$SERIAL_RESULT_FILE" 2>/dev/null | wc -l)
    
    if [ "$ZWAVE_DEVICES" -eq 0 ]; then
        log "未检测到可用的 zwave 适配器"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"skipped\",\"message\":\"no zwave adapter found - cannot generate configuration\",\"zwave_devices_detected\":0,\"timestamp\":$(date +%s)}"
        log "请连接 zwave 适配器后重试"
        exit 0
    fi
    
    log "找到 $ZWAVE_DEVICES 个可用的 zwave 适配器"
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"restoring\",\"method\":\"default_config\",\"zwave_devices_found\":$ZWAVE_DEVICES,\"timestamp\":$(date +%s)}"
    
    # 生成默认配置
    generate_default_config
    
    # 启动服务验证配置
    bash "$SERVICE_DIR/start.sh"
    
    # 等待并验证服务状态
    MAX_WAIT=120
    INTERVAL=5
    WAITED=0
    log "等待 zwave-js-ui 使用新配置启动"
    
    while [ "$WAITED" -lt "$MAX_WAIT" ]; do
        if bash "$SERVICE_DIR/status.sh" --quiet; then
            log "服务使用新配置在 ${WAITED}s 后运行"
            break
        fi
        sleep "$INTERVAL"
        WAITED=$((WAITED + INTERVAL))
    done
    
    # 最终状态验证和上报
    if bash "$SERVICE_DIR/status.sh" --quiet; then
        END_TIME=$(date +%s)
        DURATION=$((END_TIME - START_TIME))
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"success\",\"method\":\"default_config\",\"zwave_devices_found\":$ZWAVE_DEVICES,\"duration\":$DURATION,\"startup_time\":$WAITED,\"timestamp\":$END_TIME}"
        log "默认配置生成并服务启动成功，用时 ${DURATION}s (启动: ${WAITED}s)"
    else
        log "新配置生成后服务在 ${MAX_WAIT}s 后启动失败"
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
    
    TEMP_DIR="$TERMUX_TMP_DIR/zwave_zip_convert_$$"
    CONVERTED_FILE="$BACKUP_DIR/zwave-js-ui_converted_$(date +%Y%m%d-%H%M%S).tar.gz"
    
    rm -rf "$TEMP_DIR" && mkdir -p "$TEMP_DIR"
    if ! unzip -q "$RESTORE_FILE" -d "$TEMP_DIR"; then
        log "解压 zip 文件失败"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"failed to extract zip file\",\"timestamp\":$(date +%s)}"
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    
    # 查找解压后的存储目录
    STORE_DIR_IN_ZIP=""
    if [ -d "$TEMP_DIR/store" ]; then
        STORE_DIR_IN_ZIP="store"
    elif [ -d "$TEMP_DIR/zwave-js-ui/store" ]; then
        STORE_DIR_IN_ZIP="zwave-js-ui/store"
    elif [ -f "$TEMP_DIR/settings.json" ]; then
        # 如果直接是配置文件，创建store目录结构
        mkdir -p "$TEMP_DIR/store"
        mv "$TEMP_DIR"/*.* "$TEMP_DIR/store/" 2>/dev/null || true
        STORE_DIR_IN_ZIP="store"
    else
        # 查找包含settings.json的目录
        STORE_DIR_IN_ZIP=$(find "$TEMP_DIR" -name "settings.json" -type f | head -n1 | xargs dirname | sed "s|$TEMP_DIR/||")
    fi
    
    if [ -z "$STORE_DIR_IN_ZIP" ]; then
        log "zip 文件中未找到有效的 zwave-js-ui 存储"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"invalid zip structure\",\"timestamp\":$(date +%s)}"
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    
    # 创建标准的tar.gz格式
    if tar -czf "$CONVERTED_FILE" -C "$TEMP_DIR" "$STORE_DIR_IN_ZIP"; then
        FINAL_RESTORE_FILE="$CONVERTED_FILE"
        CONVERTED_FROM_ZIP=true
        log "zip 转换为: $(basename "$CONVERTED_FILE")"
    else
        log "从 zip 创建 tar.gz 失败"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"failed to create tar.gz from zip\",\"timestamp\":$(date +%s)}"
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    
    # 清理临时目录
    rm -rf "$TEMP_DIR"
    
elif [[ "$BASENAME" != *.tar.gz ]]; then
    log "不支持的文件格式: $EXT"
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"unsupported file format. only .tar.gz and .zip are supported\",\"file\":\"$BASENAME\",\"timestamp\":$(date +%s)}"
    exit 1
fi

# 上报开始还原
if [ "$CONVERTED_FROM_ZIP" = true ]; then
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"restoring\",\"method\":\"$METHOD\",\"original_file\":\"$(basename "$RESTORE_FILE")\",\"restore_file\":\"$(basename "$FINAL_RESTORE_FILE")\",\"converted_from_zip\":true}"
else
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"restoring\",\"method\":\"$METHOD\",\"file\":\"$(basename "$FINAL_RESTORE_FILE")\"}"
fi

# -----------------------------------------------------------------------------
# 停止服务
# -----------------------------------------------------------------------------
if get_zwave_pid > /dev/null 2>&1; then
    log "停止 zwave-js-ui 服务"
    bash "$SERVICE_DIR/stop.sh" || true
    sleep 3
fi

# -----------------------------------------------------------------------------
# 执行恢复
# -----------------------------------------------------------------------------
TEMP_RESTORE_DIR="$TERMUX_TMP_DIR/zwave_restore_$"
rm -rf "$TEMP_RESTORE_DIR" && mkdir -p "$TEMP_RESTORE_DIR"

if tar -xzf "$FINAL_RESTORE_FILE" -C "$TEMP_RESTORE_DIR"; then
    log "备份文件解压成功"
    
    # 还原存储目录
    if [ -d "$TEMP_RESTORE_DIR/store" ]; then
        log "还原存储目录"
        # 确保容器内存储目录存在并清空
        if ! proot-distro login "$PROOT_DISTRO" -- bash -c "
            rm -rf '$ZWAVE_STORE_DIR'
            mkdir -p '$ZWAVE_STORE_DIR'
            cp -r '$TEMP_RESTORE_DIR/store'/* '$ZWAVE_STORE_DIR/'
        "; then
            log "存储目录还原失败"
            rm -rf "$TEMP_RESTORE_DIR"
            mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"store directory restore failed\",\"timestamp\":$(date +%s)}"
            exit 1
        fi
    else
        log "备份中未找到存储目录，生成默认配置"
        # 如果没有存储目录，生成一个基本的默认配置
        proot-distro login "$PROOT_DISTRO" -- bash -c "
            mkdir -p '$ZWAVE_STORE_DIR'
            echo '{\"gateway\":{\"port\":8091,\"host\":\"0.0.0.0\"}}' > '$ZWAVE_CONFIG_FILE'
        "
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
    
    # 验证服务状态 - 只要进程运行就算成功
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
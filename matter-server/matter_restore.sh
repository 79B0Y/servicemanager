#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Matter Server 还原脚本
# 版本: v1.0.0
# 功能: 还原备份文件或生成默认配置
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# 路径和变量定义
# -----------------------------------------------------------------------------
SERVICE_ID="matter-server"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"
TERMUX_TMP_DIR="/data/data/com.termux/files/usr/tmp"

CONFIG_FILE="$BASE_DIR/configuration.yaml"

LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/restore.log"
BACKUP_DIR="/sdcard/isgbackup/$SERVICE_ID"

PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
MATTER_DATA_DIR="/opt/matter-server/data"
MATTER_CONFIG_FILE="/opt/matter-server/data/config.yaml"
MATTER_STORAGE_FILE="/opt/matter-server/data/matter.json"
MATTER_PORT="5580"

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

get_matter_pid() {
    local port_pid=$(netstat -tnlp 2>/dev/null | grep ":$MATTER_PORT " | awk '{print $7}' | cut -d'/' -f1 | head -n1)
    
    if [ -n "$port_pid" ] && [ "$port_pid" != "-" ]; then
        local cmdline=$(cat /proc/$port_pid/cmdline 2>/dev/null | grep -o 'matter-server\|python.*matter' || true)
        if [ -n "$cmdline" ]; then
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

generate_default_config() {
    log "生成默认 Matter Server 配置"
    
    # 生成基本的 config.yaml
    proot-distro login "$PROOT_DISTRO" -- bash -c "
        mkdir -p '$MATTER_DATA_DIR'
        cat > '$MATTER_CONFIG_FILE' << 'EOF'
# Matter Server Configuration
server:
  listen_host: '0.0.0.0'
  listen_port: 5580

# Storage settings
storage_path: '$MATTER_STORAGE_FILE'

# Logging configuration
log_level: 'INFO'

# MQTT Bridge (optional)
# mqtt:
#   broker_url: 'mqtt://localhost:1883'
#   username: 'matter'
#   password: 'matter'
EOF
    "
    
    # 生成基本的 matter.json 存储文件
    proot-distro login "$PROOT_DISTRO" -- bash -c "
        cat > '$MATTER_STORAGE_FILE' << 'EOF'
{
  \"version\": \"1.0\",
  \"nodes\": {},
  \"fabric_id\": null,
  \"node_id\": null,
  \"created_at\": \"$(date -Iseconds)\"
}
EOF
    "
    
    log "默认 Matter Server 配置生成成功"
}

START_TIME=$(date +%s)

# -----------------------------------------------------------------------------
# 主还原流程
# -----------------------------------------------------------------------------
ensure_directories

# 确保数据目录存在
proot-distro login "$PROOT_DISTRO" -- mkdir -p "$MATTER_DATA_DIR"

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
    RESTORE_FILE=$(ls -1t "$BACKUP_DIR"/matter-server_backup_*.tar.gz 2>/dev/null | head -n1 || true)
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
    if get_matter_pid > /dev/null 2>&1; then
        log "停止 Matter Server 服务"
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
    log "等待 Matter Server 服务启动"
    
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
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"success\",\"method\":\"default_config\",\"duration\":$DURATION,\"startup_time\":$WAITED,\"timestamp\":$END_TIME}"
        log "默认配置生成并启动成功，总耗时 ${DURATION}s"
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
    
    TEMP_DIR="$TERMUX_TMP_DIR/matter-server_zip_convert_$"
    CONVERTED_FILE="$BACKUP_DIR/matter-server_converted_$(date +%Y%m%d-%H%M%S).tar.gz"
    
    rm -rf "$TEMP_DIR" && mkdir -p "$TEMP_DIR"
    if ! unzip -q "$RESTORE_FILE" -d "$TEMP_DIR"; then
        log "解压 zip 文件失败"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"failed to extract zip file\",\"timestamp\":$(date +%s)}"
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    
    # 查找解压后的数据目录
    DATA_DIR_IN_ZIP=""
    if [ -d "$TEMP_DIR/data" ]; then
        DATA_DIR_IN_ZIP="data"
    elif [ -f "$TEMP_DIR/config.yaml" ] || [ -f "$TEMP_DIR/matter.json" ]; then
        # 如果直接是配置文件，创建data目录结构
        mkdir -p "$TEMP_DIR/data"
        mv "$TEMP_DIR"/*.* "$TEMP_DIR/data/" 2>/dev/null || true
        DATA_DIR_IN_ZIP="data"
    else
        # 查找包含config.yaml或matter.json的目录
        CONFIG_PATH=$(find "$TEMP_DIR" -name "config.yaml" -o -name "matter.json" | head -n1)
        if [ -n "$CONFIG_PATH" ]; then
            DATA_DIR_IN_ZIP=$(dirname "$CONFIG_PATH" | sed "s|$TEMP_DIR/||")
        fi
    fi
    
    if [ -z "$DATA_DIR_IN_ZIP" ]; then
        log "zip 文件中未找到有效的 Matter Server 数据"
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
if get_matter_pid > /dev/null 2>&1; then
    log "停止 Matter Server 服务"
    bash "$SERVICE_DIR/stop.sh" || true
    sleep 3
fi

# -----------------------------------------------------------------------------
# 执行还原
# -----------------------------------------------------------------------------
TEMP_RESTORE_DIR="$TERMUX_TMP_DIR/matter-server_restore_$"
rm -rf "$TEMP_RESTORE_DIR" && mkdir -p "$TEMP_RESTORE_DIR"

if tar -xzf "$FINAL_RESTORE_FILE" -C "$TEMP_RESTORE_DIR"; then
    log "备份文件解压成功"
    
    # 查找数据目录
    DATA_DIR_IN_BACKUP=""
    if [ -d "$TEMP_RESTORE_DIR/data" ]; then
        DATA_DIR_IN_BACKUP="data"
    elif [ -f "$TEMP_RESTORE_DIR/matter-server-data.tar.gz" ]; then
        # 如果是包含数据压缩包的备份，先解压
        tar -xzf "$TEMP_RESTORE_DIR/matter-server-data.tar.gz" -C "$TEMP_RESTORE_DIR"
        if [ -d "$TEMP_RESTORE_DIR/data" ]; then
            DATA_DIR_IN_BACKUP="data"
        fi
    elif [ -f "$TEMP_RESTORE_DIR/config.yaml" ] || [ -f "$TEMP_RESTORE_DIR/matter.json" ]; then
        # 如果是直接的配置文件，创建data目录结构
        mkdir -p "$TEMP_RESTORE_DIR/data"
        [ -f "$TEMP_RESTORE_DIR/config.yaml" ] && cp "$TEMP_RESTORE_DIR/config.yaml" "$TEMP_RESTORE_DIR/data/"
        [ -f "$TEMP_RESTORE_DIR/matter.json" ] && cp "$TEMP_RESTORE_DIR/matter.json" "$TEMP_RESTORE_DIR/data/"
        DATA_DIR_IN_BACKUP="data"
    else
        # 查找包含 config.yaml 或 matter.json 的目录
        CONFIG_PATH=$(find "$TEMP_RESTORE_DIR" -name "config.yaml" -o -name "matter.json" | head -n1)
        if [ -n "$CONFIG_PATH" ]; then
            DATA_DIR_IN_BACKUP=$(dirname "$CONFIG_PATH" | sed "s|$TEMP_RESTORE_DIR/||")
        fi
    fi
    
    if [ -n "$DATA_DIR_IN_BACKUP" ]; then
        # 还原数据文件
        log "还原数据文件"
        proot-distro login "$PROOT_DISTRO" -- bash -c "
            rm -rf '$MATTER_DATA_DIR'
            mkdir -p '$(dirname $MATTER_DATA_DIR)'
        "
        
        # 使用Termux的临时目录，然后复制到容器内
        TERMUX_RESTORE_TEMP="$TERMUX_TMP_DIR/matter-server-restore-$"
        mkdir -p "$TERMUX_RESTORE_TEMP"
        cp -r "$TEMP_RESTORE_DIR/$DATA_DIR_IN_BACKUP" "$TERMUX_RESTORE_TEMP/"
        
        # 将数据复制到容器内
        proot-distro login "$PROOT_DISTRO" -- bash -c "
            # 从Termux复制到容器临时位置
            mkdir -p '/tmp'
            cp -r '$TERMUX_RESTORE_TEMP/$(basename $DATA_DIR_IN_BACKUP)' '/tmp/matter-server-restore'
            # 移动到最终位置
            mv '/tmp/matter-server-restore' '$MATTER_DATA_DIR'
        "
        
        # 清理Termux临时目录
        rm -rf "$TERMUX_RESTORE_TEMP"
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
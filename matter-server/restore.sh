#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Matter Server 还原脚本 - 最终修复版本
# - 支持 tar.gz/zip/无备份全自动恢复
# - 新增 -c 参数直接初始化配置
# - 修复: 按基础要求还原到 /root/.matter_server/ 目录
# - 修复: 引号匹配问题
# =============================================================================

set -euo pipefail

# ------------------- 路径和变量定义 -------------------
SERVICE_ID="matter-server"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"
TERMUX_TMP_DIR="/data/data/com.termux/files/usr/tmp"

CONFIG_FILE="$BASE_DIR/configuration.yaml"
LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/restore.log"
BACKUP_DIR="/sdcard/isgbackup/$SERVICE_ID"

PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
MATTER_INSTALL_DIR="/opt/matter-server"
# 修复: 按基础要求使用 /root/.matter_server/ 目录
MATTER_DATA_DIR="/root/.matter_server"
MATTER_CONFIG_FILE="/opt/matter-server/config.yaml"
MATTER_PORT="5580"

# 支持外部指定还原文件和初始化模式
CUSTOM_BACKUP_FILE="${RESTORE_FILE:-}"
INIT_CONFIG_MODE=false

# 解析命令行参数 - 新增 -c 参数支持
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--config-init)
            INIT_CONFIG_MODE=true
            shift
            ;;
        -f|--file)
            CUSTOM_BACKUP_FILE="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

# ------------------- 工具函数 -------------------
ensure_directories() {
    mkdir -p "$LOG_DIR" "$BACKUP_DIR" "$TERMUX_TMP_DIR"
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

# 修复: 生成标准配置到正确路径，同时初始化数据目录
generate_default_config() {
    log "生成默认 Matter Server 配置和数据目录"
    load_mqtt_conf
    
    # 确保目录存在
    proot-distro login "$PROOT_DISTRO" -- bash -c "
        mkdir -p '$MATTER_DATA_DIR'
        mkdir -p '$(dirname $MATTER_CONFIG_FILE)'
    "
    
    # 生成配置文件到 /opt/matter-server/config.yaml
    proot-distro login "$PROOT_DISTRO" -- bash -c "
        cat > '$MATTER_CONFIG_FILE' <<'EOCONFIG'
mqtt:
  broker: 'mqtt://$MQTT_HOST:$MQTT_PORT_CONFIG'
  username: '$MQTT_USER'
  password: '$MQTT_PASS'

matter:
  listen_ip: '0.0.0.0'
  port: $MATTER_PORT
  storage_path: '$MATTER_DATA_DIR'
  ssl:
    certfile: '$MATTER_INSTALL_DIR/certificate.pem'
    keyfile: '$MATTER_INSTALL_DIR/privatekey.pem'

logging:
  level: 'INFO'
  file: '$MATTER_INSTALL_DIR/matter-server.log'
EOCONFIG
    "
    
    # 在数据目录创建初始文件
    proot-distro login "$PROOT_DISTRO" -- bash -c "
        # 创建初始的 matter.json 存储文件
        cat > '$MATTER_DATA_DIR/matter.json' <<'EOJSON'
{
  \"version\": \"1.0\",
  \"nodes\": {},
  \"fabric_id\": null,
  \"node_id\": null,
  \"created_at\": \"\$(date -Iseconds)\"
}
EOJSON

        # 创建配置目录结构
        mkdir -p '$MATTER_DATA_DIR/config'
        mkdir -p '$MATTER_DATA_DIR/certificates'
        mkdir -p '$MATTER_DATA_DIR/logs'
        
        # 创建版本标记文件
        echo \"Matter Server Data Directory - Initialized \$(date)\" > '$MATTER_DATA_DIR/.initialized'
    "
    
    log "默认 Matter Server 配置和数据目录生成成功"
}

# ------------------- 主还原流程 -------------------
START_TIME=$(date +%s)
ensure_directories

# 新增: -c 参数直接初始化配置模式
if [ "$INIT_CONFIG_MODE" = true ]; then
    log "执行初始化配置模式 (bash restore.sh -c)"
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"restoring\",\"method\":\"config_init\",\"message\":\"initializing default configuration\",\"timestamp\":$(date +%s)}"
    
    # 停止服务
    if get_matter_pid > /dev/null 2>&1; then
        log "停止 Matter Server 服务"
        bash "$SERVICE_DIR/stop.sh" || true
        sleep 3
    fi
    
    # 确保安装目录存在
    proot-distro login "$PROOT_DISTRO" -- mkdir -p "$MATTER_INSTALL_DIR"
    
    # 生成默认配置和数据目录
    generate_default_config
    
    # 启动服务验证
    log "启动服务验证配置"
    bash "$SERVICE_DIR/start.sh"
    
    # 等待启动
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
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"success\",\"method\":\"config_init\",\"duration\":$DURATION,\"startup_time\":$WAITED,\"timestamp\":$END_TIME}"
        log "初始化配置完成并启动成功，总耗时 ${DURATION}s"
    else
        log "服务启动失败，超时 ${MAX_WAIT}s"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"service failed to start after config initialization\",\"method\":\"config_init\",\"timestamp\":$(date +%s)}"
        exit 1
    fi
    exit 0
fi

# 修复: 确保数据目录存在
proot-distro login "$PROOT_DISTRO" -- mkdir -p "$MATTER_DATA_DIR"

# --- 确定还原文件 ---
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

# --- 无备份，生成默认配置 ---
if [ -z "$RESTORE_FILE" ]; then
    log "未找到备份文件，将生成默认配置"
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"restoring\",\"method\":\"default_config\",\"timestamp\":$(date +%s)}"
    if get_matter_pid > /dev/null 2>&1; then
        log "停止 Matter Server 服务"
        bash "$SERVICE_DIR/stop.sh" || true
        sleep 3
    fi
    generate_default_config
    log "启动服务验证配置"
    bash "$SERVICE_DIR/start.sh"
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

# --- 有备份，开始还原 ---
log "开始从备份文件还原: $RESTORE_FILE"
BASENAME=$(basename -- "$RESTORE_FILE")
EXT="${BASENAME##*.}"
EXT_LOWER=$(echo "$EXT" | tr '[:upper:]' '[:lower:]')
FINAL_RESTORE_FILE="$RESTORE_FILE"
CONVERTED_FROM_ZIP=false

if [[ "$EXT_LOWER" == "zip" ]]; then
    log "检测到 zip 文件，转换为 tar.gz"
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"restoring\",\"method\":\"$METHOD\",\"file\":\"$RESTORE_FILE\",\"converting_zip\":true}"
    
    # 修复: 使用 Termux 专用临时目录
    TEMP_DIR="$TERMUX_TMP_DIR/matter-server_zip_convert_$$"
    CONVERTED_FILE="$BACKUP_DIR/matter-server_converted_$(date +%Y%m%d-%H%M%S).tar.gz"
    rm -rf "$TEMP_DIR" && mkdir -p "$TEMP_DIR"
    
    if ! unzip -q "$RESTORE_FILE" -d "$TEMP_DIR"; then
        log "解压 zip 文件失败"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"failed to extract zip file\",\"timestamp\":$(date +%s)}"
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    
    DATA_DIR_IN_ZIP=""
    if [ -d "$TEMP_DIR/.matter_server" ]; then
        DATA_DIR_IN_ZIP=".matter_server"
    elif [ -f "$TEMP_DIR/matter-server-data.tar.gz" ]; then
        tar -xzf "$TEMP_DIR/matter-server-data.tar.gz" -C "$TEMP_DIR"
        if [ -d "$TEMP_DIR/.matter_server" ]; then
            DATA_DIR_IN_ZIP=".matter_server"
        fi
    elif [ -f "$TEMP_DIR/matter.json" ]; then
        mkdir -p "$TEMP_DIR/.matter_server"
        mv "$TEMP_DIR"/*.* "$TEMP_DIR/.matter_server/" 2>/dev/null || true
        DATA_DIR_IN_ZIP=".matter_server"
    else
        DATA_PATH=$(find "$TEMP_DIR" -name "matter.json" -o -name ".matter_server" | head -n1)
        if [ -n "$DATA_PATH" ]; then
            if [ -f "$DATA_PATH" ]; then
                DATA_DIR_IN_ZIP=$(dirname "$DATA_PATH" | sed "s|$TEMP_DIR/||")
            else
                DATA_DIR_IN_ZIP=$(echo "$DATA_PATH" | sed "s|$TEMP_DIR/||")
            fi
        fi
    fi
    
    if [ -z "$DATA_DIR_IN_ZIP" ]; then
        log "zip 文件中未找到有效的 Matter Server 数据"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"invalid zip structure\",\"timestamp\":$(date +%s)}"
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    
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

mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"restoring\",\"method\":\"$METHOD\",\"file\":\"$(basename "$FINAL_RESTORE_FILE")\"}"

if get_matter_pid > /dev/null 2>&1; then
    log "停止 Matter Server 服务"
    bash "$SERVICE_DIR/stop.sh" || true
    sleep 3
fi

# 修复: 使用 Termux 专用临时目录
TEMP_RESTORE_DIR="$TERMUX_TMP_DIR/matter-server_restore_$$"
rm -rf "$TEMP_RESTORE_DIR" && mkdir -p "$TEMP_RESTORE_DIR"

if tar -xzf "$FINAL_RESTORE_FILE" -C "$TEMP_RESTORE_DIR"; then
    log "备份文件解压成功"
    DATA_DIR_IN_BACKUP=""
    
    # 修复: 寻找 .matter_server 目录或相关数据
    if [ -d "$TEMP_RESTORE_DIR/.matter_server" ]; then
        DATA_DIR_IN_BACKUP=".matter_server"
    elif [ -f "$TEMP_RESTORE_DIR/matter-server-data.tar.gz" ]; then
        log "发现压缩的数据文件，解压中"
        tar -xzf "$TEMP_RESTORE_DIR/matter-server-data.tar.gz" -C "$TEMP_RESTORE_DIR"
        if [ -d "$TEMP_RESTORE_DIR/.matter_server" ]; then
            DATA_DIR_IN_BACKUP=".matter_server"
        fi
    elif [ -f "$TEMP_RESTORE_DIR/matter.json" ]; then
        # 如果找到散落的数据文件，重新组织到 .matter_server 目录
        log "重新组织散落的数据文件"
        mkdir -p "$TEMP_RESTORE_DIR/.matter_server"
        mv "$TEMP_RESTORE_DIR"/*.json "$TEMP_RESTORE_DIR/.matter_server/" 2>/dev/null || true
        mv "$TEMP_RESTORE_DIR"/*.yaml "$TEMP_RESTORE_DIR/.matter_server/" 2>/dev/null || true
        mv "$TEMP_RESTORE_DIR"/*.yml "$TEMP_RESTORE_DIR/.matter_server/" 2>/dev/null || true
        DATA_DIR_IN_BACKUP=".matter_server"
    else
        # 寻找可能的数据文件路径
        DATA_PATH=$(find "$TEMP_RESTORE_DIR" -name "matter.json" -o -name ".matter_server" | head -n1)
        if [ -n "$DATA_PATH" ]; then
            if [ -f "$DATA_PATH" ]; then
                DATA_DIR_IN_BACKUP=$(dirname "$DATA_PATH" | sed "s|$TEMP_RESTORE_DIR/||")
            else
                DATA_DIR_IN_BACKUP=$(echo "$DATA_PATH" | sed "s|$TEMP_RESTORE_DIR/||")
            fi
        fi
    fi
    
    if [ -n "$DATA_DIR_IN_BACKUP" ]; then
        log "还原数据文件到 $MATTER_DATA_DIR"
        
        # 清理现有数据目录
        proot-distro login "$PROOT_DISTRO" -- bash -c "
            rm -rf '$MATTER_DATA_DIR'
            mkdir -p '$(dirname $MATTER_DATA_DIR)'
        "
        
        # 修复: 使用 Termux 专用临时目录传输数据
        TERMUX_RESTORE_TEMP="$TERMUX_TMP_DIR/matter-server-restore-$$"
        mkdir -p "$TERMUX_RESTORE_TEMP"
        cp -r "$TEMP_RESTORE_DIR/$DATA_DIR_IN_BACKUP" "$TERMUX_RESTORE_TEMP/"
        
        # 将数据复制到容器内的正确位置
        proot-distro login "$PROOT_DISTRO" -- bash -c "
            mkdir -p '/tmp'
            cp -r '$TERMUX_RESTORE_TEMP/$(basename $DATA_DIR_IN_BACKUP)' '/tmp/matter-server-restore'
            mv '/tmp/matter-server-restore' '$MATTER_DATA_DIR'
            
            # 确保目录权限正确
            chmod -R 755 '$MATTER_DATA_DIR' 2>/dev/null || true
            
            # 验证关键文件
            if [ -f '$MATTER_DATA_DIR/matter.json' ]; then
                echo 'matter.json 文件已还原'
            else
                echo '警告: matter.json 文件未找到'
            fi
        "
        
        rm -rf "$TERMUX_RESTORE_TEMP"
        log "数据文件还原完成"
    else
        log "备份中未找到有效的数据目录，生成默认配置"
        generate_default_config
    fi
    rm -rf "$TEMP_RESTORE_DIR"
    
    log "还原完成，重启服务"
    bash "$SERVICE_DIR/start.sh"
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
    
    if bash "$SERVICE_DIR/status.sh" --quiet; then
        END_TIME=$(date +%s)
        DURATION=$((END_TIME - START_TIME))
        SIZE_KB=$(du -k "$FINAL_RESTORE_FILE" | awk '{print $1}')
        if [ "$CONVERTED_FROM_ZIP" = true ]; then
            mqtt_report "isg/restore/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"success\",\"method\":\"$METHOD\",\"original_file\":\"$(basename "$RESTORE_FILE")\",\"restore_file\":\"$(basename "$FINAL_RESTORE_FILE")\",\"size_kb\":$SIZE_KB,\"duration\":$DURATION,\"converted_from_zip\":true,\"timestamp\":$END_TIME}"
            log "还原 + 重启完成: $(basename "$FINAL_RESTORE_FILE") ($SIZE_KB KB, ${DURATION}s)"
            log "转换自: $(basename "$RESTORE_FILE")"
        else
            mqtt_report "isg/restore/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"success\",\"method\":\"$METHOD\",\"file\":\"$(basename "$FINAL_RESTORE_FILE")\",\"size_kb\":$SIZE_KB,\"duration\":$DURATION,\"timestamp\":$END_TIME}"
            log "还原 + 重启完成: $(basename "$FINAL_RESTORE_FILE") ($SIZE_KB KB, ${DURATION}s)"
        fi
        log "✅ 还原成功"
        
        # 验证还原的数据
        log "验证还原的数据完整性"
        proot-distro login "$PROOT_DISTRO" -- bash -c "
            if [ -d '$MATTER_DATA_DIR' ]; then
                file_count=\$(find '$MATTER_DATA_DIR' -type f 2>/dev/null | wc -l)
                echo \"还原验证: 数据目录包含 \$file_count 个文件\"
            fi
        " >> "$LOG_FILE"
        
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

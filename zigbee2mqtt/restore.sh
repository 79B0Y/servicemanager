#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Zigbee2MQTT 还原脚本
# 版本: v1.1.1 - 修复版
# 功能: 还原备份文件或生成默认配置
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# 从common_paths.sh提取的路径和配置定义
# -----------------------------------------------------------------------------
SERVICE_ID="zigbee2mqtt"
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"

# 主要目录路径 (Termux 环境)
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"
TERMUX_VAR_DIR="/data/data/com.termux/files/usr/var"
TERMUX_TMP_DIR="/data/data/com.termux/files/usr/tmp"

# 配置文件路径
CONFIG_FILE="$BASE_DIR/configuration.yaml"
SERVICEUPDATE_FILE="$BASE_DIR/serviceupdate.json"
DETECT_SCRIPT="$BASE_DIR/detect_serial_adapters.py"
VERSION_FILE="$SERVICE_DIR/VERSION"

# 服务控制路径 (isgservicemonitor)
SERVICE_CONTROL_DIR="$TERMUX_VAR_DIR/service/$SERVICE_ID"
CONTROL_FILE="$SERVICE_CONTROL_DIR/supervise/control"
DOWN_FILE="$SERVICE_CONTROL_DIR/down"

# 日志目录和文件
LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE_RESTORE="$LOG_DIR/restore.log"
LOG_FILE_START="$LOG_DIR/start.log"
LOG_FILE_STOP="$LOG_DIR/stop.log"

# 状态和锁文件
DISABLED_FLAG="$SERVICE_DIR/.disabled"

# 备份相关路径
BACKUP_DIR="${BACKUP_DIR:-/sdcard/isgbackup/$SERVICE_ID}"
SERIAL_RESULT_FILE="/sdcard/isgbackup/serialport/latest.json"
DEFAULT_CONFIG_FILE="$BACKUP_DIR/configuration_default.yaml"

# 容器内路径 (Proot Ubuntu)
Z2M_INSTALL_DIR="/opt/zigbee2mqtt"
Z2M_DATA_DIR="${Z2M_DATA_DIR:-$Z2M_INSTALL_DIR/data}"
Z2M_CONFIG_FILE="$Z2M_DATA_DIR/configuration.yaml"

# 临时文件路径
TEMP_DIR="$TERMUX_TMP_DIR/${SERVICE_ID}_temp"
RESTORE_TEMP_DIR="$TERMUX_TMP_DIR/restore_temp_$$"

# 网络和端口
Z2M_PORT="8080"
MQTT_TIMEOUT="10"

# 脚本参数和配置
MAX_TRIES="${MAX_TRIES:-30}"
RETRY_INTERVAL="${RETRY_INTERVAL:-60}"
MAX_WAIT="${MAX_WAIT:-300}"
INTERVAL="${INTERVAL:-5}"

# 设置脚本特定的日志文件
LOG_FILE="$LOG_FILE_RESTORE"

# -----------------------------------------------------------------------------
# 辅助函数定义
# -----------------------------------------------------------------------------

# 确保目录存在
ensure_directories() {
    mkdir -p "$LOG_DIR"
    mkdir -p "$BACKUP_DIR"
    mkdir -p "$(dirname "$SERIAL_RESULT_FILE")"
}

# 加载 MQTT 配置从主配置文件
load_mqtt_conf() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "错误: 配置文件不存在: $CONFIG_FILE"
        exit 1
    fi
    
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
}

# MQTT 消息发布
mqtt_report() {
    local topic="$1"
    local payload="$2"
    local log_file="${3:-$LOG_FILE}"
    
    load_mqtt_conf
    if command -v mosquitto_pub >/dev/null 2>&1; then
        mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload" || true
    fi
    echo "[$(date '+%F %T')] [MQTT] $topic -> $payload" >> "$log_file"
}

# 统一日志记录
log() {
    echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"
}

# 获取 Zigbee2MQTT 进程 PID
get_z2m_pid() {
    local port_pid=$(netstat -tnlp 2>/dev/null | grep ":$Z2M_PORT " | awk '{print $7}' | cut -d'/' -f1 | head -n1)
    
    if [ -n "$port_pid" ] && [ "$port_pid" != "-" ]; then
        local cwd=$(ls -l /proc/$port_pid/cwd 2>/dev/null | grep -o 'zigbee2mqtt' || true)
        if [ -n "$cwd" ]; then
            echo "$port_pid"
            return 0
        fi
    fi
    
    return 1
}

# 检查服务是否运行的改进版本
check_service_status() {
    if get_z2m_pid > /dev/null 2>&1; then
        return 0  # 服务运行中
    else
        return 1  # 服务未运行
    fi
}

# 启动时间记录
START_TIME=$(date +%s)
CUSTOM_BACKUP_FILE="${RESTORE_FILE:-}"

# 确保必要目录存在
ensure_directories

# 确保数据目录存在
proot-distro login "$PROOT_DISTRO" -- bash -c "mkdir -p $Z2M_DATA_DIR"

# -----------------------------------------------------------------------------
# 生成默认配置文件
# -----------------------------------------------------------------------------
generate_default_config() {
    log "开始生成默认配置文件，基于检测到的设备信息"
    
    # 检查串口检测结果文件是否存在
    if [ ! -f "$SERIAL_RESULT_FILE" ]; then
        log "错误: 串口检测结果文件不存在: $SERIAL_RESULT_FILE"
        return 1
    fi
    
    # 读取检测结果，使用更健壮的JSON解析方式
    SERIAL_PORT=""
    ADAPTER_TYPE="ezsp"
    BAUDRATE=115200
    
    # 首先检查JSON文件格式
    if ! python3 -c "import json; json.load(open('$SERIAL_RESULT_FILE'))" 2>/dev/null; then
        log "错误: 串口检测结果JSON格式无效"
        return 1
    fi
    
    # 使用Python脚本解析JSON，更加可靠
    ZIGBEE_INFO=$(python3 -c "
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
    
    for port in ports:
        if port.get('type') == 'zigbee' and not port.get('busy', False):
            print(f\"{port['port']}|{port.get('protocol', 'ezsp')}|{port.get('baudrate', 115200)}\")
            sys.exit(0)
    
    print('NO_ZIGBEE_FOUND')
except Exception as e:
    print(f'JSON_PARSE_ERROR: {e}')
" 2>/dev/null)
    
    if [ "$ZIGBEE_INFO" = "NO_ZIGBEE_FOUND" ]; then
        log "错误: 未检测到可用的Zigbee适配器"
        return 1
    elif [[ "$ZIGBEE_INFO" == JSON_PARSE_ERROR* ]]; then
        log "错误: JSON解析失败: $ZIGBEE_INFO"
        return 1
    elif [ -z "$ZIGBEE_INFO" ]; then
        log "错误: 无法获取Zigbee设备信息"
        return 1
    fi
    
    # 解析设备信息
    SERIAL_PORT=$(echo "$ZIGBEE_INFO" | cut -d'|' -f1)
    ADAPTER_TYPE=$(echo "$ZIGBEE_INFO" | cut -d'|' -f2)
    BAUDRATE=$(echo "$ZIGBEE_INFO" | cut -d'|' -f3)
    
    if [ -z "$SERIAL_PORT" ]; then
        log "错误: 无法提取串口信息"
        return 1
    fi
    
    log "选择的Zigbee适配器: $SERIAL_PORT (协议: $ADAPTER_TYPE, 波特率: $BAUDRATE)"
    
    # 获取 MQTT 配置
    load_mqtt_conf
    
    # 生成标准格式的配置文件到备份目录
    log "生成配置文件: $DEFAULT_CONFIG_FILE"
    cat > "$DEFAULT_CONFIG_FILE" << EOF
advanced:
  network_key: GENERATE
  pan_id: GENERATE
  ext_pan_id: GENERATE
frontend:
  enabled: true
mqtt:
  base_topic: zigbee2mqtt
  password: '$MQTT_PASS'
  server: mqtt://$MQTT_HOST:$MQTT_PORT
  user: '$MQTT_USER'
serial:
  adapter: $ADAPTER_TYPE
  baudrate: $BAUDRATE
  port: $SERIAL_PORT
version: 4
homeassistant:
  enabled: true
  experimental_event_entities: true
  legacy_action_sensor: true
  discovery_topic: homeassistant
  status_topic: homeassistant/status
EOF
    
    # 复制到容器内
    log "将配置文件复制到容器内: $Z2M_CONFIG_FILE"
    if ! proot-distro login "$PROOT_DISTRO" -- bash -c "rm -rf $Z2M_DATA_DIR && mkdir -p $Z2M_DATA_DIR && cp '$DEFAULT_CONFIG_FILE' $Z2M_DATA_DIR/configuration.yaml"; then
        log "错误: 无法将配置文件复制到容器内"
        return 1
    fi
    
    log "默认配置生成成功"
    return 0
}

# -----------------------------------------------------------------------------
# 确定恢复文件
# -----------------------------------------------------------------------------
log "开始Zigbee2MQTT还原过程"

if [ -n "$CUSTOM_BACKUP_FILE" ]; then
    RESTORE_FILE="$CUSTOM_BACKUP_FILE"
    if [ -f "$RESTORE_FILE" ]; then
        log "使用用户指定的文件: $RESTORE_FILE"
        METHOD="user_specified"
    else
        log "错误: 用户指定的文件不存在: $RESTORE_FILE"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"user specified file not found\",\"file\":\"$RESTORE_FILE\",\"timestamp\":$(date +%s)}"
        exit 1
    fi
else
    RESTORE_FILE=$(ls -1t "$BACKUP_DIR"/zigbee2mqtt_backup_*.tar.gz 2>/dev/null | head -n1 || true)
    if [ -n "$RESTORE_FILE" ] && [ -f "$RESTORE_FILE" ]; then
        log "使用最新的备份文件: $RESTORE_FILE"
        METHOD="latest_backup"
    else
        RESTORE_FILE=""
        METHOD="default_config"
        log "未找到备份文件，将生成默认配置"
    fi
fi

# -----------------------------------------------------------------------------
# 处理无备份文件的情况 - 生成默认配置
# -----------------------------------------------------------------------------
if [ -z "$RESTORE_FILE" ]; then
    log "未找到备份文件，开始生成默认配置流程"
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"restoring\",\"method\":\"default_config\",\"timestamp\":$(date +%s)}"
    
    # 停止服务以释放串口资源
    log "停止zigbee2mqtt服务以释放串口资源"
    bash "$SERVICE_DIR/stop.sh" 2>/dev/null || true
    sleep 5
    
    # 运行串口检测脚本
    log "开始运行串口检测脚本"
    if [ -f "$DETECT_SCRIPT" ]; then
        if python3 "$DETECT_SCRIPT"; then
            log "串口检测脚本执行成功"
        else
            log "警告: 串口检测脚本执行失败，但继续尝试处理"
        fi
    else
        log "错误: 串口检测脚本不存在: $DETECT_SCRIPT"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"serial detection script not found\",\"timestamp\":$(date +%s)}"
        exit 1
    fi
    
    # 等待检测完成
    log "等待串口检测完成..."
    sleep 3
    
    # 检查是否检测到 Zigbee 设备
    if [ ! -f "$SERIAL_RESULT_FILE" ]; then
        log "错误: 串口检测结果文件不存在: $SERIAL_RESULT_FILE"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"serial detection failed - no result file\",\"timestamp\":$(date +%s)}"
        exit 1
    fi
    
    # 检查Zigbee设备数量
    log "分析串口检测结果..."
    ZIGBEE_DEVICES=$(python3 -c "
import json
import sys
try:
    with open('$SERIAL_RESULT_FILE', 'r') as f:
        data = json.load(f)
    
    count = 0
    # 处理新格式的results数组
    if 'results' in data and isinstance(data['results'], list):
        ports = data['results']
    # 处理旧格式的ports数组
    elif 'ports' in data and isinstance(data['ports'], list):
        ports = data['ports']
    else:
        ports = []
    
    for port in ports:
        if port.get('type') == 'zigbee' and not port.get('busy', False):
            count += 1
    
    print(count)
except:
    print(0)
" 2>/dev/null)
    
    # 确保ZIGBEE_DEVICES是数字
    ZIGBEE_DEVICES=${ZIGBEE_DEVICES:-0}
    
    if [ "$ZIGBEE_DEVICES" -eq 0 ]; then
        log "未检测到可用的Zigbee适配器"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"skipped\",\"message\":\"no zigbee adapter found - cannot generate configuration\",\"zigbee_devices_detected\":0,\"timestamp\":$(date +%s)}"
        log "请连接Zigbee适配器后重试"
        exit 0
    fi
    
    log "检测到 $ZIGBEE_DEVICES 个可用的Zigbee适配器"
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"restoring\",\"method\":\"default_config\",\"zigbee_devices_found\":$ZIGBEE_DEVICES,\"timestamp\":$(date +%s)}"
    
    # 生成默认配置
    if ! generate_default_config; then
        log "错误: 生成默认配置失败"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"failed to generate default configuration\",\"timestamp\":$(date +%s)}"
        exit 1
    fi
    
    # 启动服务验证配置
    log "启动服务以验证新配置"
    if ! bash "$SERVICE_DIR/start.sh"; then
        log "警告: 启动脚本返回非零状态，但继续检查服务状态"
    fi
    
    # 等待并验证服务状态
    MAX_WAIT=120
    INTERVAL=5
    WAITED=0
    log "等待zigbee2mqtt使用新配置启动 (最长等待${MAX_WAIT}秒)"
    
    while [ "$WAITED" -lt "$MAX_WAIT" ]; do
        if check_service_status; then
            log "服务在等待 ${WAITED}秒 后使用新配置成功启动"
            break
        fi
        sleep "$INTERVAL"
        WAITED=$((WAITED + INTERVAL))
        log "等待中... ${WAITED}/${MAX_WAIT}秒"
    done
    
    # 最终状态验证和上报
    if check_service_status; then
        END_TIME=$(date +%s)
        DURATION=$((END_TIME - START_TIME))
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"success\",\"method\":\"default_config\",\"zigbee_devices_found\":$ZIGBEE_DEVICES,\"duration\":$DURATION,\"startup_time\":$WAITED,\"timestamp\":$END_TIME}"
        log "默认配置生成完成，服务成功启动 (总耗时: ${DURATION}秒, 启动时间: ${WAITED}秒)"
    else
        log "错误: 服务在 ${MAX_WAIT}秒 后仍未能使用新配置启动"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"service failed to start after config generation\",\"method\":\"default_config\",\"max_wait\":$MAX_WAIT,\"timestamp\":$(date +%s)}"
        exit 1
    fi
    
    exit 0
fi

# -----------------------------------------------------------------------------
# 处理备份文件还原
# -----------------------------------------------------------------------------
log "开始从备份文件还原: $RESTORE_FILE"

# 检查文件格式
BASENAME=$(basename -- "$RESTORE_FILE")
EXT="${BASENAME##*.}"
EXT_LOWER=$(echo "$EXT" | tr '[:upper:]' '[:lower:]')
FINAL_RESTORE_FILE="$RESTORE_FILE"
CONVERTED_FROM_ZIP=false

# 如果是zip文件，需要转换为tar.gz格式
if [[ "$EXT_LOWER" == "zip" ]]; then
    log "检测到ZIP文件，转换为tar.gz格式"
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"restoring\",\"method\":\"$METHOD\",\"file\":\"$RESTORE_FILE\",\"converting_zip\":true,\"timestamp\":$(date +%s)}"
    
    TEMP_DIR="$RESTORE_TEMP_DIR"
    CONVERTED_FILE="$BACKUP_DIR/zigbee2mqtt_converted_$(date +%Y%m%d-%H%M%S).tar.gz"
    
    # 创建临时目录并解压
    rm -rf "$TEMP_DIR" && mkdir -p "$TEMP_DIR"
    if ! unzip -q "$RESTORE_FILE" -d "$TEMP_DIR"; then
        log "错误: 无法解压ZIP文件"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"failed to extract zip file\",\"timestamp\":$(date +%s)}"
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    
    # 查找解压后的数据目录
    DATA_DIR_IN_ZIP=""
    if [ -d "$TEMP_DIR/data" ]; then
        DATA_DIR_IN_ZIP="data"
    elif [ -d "$TEMP_DIR/zigbee2mqtt/data" ]; then
        DATA_DIR_IN_ZIP="zigbee2mqtt/data"
    elif [ -f "$TEMP_DIR/configuration.yaml" ]; then
        # 如果直接是配置文件，创建data目录结构
        mkdir -p "$TEMP_DIR/data"
        mv "$TEMP_DIR"/*.* "$TEMP_DIR/data/" 2>/dev/null || true
        DATA_DIR_IN_ZIP="data"
    else
        # 查找包含configuration.yaml的目录
        CONFIG_PATH=$(find "$TEMP_DIR" -name "configuration.yaml" -type f | head -n1)
        if [ -n "$CONFIG_PATH" ]; then
            DATA_DIR_IN_ZIP=$(dirname "$CONFIG_PATH" | sed "s|$TEMP_DIR/||")
        fi
    fi
    
    if [ -z "$DATA_DIR_IN_ZIP" ]; then
        log "错误: ZIP文件中未找到有效的zigbee2mqtt数据"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"invalid zip structure - no configuration.yaml found\",\"timestamp\":$(date +%s)}"
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    
    log "在ZIP中找到数据目录: $DATA_DIR_IN_ZIP"
    
    # 创建标准的tar.gz格式
    if tar -czf "$CONVERTED_FILE" -C "$TEMP_DIR" "$DATA_DIR_IN_ZIP"; then
        FINAL_RESTORE_FILE="$CONVERTED_FILE"
        CONVERTED_FROM_ZIP=true
        log "ZIP转换为tar.gz完成: $(basename "$CONVERTED_FILE")"
    else
        log "错误: 从ZIP创建tar.gz失败"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"failed to create tar.gz from zip\",\"timestamp\":$(date +%s)}"
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    
    # 清理临时目录
    rm -rf "$TEMP_DIR"
    
elif [[ "$BASENAME" != *.tar.gz ]]; then
    log "错误: 不支持的文件格式: $EXT"
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"unsupported file format. only .tar.gz and .zip are supported\",\"file\":\"$BASENAME\",\"timestamp\":$(date +%s)}"
    exit 1
fi

# 上报开始还原
if [ "$CONVERTED_FROM_ZIP" = true ]; then
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"restoring\",\"method\":\"$METHOD\",\"original_file\":\"$(basename "$RESTORE_FILE")\",\"restore_file\":\"$(basename "$FINAL_RESTORE_FILE")\",\"converted_from_zip\":true,\"timestamp\":$(date +%s)}"
else
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"restoring\",\"method\":\"$METHOD\",\"file\":\"$(basename "$FINAL_RESTORE_FILE")\",\"timestamp\":$(date +%s)}"
fi

# -----------------------------------------------------------------------------
# 执行恢复
# -----------------------------------------------------------------------------
log "开始执行备份还原操作"

# 停止当前服务
log "停止当前服务"
bash "$SERVICE_DIR/stop.sh" 2>/dev/null || true
sleep 3

# 执行还原操作
log "在容器内执行还原操作"
if proot-distro login "$PROOT_DISTRO" -- bash -c "rm -rf \"$Z2M_DATA_DIR\" && mkdir -p \"$Z2M_DATA_DIR\" && tar -xzf \"$FINAL_RESTORE_FILE\" -C \"$(dirname $Z2M_DATA_DIR)\""; then
    log "备份还原成功，重新启动服务"
    
    # 启动服务
    if ! bash "$SERVICE_DIR/start.sh"; then
        log "警告: 启动脚本返回非零状态，但继续检查服务状态"
    fi
    
    # 等待服务启动
    WAIT_TIME=30
    log "等待服务启动 (${WAIT_TIME}秒)"
    sleep "$WAIT_TIME"
    
    # 检查服务状态
    if check_service_status; then
        END_TIME=$(date +%s)
        DURATION=$((END_TIME - START_TIME))
        SIZE_KB=$(du -k "$FINAL_RESTORE_FILE" | awk '{print $1}')
        
        # 构建成功消息
        if [ "$CONVERTED_FROM_ZIP" = true ]; then
            mqtt_report "isg/restore/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"success\",\"method\":\"$METHOD\",\"original_file\":\"$(basename "$RESTORE_FILE")\",\"restore_file\":\"$(basename "$FINAL_RESTORE_FILE")\",\"size_kb\":$SIZE_KB,\"duration\":$DURATION,\"converted_from_zip\":true,\"timestamp\":$END_TIME}"
            log "还原+重启完成: $(basename "$FINAL_RESTORE_FILE") ($SIZE_KB KB, ${DURATION}秒)"
            log "原始文件: $(basename "$RESTORE_FILE")"
        else
            mqtt_report "isg/restore/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"success\",\"method\":\"$METHOD\",\"file\":\"$(basename "$FINAL_RESTORE_FILE")\",\"size_kb\":$SIZE_KB,\"duration\":$DURATION,\"timestamp\":$END_TIME}"
            log "还原+重启完成: $(basename "$FINAL_RESTORE_FILE") ($SIZE_KB KB, ${DURATION}秒)"
        fi
    else
        log "错误: 还原成功但服务未能启动"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"service failed to start after restore\",\"method\":\"$METHOD\",\"timestamp\":$(date +%s)}"
        exit 1
    fi
else
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"restore failed inside proot container\",\"timestamp\":$(date +%s)}"
    log "错误: 在proot容器内还原失败"
    exit 1
fi

log "Zigbee2MQTT还原操作完成"
exit 0

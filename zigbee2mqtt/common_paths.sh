#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Zigbee2MQTT 服务管理 - 统一路径定义和公共函数
# 版本: v1.1.0
# 说明: 所有脚本应在开头引用这些路径定义，确保一致性
# =============================================================================

# -----------------------------------------------------------------------------
# 基础标识和环境
# -----------------------------------------------------------------------------
SERVICE_ID="zigbee2mqtt"
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"

# -----------------------------------------------------------------------------
# 主要目录路径 (Termux 环境)
# -----------------------------------------------------------------------------
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"
TERMUX_VAR_DIR="/data/data/com.termux/files/usr/var"
TERMUX_TMP_DIR="/data/data/com.termux/files/usr/tmp"

# -----------------------------------------------------------------------------
# 配置文件路径
# -----------------------------------------------------------------------------
CONFIG_FILE="$BASE_DIR/configuration.yaml"
SERVICEUPDATE_FILE="$BASE_DIR/serviceupdate.json"
DETECT_SCRIPT="$BASE_DIR/detect_serial_adapters.py"
VERSION_FILE="$SERVICE_DIR/VERSION"

# -----------------------------------------------------------------------------
# 服务控制路径 (isgservicemonitor)
# -----------------------------------------------------------------------------
SERVICE_CONTROL_DIR="$TERMUX_VAR_DIR/service/$SERVICE_ID"
CONTROL_FILE="$SERVICE_CONTROL_DIR/supervise/control"
DOWN_FILE="$SERVICE_CONTROL_DIR/down"

# -----------------------------------------------------------------------------
# 日志目录和文件
# -----------------------------------------------------------------------------
LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE_INSTALL="$LOG_DIR/install.log"
LOG_FILE_START="$LOG_DIR/start.log"
LOG_FILE_STOP="$LOG_DIR/stop.log"
LOG_FILE_STATUS="$LOG_DIR/status.log"
LOG_FILE_BACKUP="$LOG_DIR/backup.log"
LOG_FILE_RESTORE="$LOG_DIR/restore.log"
LOG_FILE_UPDATE="$LOG_DIR/update.log"
LOG_FILE_UNINSTALL="$LOG_DIR/uninstall.log"
LOG_FILE_AUTOCHECK="$LOG_DIR/autocheck.log"

# -----------------------------------------------------------------------------
# 状态和锁文件
# -----------------------------------------------------------------------------
DISABLED_FLAG="$SERVICE_DIR/.disabled"
LOCK_FILE_AUTOCHECK="$SERVICE_DIR/.lock_autocheck"
LAST_CHECK_FILE="$SERVICE_DIR/.lastcheck"

# -----------------------------------------------------------------------------
# 备份相关路径
# -----------------------------------------------------------------------------
BACKUP_DIR="${BACKUP_DIR:-/sdcard/isgbackup/$SERVICE_ID}"
KEEP_BACKUPS="${KEEP_BACKUPS:-3}"
SERIAL_RESULT_FILE="/sdcard/isgbackup/serialport/latest.json"
DEFAULT_CONFIG_FILE="$BACKUP_DIR/configuration_default.yaml"
INSTALL_HISTORY_FILE="$BACKUP_DIR/.install_history"
UPDATE_HISTORY_FILE="$BACKUP_DIR/.update_history"

# -----------------------------------------------------------------------------
# 容器内路径 (Proot Ubuntu)
# -----------------------------------------------------------------------------
Z2M_INSTALL_DIR="/opt/zigbee2mqtt"
Z2M_DATA_DIR="${Z2M_DATA_DIR:-$Z2M_INSTALL_DIR/data}"
Z2M_CONFIG_FILE="$Z2M_DATA_DIR/configuration.yaml"

# -----------------------------------------------------------------------------
# 临时文件路径
# -----------------------------------------------------------------------------
TEMP_DIR="$TERMUX_TMP_DIR/${SERVICE_ID}_temp"
Z2M_VERSION_TEMP="$TERMUX_TMP_DIR/z2m_version.txt"
RESTORE_TEMP_DIR="$TERMUX_TMP_DIR/restore_temp_$$"

# -----------------------------------------------------------------------------
# 网络和端口
# -----------------------------------------------------------------------------
Z2M_PORT="8080"
MQTT_TIMEOUT="10"

# -----------------------------------------------------------------------------
# 脚本参数和配置
# -----------------------------------------------------------------------------
MAX_TRIES="${MAX_TRIES:-30}"
RETRY_INTERVAL="${RETRY_INTERVAL:-60}"
MAX_WAIT="${MAX_WAIT:-300}"
INTERVAL="${INTERVAL:-5}"
START_TIME=$(date +%s)

# -----------------------------------------------------------------------------
# 辅助函数 - 确保目录存在
# -----------------------------------------------------------------------------
ensure_directories() {
    mkdir -p "$LOG_DIR"
    mkdir -p "$BACKUP_DIR"
    mkdir -p "$(dirname "$SERIAL_RESULT_FILE")"
    
    # 确保备份目录下的历史记录文件可以被创建
    touch "$INSTALL_HISTORY_FILE" 2>/dev/null || true
    touch "$UPDATE_HISTORY_FILE" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# 辅助函数 - 加载 MQTT 配置
# -----------------------------------------------------------------------------
load_mqtt_conf() {
    MQTT_HOST=$(grep -Po '^[[:space:]]*host:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1)
    MQTT_PORT=$(grep -Po '^[[:space:]]*port:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1)
    MQTT_USER=$(grep -Po '^[[:space:]]*username:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1)
    MQTT_PASS=$(grep -Po '^[[:space:]]*password:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1)
}

# -----------------------------------------------------------------------------
# 辅助函数 - MQTT 消息发布
# -----------------------------------------------------------------------------
mqtt_report() {
    local topic="$1"
    local payload="$2"
    local log_file="${3:-$LOG_FILE}"
    
    load_mqtt_conf
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload" || true
    echo "[$(date '+%F %T')] [MQTT] $topic -> $payload" >> "$log_file"
}

# -----------------------------------------------------------------------------
# 辅助函数 - 统一日志记录
# -----------------------------------------------------------------------------
log() {
    echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"
}

# -----------------------------------------------------------------------------
# 辅助函数 - 获取 Zigbee2MQTT 进程 PID
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# 辅助函数 - 获取版本信息
# -----------------------------------------------------------------------------
get_current_version() {
    proot-distro login "$PROOT_DISTRO" -- bash -c "cd $Z2M_INSTALL_DIR && grep -m1 '\"version\"' package.json | cut -d'\"' -f4" 2>/dev/null || echo "unknown"
}

get_latest_version() {
    jq -r ".services[] | select(.id==\"$SERVICE_ID\") | .latest_service_version" "$SERVICEUPDATE_FILE" 2>/dev/null || echo "unknown"
}

get_script_version() {
    cat "$VERSION_FILE" 2>/dev/null || echo "unknown"
}

get_latest_script_version() {
    jq -r ".services[] | select(.id==\"$SERVICE_ID\") | .latest_script_version" "$SERVICEUPDATE_FILE" 2>/dev/null || echo "unknown"
}

get_upgrade_dependencies() {
    jq -c ".services[] | select(.id==\"$SERVICE_ID\") | .upgrade_dependencies" "$SERVICEUPDATE_FILE" 2>/dev/null || echo "[]"
}

# -----------------------------------------------------------------------------
# 辅助函数 - 获取安装状态
# -----------------------------------------------------------------------------
get_install_status() {
    if proot-distro login "$PROOT_DISTRO" -- test -d "$Z2M_INSTALL_DIR"; then
        if proot-distro login "$PROOT_DISTRO" -- test -f "$Z2M_INSTALL_DIR/package.json"; then
            echo "success"
        else
            echo "failed"
        fi
    else
        echo "failed"
    fi
}

# -----------------------------------------------------------------------------
# 辅助函数 - 获取运行状态
# -----------------------------------------------------------------------------
get_run_status() {
    if get_z2m_pid > /dev/null 2>&1; then
        echo "success"
    else
        echo "failed"
    fi
}

# -----------------------------------------------------------------------------
# 辅助函数 - 生成状态消息
# -----------------------------------------------------------------------------
generate_status_message() {
    local run_status="$1"
    local z2m_pid=$(get_z2m_pid || echo "")
    local uptime_seconds=0
    
    if [ -n "$z2m_pid" ]; then
        uptime_seconds=$(ps -o etimes= -p "$z2m_pid" 2>/dev/null || echo 0)
    fi
    
    local uptime_minutes=$(( uptime_seconds / 60 ))
    
    if [ "$run_status" = "success" ]; then
        if [ $uptime_minutes -lt 5 ]; then
            echo "zigbee2mqtt restarted $uptime_minutes minutes ago"
        elif [ $uptime_minutes -lt 60 ]; then
            echo "zigbee2mqtt running for $uptime_minutes minutes"
        else
            local uptime_hours=$(( uptime_minutes / 60 ))
            echo "zigbee2mqtt running for $uptime_hours hours"
        fi
    else
        echo "zigbee2mqtt is not running"
    fi
}

# -----------------------------------------------------------------------------
# 辅助函数 - 获取配置信息 (JSON格式)
# -----------------------------------------------------------------------------
get_config_info() {
    # 首先检查配置文件是否存在
    if ! proot-distro login "$PROOT_DISTRO" -- test -f "$Z2M_CONFIG_FILE"; then
        echo '{"error": "Config file not found"}'
        return
    fi
    
    # 尝试使用 Python3 + yaml 解析
    local config_json=$(proot-distro login "$PROOT_DISTRO" -- python3 -c "
import sys
try:
    import yaml
    import json
    
    with open('$Z2M_CONFIG_FILE', 'r') as f:
        config = yaml.safe_load(f)
    
    # 提取关键配置信息
    result = {
        'base_topic': config.get('mqtt', {}).get('base_topic', 'zigbee2mqtt'),
        'password': config.get('mqtt', {}).get('password', ''),
        'server': config.get('mqtt', {}).get('server', ''),
        'user': config.get('mqtt', {}).get('user', ''),
        'adapter': config.get('serial', {}).get('adapter', ''),
        'baudrate': str(config.get('serial', {}).get('baudrate', '')),
        'port': config.get('serial', {}).get('port', '')
    }
    print(json.dumps(result))
    
except ImportError as e:
    print('{\"error\": \"yaml module not available\"}')
except Exception as e:
    print('{\"error\": \"Failed to parse config: ' + str(e).replace('\"', '\\\\"') + '\"}')
" 2>/dev/null)
    
    # 如果 Python 方法失败，尝试使用 shell 命令解析 YAML
    if [ -z "$config_json" ] || [[ "$config_json" == *"error"* ]]; then
        config_json=$(proot-distro login "$PROOT_DISTRO" -- bash -c "
            if [ -f '$Z2M_CONFIG_FILE' ]; then
                # 使用 grep 和 awk 提取关键配置
                base_topic=\$(grep -A 10 '^mqtt:' '$Z2M_CONFIG_FILE' | grep 'base_topic:' | awk '{print \$2}' | tr -d '\"' || echo 'zigbee2mqtt')
                password=\$(grep -A 10 '^mqtt:' '$Z2M_CONFIG_FILE' | grep 'password:' | awk '{print \$2}' | tr -d '\"' || echo '')
                server=\$(grep -A 10 '^mqtt:' '$Z2M_CONFIG_FILE' | grep 'server:' | awk '{print \$2}' | tr -d '\"' || echo '')
                user=\$(grep -A 10 '^mqtt:' '$Z2M_CONFIG_FILE' | grep 'user:' | awk '{print \$2}' | tr -d '\"' || echo '')
                adapter=\$(grep -A 10 '^serial:' '$Z2M_CONFIG_FILE' | grep 'adapter:' | awk '{print \$2}' | tr -d '\"' || echo '')
                baudrate=\$(grep -A 10 '^serial:' '$Z2M_CONFIG_FILE' | grep 'baudrate:' | awk '{print \$2}' | tr -d '\"' || echo '')
                port=\$(grep -A 10 '^serial:' '$Z2M_CONFIG_FILE' | grep 'port:' | awk '{print \$2}' | tr -d '\"' || echo '')
                
                echo \"{\\\"base_topic\\\":\\\"\$base_topic\\\",\\\"password\\\":\\\"\$password\\\",\\\"server\\\":\\\"\$server\\\",\\\"user\\\":\\\"\$user\\\",\\\"adapter\\\":\\\"\$adapter\\\",\\\"baudrate\\\":\\\"\$baudrate\\\",\\\"port\\\":\\\"\$port\\\"}\"
            else
                echo '{\"error\": \"Config file not accessible\"}'
            fi
        " 2>/dev/null || echo '{"error": "Config not accessible"}')
    fi
    
    echo "$config_json"
}

# -----------------------------------------------------------------------------
# 辅助函数 - 记录历史
# -----------------------------------------------------------------------------
record_install_history() {
    local status="$1"
    local version="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$timestamp INSTALL $status $version" >> "$INSTALL_HISTORY_FILE"
}

record_uninstall_history() {
    local status="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$timestamp UNINSTALL $status" >> "$INSTALL_HISTORY_FILE"
}

record_update_history() {
    local status="$1"
    local old_version="$2"
    local new_version="$3"
    local reason="$4"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    if [ "$status" = "SUCCESS" ]; then
        echo "$timestamp SUCCESS $old_version -> $new_version" >> "$UPDATE_HISTORY_FILE"
    else
        echo "$timestamp FAILED $old_version -> $new_version ($reason)" >> "$UPDATE_HISTORY_FILE"
    fi
}

# -----------------------------------------------------------------------------
# 辅助函数 - 获取更新信息摘要
# -----------------------------------------------------------------------------
get_update_info() {
    local update_history="$UPDATE_HISTORY_FILE"
    if [ -f "$update_history" ]; then
        local last_update_line=$(tail -n1 "$update_history" 2>/dev/null)
        if [ -n "$last_update_line" ]; then
            local update_date=$(echo "$last_update_line" | awk '{print $1}')
            local update_time=$(echo "$last_update_line" | awk '{print $2}')
            local update_status=$(echo "$last_update_line" | awk '{print $3}')
            local version_info=$(echo "$last_update_line" | cut -d' ' -f4-)
            
            local update_timestamp=$(date -d "$update_date $update_time" +%s 2>/dev/null || echo 0)
            local current_time=$(date +%s)
            local time_diff=$((current_time - update_timestamp))
            
            if [ $time_diff -lt 3600 ]; then
                local minutes=$(( time_diff / 60 ))
                echo "$update_status $minutes minutes ago ($version_info)"
            elif [ $time_diff -lt 86400 ]; then
                local hours=$(( time_diff / 3600 ))
                echo "$update_status $hours hours ago ($version_info)"
            else
                local days=$(( time_diff / 86400 ))
                echo "$update_status $days days ago ($version_info)"
            fi
        else
            echo "update history empty"
        fi
    else
        echo "never updated"
    fi
}

# -----------------------------------------------------------------------------
# 辅助函数 - 检查容器可用性
# -----------------------------------------------------------------------------
check_proot_container() {
    if ! proot-distro login "$PROOT_DISTRO" -- echo "test" >/dev/null 2>&1; then
        log "proot container $PROOT_DISTRO not available"
        return 1
    fi
    return 0
}
get_script_status() {
    local script_name="$1"
    local script_path="$SERVICE_DIR/$script_name"
    
    # 检查是否有对应的锁文件或进程
    case "$script_name" in
        "install.sh")
            if pgrep -f "$script_path" > /dev/null 2>&1; then
                echo "installing"
            else
                echo "success"
            fi
            ;;
        "update.sh")
            if pgrep -f "$script_path" > /dev/null 2>&1; then
                echo "updating"
            else
                echo "success"
            fi
            ;;
        "backup.sh")
            if pgrep -f "$script_path" > /dev/null 2>&1; then
                echo "backuping"
            else
                echo "success"
            fi
            ;;
        "restore.sh")
            if pgrep -f "$script_path" > /dev/null 2>&1; then
                echo "restoring"
            else
                echo "success"
            fi
            ;;
        "uninstall.sh")
            if pgrep -f "$script_path" > /dev/null 2>&1; then
                echo "uninstalling"
            else
                echo "success"
            fi
            ;;
        *)
            echo "success"
            ;;
    esac
}

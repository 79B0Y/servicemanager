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
    
    case "$run_status" in
        "running")
            if [ $uptime_minutes -lt 5 ]; then
                echo "zigbee2mqtt restarted $uptime_minutes minutes ago"
            elif [ $uptime_minutes -lt 60 ]; then
                echo "zigbee2mqtt running for $uptime_minutes minutes"
            else
                local uptime_hours=$(( uptime_minutes / 60 ))
                echo "zigbee2mqtt running for $uptime_hours hours"
            fi
            ;;
        "starting")
            echo "zigbee2mqtt is starting up"
            ;;
        "stopping")
            echo "zigbee2mqtt is stopping"
            ;;
        "stopped")
            echo "zigbee2mqtt is not running"
            ;;
        "failed")
            echo "zigbee2mqtt failed to start"
            ;;
        *)
            echo "zigbee2mqtt status unknown"
            ;;
    esac
}

# -----------------------------------------------------------------------------
# 辅助函数 - 获取配置信息 (JSON格式)
# -----------------------------------------------------------------------------
get_config_info() {
    if ! proot-distro login "$PROOT_DISTRO" -- test -f "$Z2M_CONFIG_FILE"; then
        echo '{"error": "Config file not found"}'
        return
    fi
    
    local config_json=$(proot-distro login "$PROOT_DISTRO" -- python3 -c "
import sys
try:
    import yaml
    import json
    
    with open('$Z2M_CONFIG_FILE', 'r') as f:
        config = yaml.safe_load(f)
    
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
    
except ImportError:
    print('{\"error\": \"yaml module not available\"}')
except Exception as e:
    print('{\"error\": \"Failed to parse config\"}')
" 2>/dev/null)
    
    if [ -z "$config_json" ] || [[ "$config_json" == *"error"* ]]; then
        config_json=$(proot-distro login "$PROOT_DISTRO" -- bash -c "
            if [ -f '$Z2M_CONFIG_FILE' ]; then
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
# 辅助函数 - 检查各脚本的实际状态
# -----------------------------------------------------------------------------
get_script_status() {
    local script_name="$1"
    local script_path="$SERVICE_DIR/$script_name"
    
    case "$script_name" in
        "install.sh")
            if pgrep -f "$script_path" > /dev/null 2>&1; then
                echo "installing"
            elif pgrep -f "$SERVICE_DIR/uninstall.sh" > /dev/null 2>&1; then
                echo "uninstalling"
            else
                if proot-distro login "$PROOT_DISTRO" -- test -d "$Z2M_INSTALL_DIR" && \
                   proot-distro login "$PROOT_DISTRO" -- test -f "$Z2M_INSTALL_DIR/package.json"; then
                    echo "success"
                else
                    echo "failed"
                fi
            fi
            ;;
        "backup.sh")
            if pgrep -f "$script_path" > /dev/null 2>&1; then
                echo "backuping"
            else
                local latest_backup=$(ls -1t "$BACKUP_DIR"/zigbee2mqtt_backup_*.tar.gz 2>/dev/null | head -n1 || true)
                if [ -n "$latest_backup" ] && [ -f "$latest_backup" ]; then
                    echo "success"
                else
                    if [ -f "$LOG_FILE_BACKUP" ] && [ -s "$LOG_FILE_BACKUP" ]; then
                        if tail -10 "$LOG_FILE_BACKUP" 2>/dev/null | grep -q "backup skipped"; then
                            echo "skipped"
                        elif tail -10 "$LOG_FILE_BACKUP" 2>/dev/null | grep -q "backup completed"; then
                            echo "success"
                        elif tail -10 "$LOG_FILE_BACKUP" 2>/dev/null | grep -q "backup.*failed\|failed.*backup"; then
                            echo "failed"
                        else
                            echo "never"
                        fi
                    else
                        echo "never"
                    fi
                fi
            fi
            ;;
        "restore.sh")
            if pgrep -f "$script_path" > /dev/null 2>&1; then
                echo "restoring"
            else
                if [ -f "$LOG_FILE_RESTORE" ] && [ -s "$LOG_FILE_RESTORE" ]; then
                    if tail -10 "$LOG_FILE_RESTORE" 2>/dev/null | grep -q "restore.*complete\|configuration generated.*successfully"; then
                        echo "success"
                    elif tail -10 "$LOG_FILE_RESTORE" 2>/dev/null | grep -q "restore.*skipped\|backup.*skipped"; then
                        echo "skipped"
                    elif tail -10 "$LOG_FILE_RESTORE" 2>/dev/null | grep -q "restore.*failed\|failed.*restore"; then
                        echo "failed"
                    else
                        echo "never"
                    fi
                else
                    if proot-distro login "$PROOT_DISTRO" -- test -f "$Z2M_CONFIG_FILE"; then
                        echo "success"
                    else
                        echo "never"
                    fi
                fi
            fi
            ;;
        "update.sh")
            if pgrep -f "$script_path" > /dev/null 2>&1; then
                echo "updating"
            else
                if [ -f "$UPDATE_HISTORY_FILE" ] && [ -s "$UPDATE_HISTORY_FILE" ]; then
                    local last_update_line=$(tail -n1 "$UPDATE_HISTORY_FILE" 2>/dev/null)
                    if [ -n "$last_update_line" ]; then
                        if echo "$last_update_line" | grep -q "SUCCESS"; then
                            echo "success"
                        elif echo "$last_update_line" | grep -q "FAILED"; then
                            echo "failed"
                        else
                            echo "never"
                        fi
                    else
                        echo "never"
                    fi
                else
                    echo "never"
                fi
            fi
            ;;
        *)
            echo "success"
            ;;
    esac
}

# -----------------------------------------------------------------------------
# 新增辅助函数 - 改进的状态检查
# -----------------------------------------------------------------------------

# 检查进程状态的改进版本
check_script_process() {
    local script_name="$1"
    local script_path="$SERVICE_DIR/$script_name"
    
    if pgrep -f "$script_path" > /dev/null 2>&1; then
        return 0  # 进程存在
    else
        return 1  # 进程不存在
    fi
}

# 读取历史记录的最后状态
get_last_history_status() {
    local history_file="$1"
    local operation_type="$2"  # INSTALL, UNINSTALL, UPDATE 等
    
    if [ -f "$history_file" ] && [ -s "$history_file" ]; then
        local last_line=$(tail -n1 "$history_file" 2>/dev/null)
        if [ -n "$last_line" ]; then
            echo "$last_line"
        else
            echo "empty"
        fi
    else
        echo "no_history"
    fi
}

# 检查备份文件数量
count_backup_files() {
    local backup_pattern="$BACKUP_DIR/zigbee2mqtt_backup_*.tar.gz"
    local count=$(ls -1 $backup_pattern 2>/dev/null | wc -l)
    echo "${count:-0}"
}

# 获取最新备份文件信息
get_latest_backup_info() {
    local latest_backup=$(ls -1t "$BACKUP_DIR"/zigbee2mqtt_backup_*.tar.gz 2>/dev/null | head -n1 || echo "")
    
    if [ -n "$latest_backup" ] && [ -f "$latest_backup" ]; then
        local file_size=$(du -k "$latest_backup" | awk '{print $1}')
        local file_date=$(stat -c %Y "$latest_backup" 2>/dev/null || echo 0)
        local current_time=$(date +%s)
        local age_hours=$(( (current_time - file_date) / 3600 ))
        
        echo "{\"file\":\"$(basename "$latest_backup")\",\"size_kb\":$file_size,\"age_hours\":$age_hours}"
    else
        echo "{\"file\":null,\"size_kb\":0,\"age_hours\":0}"
    fi
}

# 检查日志文件中的最近状态
get_recent_log_status() {
    local log_file="$1"
    local success_pattern="$2"
    local failed_pattern="$3"
    local skipped_pattern="$4"
    
    if [ -f "$log_file" ] && [ -s "$log_file" ]; then
        local recent_log=$(tail -20 "$log_file" 2>/dev/null)
        
        if echo "$recent_log" | grep -q "$success_pattern"; then
            echo "success"
        elif echo "$recent_log" | grep -q "$failed_pattern"; then
            echo "failed"
        elif [ -n "$skipped_pattern" ] && echo "$recent_log" | grep -q "$skipped_pattern"; then
            echo "skipped"
        else
            echo "unknown"
        fi
    else
        echo "no_log"
    fi
}

# 综合状态评估
evaluate_overall_status() {
    local run_status="$1"
    local install_status="$2"
    local bridge_state="$3"
    
    # 如果是禁用状态
    if [ -f "$DISABLED_FLAG" ]; then
        echo "disabled"
        return
    fi
    
    # 如果安装失败或未安装
    if [ "$install_status" = "failed" ] || [ "$install_status" = "never" ] || [ "$install_status" = "uninstalled" ]; then
        echo "problem"
        return
    fi
    
    # 如果运行失败
    if [ "$run_status" = "failed" ] || [ "$run_status" = "stopped" ]; then
        echo "problem"
        return
    fi
    
    # 如果服务运行但桥接离线
    if [ "$run_status" = "running" ] && [ "$bridge_state" = "offline" ]; then
        echo "problem"
        return
    fi
    
    # 正在进行操作的状态
    if [[ "$run_status" =~ ^(starting|stopping)$ ]] || [[ "$install_status" =~ ^(installing|uninstalling)$ ]]; then
        echo "healthy"
        return
    fi
    
    # 默认健康状态
    echo "healthy"
}

# 获取进程运行时长描述
get_process_uptime_description() {
    local pid="$1"
    
    if [ -z "$pid" ]; then
        echo "not running"
        return
    fi
    
    local uptime_seconds=$(ps -o etimes= -p "$pid" 2>/dev/null | head -n1 | awk '{print $1}' || echo 0)
    uptime_seconds=$(echo "$uptime_seconds" | tr -d '\n\r\t ' | grep -o '^[0-9]*' || echo 0)
    uptime_seconds=${uptime_seconds:-0}
    local uptime_minutes=$(( uptime_seconds / 60 ))
    local uptime_hours=$(( uptime_minutes / 60 ))
    local uptime_days=$(( uptime_hours / 24 ))
    
    if [ $uptime_seconds -lt 60 ]; then
        echo "${uptime_seconds} seconds"
    elif [ $uptime_minutes -lt 60 ]; then
        echo "${uptime_minutes} minutes"
    elif [ $uptime_hours -lt 24 ]; then
        echo "${uptime_hours} hours"
    else
        echo "${uptime_days} days"
    fi
}

# 生成详细的状态报告
generate_detailed_status_report() {
    local run_status="$1"
    local install_status="$2"
    local backup_status="$3"
    local update_status="$4"
    local restore_status="$5"
    
    local report="Status Report:\n"
    report="$report  - Run: $run_status\n"
    report="$report  - Install: $install_status\n"
    report="$report  - Backup: $backup_status\n"
    report="$report  - Update: $update_status\n"
    report="$report  - Restore: $restore_status"
    
    echo -e "$report"
}

# -----------------------------------------------------------------------------
# 改进的状态检查函数 - 用于autocheck.sh
# -----------------------------------------------------------------------------

# 改进的 RUN 状态检查
get_improved_run_status() {
    # 检查是否有 start.sh 进程在运行
    if pgrep -f "$SERVICE_DIR/start.sh" > /dev/null 2>&1; then
        echo "starting"
        return
    fi
    
    # 检查是否有 stop.sh 进程在运行
    if pgrep -f "$SERVICE_DIR/stop.sh" > /dev/null 2>&1; then
        echo "stopping"
        return
    fi
    
    # 调用 status.sh 检查实际运行状态
    if bash "$SERVICE_DIR/status.sh" --quiet; then
        echo "running"
    else
        echo "stopped"
    fi
}

# 改进的 INSTALL 状态检查
get_improved_install_status() {
    # 检查是否有 install.sh 进程在运行
    if pgrep -f "$SERVICE_DIR/install.sh" > /dev/null 2>&1; then
        echo "installing"
        return
    fi
    
    # 检查是否有 uninstall.sh 进程在运行
    if pgrep -f "$SERVICE_DIR/uninstall.sh" > /dev/null 2>&1; then
        echo "uninstalling"
        return
    fi
    
    # 检查安装历史记录
    if [ -f "$INSTALL_HISTORY_FILE" ] && [ -s "$INSTALL_HISTORY_FILE" ]; then
        # 读取最后一行安装记录
        local last_install_line=$(tail -n1 "$INSTALL_HISTORY_FILE" 2>/dev/null)
        if [ -n "$last_install_line" ]; then
            # 优先检查卸载记录
            if echo "$last_install_line" | grep -q "UNINSTALL SUCCESS"; then
                echo "uninstalled"
                return
            elif echo "$last_install_line" | grep -q "INSTALL SUCCESS"; then
                # 虽然历史记录说安装成功，但需要验证实际状态
                if proot-distro login "$PROOT_DISTRO" -- test -d "$Z2M_INSTALL_DIR" 2>/dev/null && \
                   proot-distro login "$PROOT_DISTRO" -- test -f "$Z2M_INSTALL_DIR/package.json" 2>/dev/null; then
                    echo "success"
                else
                    echo "uninstalled"  # 历史说成功但实际不存在，说明被卸载了
                fi
                return
            elif echo "$last_install_line" | grep -q "INSTALL FAILED"; then
                echo "failed"
                return
            fi
        fi
    fi
    
    # 没有历史记录，检查实际安装状态
    if proot-distro login "$PROOT_DISTRO" -- test -d "$Z2M_INSTALL_DIR" 2>/dev/null && \
       proot-distro login "$PROOT_DISTRO" -- test -f "$Z2M_INSTALL_DIR/package.json" 2>/dev/null; then
        echo "success"
    else
        echo "never"
    fi
}

# 改进的 BACKUP 状态检查
get_improved_backup_status() {
    # 检查是否有 backup.sh 进程在运行
    if pgrep -f "$SERVICE_DIR/backup.sh" > /dev/null 2>&1; then
        echo "backuping"
        return
    fi
    
    # 检查备份目录是否有备份文件
    local backup_files=$(ls -1 "$BACKUP_DIR"/zigbee2mqtt_backup_*.tar.gz 2>/dev/null | wc -l)
    # 确保backup_files是数字
    backup_files=${backup_files:-0}
    
    if [ "$backup_files" -gt 0 ]; then
        # 有备份文件，检查最近的备份状态
        if [ -f "$LOG_FILE_BACKUP" ] && [ -s "$LOG_FILE_BACKUP" ]; then
            # 检查最近的日志记录
            local recent_log=$(tail -10 "$LOG_FILE_BACKUP" 2>/dev/null)
            if echo "$recent_log" | grep -q "backup skipped"; then
                echo "skipped"
            elif echo "$recent_log" | grep -q "backup completed.*successfully"; then
                echo "success"
            elif echo "$recent_log" | grep -q "backup.*failed\|failed.*backup"; then
                echo "failed"
            else
                echo "success"  # 有备份文件默认认为成功
            fi
        else
            echo "success"  # 有备份文件但无日志，默认成功
        fi
    else
        echo "never"  # 没有备份文件
    fi
}

# 改进的 UPDATE 状态检查
get_improved_update_status() {
    # 检查是否有 update.sh 进程在运行
    if pgrep -f "$SERVICE_DIR/update.sh" > /dev/null 2>&1; then
        echo "updating"
        return
    fi
    
    # 检查更新历史记录
    if [ -f "$UPDATE_HISTORY_FILE" ] && [ -s "$UPDATE_HISTORY_FILE" ]; then
        local last_update_line=$(tail -n1 "$UPDATE_HISTORY_FILE" 2>/dev/null)
        if [ -n "$last_update_line" ]; then
            if echo "$last_update_line" | grep -q "SUCCESS"; then
                echo "success"
            elif echo "$last_update_line" | grep -q "FAILED"; then
                echo "failed"
            else
                echo "never"
            fi
        else
            echo "never"
        fi
    else
        echo "never"  # 没有更新历史记录
    fi
}

# 改进的 RESTORE 状态检查
get_improved_restore_status() {
    # 检查是否有 restore.sh 进程在运行
    if pgrep -f "$SERVICE_DIR/restore.sh" > /dev/null 2>&1; then
        echo "restoring"
        return
    fi
    
    # 检查还原日志
    if [ -f "$LOG_FILE_RESTORE" ] && [ -s "$LOG_FILE_RESTORE" ]; then
        local recent_log=$(tail -10 "$LOG_FILE_RESTORE" 2>/dev/null)
        if echo "$recent_log" | grep -q "restore.*complete\|configuration generated.*successfully"; then
            echo "success"
        elif echo "$recent_log" | grep -q "restore.*skipped\|backup.*skipped"; then
            echo "skipped"
        elif echo "$recent_log" | grep -q "restore.*failed\|failed.*restore"; then
            echo "failed"
        else
            # 如果有配置文件，认为还原成功
            if proot-distro login "$PROOT_DISTRO" -- test -f "$Z2M_CONFIG_FILE"; then
                echo "success"
            else
                echo "never"
            fi
        fi
    else
        # 没有还原日志，检查配置文件
        if proot-distro login "$PROOT_DISTRO" -- test -f "$Z2M_CONFIG_FILE"; then
            echo "success"
        else
            echo "never"
        fi
    fi
}

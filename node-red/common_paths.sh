#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Node-RED 服务管理 - 统一路径定义和公共函数
# 版本: v1.1.0
# 说明: 所有脚本应在开头引用这些路径定义，确保一致性
# =============================================================================

# -----------------------------------------------------------------------------
# 基础标识和环境
# -----------------------------------------------------------------------------
SERVICE_ID="node-red"
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"

# -----------------------------------------------------------------------------
# 主要目录路径 (Termux 环境)
# -----------------------------------------------------------------------------
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"
TERMUX_VAR_DIR="/data/data/com.termux/files/usr/var"
TERMUX_TMP_DIR="/data/data/com.termux/files/usr/tmp"
PREFIX="/data/data/com.termux/files/usr"

# -----------------------------------------------------------------------------
# 配置文件路径
# -----------------------------------------------------------------------------
CONFIG_FILE="$BASE_DIR/configuration.yaml"
SERVICEUPDATE_FILE="$BASE_DIR/serviceupdate.json"
VERSION_FILE="$SERVICE_DIR/VERSION"

# -----------------------------------------------------------------------------
# 服务控制路径 (isgservicemonitor)
# -----------------------------------------------------------------------------
SERVICE_CONTROL_DIR="$TERMUX_VAR_DIR/service/$SERVICE_ID"
CONTROL_FILE="$SERVICE_CONTROL_DIR/supervise/control"
DOWN_FILE="$SERVICE_CONTROL_DIR/down"
RUN_SCRIPT="$SERVICE_CONTROL_DIR/run"

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
DEFAULT_CONFIG_FILE="$BACKUP_DIR/flows_default.json"
INSTALL_HISTORY_FILE="$BACKUP_DIR/.install_history"
UPDATE_HISTORY_FILE="$BACKUP_DIR/.update_history"

# -----------------------------------------------------------------------------
# 容器内路径 (Proot Ubuntu)
# -----------------------------------------------------------------------------
NODE_RED_GLOBAL_DIR="/root/.pnpm-global"
NODE_RED_DATA_DIR="${NODE_RED_DATA_DIR:-/root/.node-red}"
NODE_RED_FLOWS_FILE="$NODE_RED_DATA_DIR/flows.json"
NODE_RED_SETTINGS_FILE="$NODE_RED_DATA_DIR/settings.js"
NODE_RED_PACKAGE_JSON="$NODE_RED_GLOBAL_DIR/global/5/node_modules/node-red/package.json"

# -----------------------------------------------------------------------------
# 临时文件路径
# -----------------------------------------------------------------------------
TEMP_DIR="$TERMUX_TMP_DIR/${SERVICE_ID}_temp"
NODE_RED_VERSION_TEMP="$TERMUX_TMP_DIR/node_red_version.txt"
RESTORE_TEMP_DIR="$TERMUX_TMP_DIR/restore_temp_$$"

# -----------------------------------------------------------------------------
# 网络和端口
# -----------------------------------------------------------------------------
NODE_RED_PORT="1880"
HTTP_TIMEOUT="10"

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
    mkdir -p "$SERVICE_CONTROL_DIR/supervise"
    
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
# 辅助函数 - 获取 Node-RED 进程 PID
# -----------------------------------------------------------------------------
get_node_red_pid() {
    local port_pid=$(netstat -tnlp 2>/dev/null | grep ":$NODE_RED_PORT " | awk '{print $7}' | cut -d'/' -f1 | head -n1)
    
    if [ -n "$port_pid" ] && [ "$port_pid" != "-" ]; then
        local cmdline=$(cat /proc/$port_pid/cmdline 2>/dev/null | tr '\0' ' ')
        if echo "$cmdline" | grep -q "node-red"; then
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
    if proot-distro login "$PROOT_DISTRO" -- test -f "$NODE_RED_PACKAGE_JSON"; then
        proot-distro login "$PROOT_DISTRO" -- bash -c "cat $NODE_RED_PACKAGE_JSON | grep '\"version\"' | sed -E 's/.*\"version\": *\"([^\"]+)\".*/\1/'" 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
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
    if proot-distro login "$PROOT_DISTRO" -- test -f "$NODE_RED_PACKAGE_JSON"; then
        echo "success"
    else
        echo "failed"
    fi
}

# -----------------------------------------------------------------------------
# 辅助函数 - 获取运行状态
# -----------------------------------------------------------------------------
get_run_status() {
    if get_node_red_pid > /dev/null 2>&1; then
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
    local node_red_pid=$(get_node_red_pid || echo "")
    local uptime_seconds=0
    
    if [ -n "$node_red_pid" ]; then
        uptime_seconds=$(ps -o etimes= -p "$node_red_pid" 2>/dev/null || echo 0)
    fi
    
    local uptime_minutes=$(( uptime_seconds / 60 ))
    
    case "$run_status" in
        "running")
            if [ $uptime_minutes -lt 5 ]; then
                echo "node-red restarted $uptime_minutes minutes ago"
            elif [ $uptime_minutes -lt 60 ]; then
                echo "node-red running for $uptime_minutes minutes"
            else
                local uptime_hours=$(( uptime_minutes / 60 ))
                echo "node-red running for $uptime_hours hours"
            fi
            ;;
        "starting")
            echo "node-red is starting up"
            ;;
        "stopping")
            echo "node-red is stopping"
            ;;
        "stopped")
            echo "node-red is not running"
            ;;
        "failed")
            echo "node-red failed to start"
            ;;
        *)
            echo "node-red status unknown"
            ;;
    esac
}

# -----------------------------------------------------------------------------
# 辅助函数 - 获取配置信息 (JSON格式)
# -----------------------------------------------------------------------------
get_config_info() {
    if ! proot-distro login "$PROOT_DISTRO" -- test -f "$NODE_RED_SETTINGS_FILE"; then
        echo '{"error": "Settings file not found"}'
        return
    fi
    
    local config_json=$(proot-distro login "$PROOT_DISTRO" -- bash -c "
        if [ -f '$NODE_RED_SETTINGS_FILE' ]; then
            port=\$(grep -o 'uiPort.*[0-9]*' '$NODE_RED_SETTINGS_FILE' | grep -o '[0-9]*' || echo '1880')
            httpAdminRoot=\$(grep -o 'httpAdminRoot.*[\"'\"'].*[\"'\"']' '$NODE_RED_SETTINGS_FILE' | cut -d'\"' -f2 || echo '/')
            flowFile=\$(grep -o 'flowFile.*[\"'\"'].*[\"'\"']' '$NODE_RED_SETTINGS_FILE' | cut -d'\"' -f2 || echo 'flows.json')
            userDir=\$(grep -o 'userDir.*[\"'\"'].*[\"'\"']' '$NODE_RED_SETTINGS_FILE' | cut -d'\"' -f2 || echo '/root/.node-red')
            
            echo \"{\\\"port\\\":\\\"\$port\\\",\\\"httpAdminRoot\\\":\\\"\$httpAdminRoot\\\",\\\"flowFile\\\":\\\"\$flowFile\\\",\\\"userDir\\\":\\\"\$userDir\\\"}\"
        else
            echo '{\"error\": \"Settings file not accessible\"}'
        fi
    " 2>/dev/null || echo '{"error": "Settings not accessible"}')
    
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
                if proot-distro login "$PROOT_DISTRO" -- test -f "$NODE_RED_PACKAGE_JSON"; then
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
                local latest_backup=$(ls -1t "$BACKUP_DIR"/node-red_backup_*.tar.gz 2>/dev/null | head -n1 || true)
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
                    if proot-distro login "$PROOT_DISTRO" -- test -f "$NODE_RED_DATA_DIR"; then
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
                if proot-distro login "$PROOT_DISTRO" -- test -f "$NODE_RED_PACKAGE_JSON" 2>/dev/null; then
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
    if proot-distro login "$PROOT_DISTRO" -- test -f "$NODE_RED_PACKAGE_JSON" 2>/dev/null; then
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
    local backup_files=$(ls -1 "$BACKUP_DIR"/node-red_backup_*.tar.gz 2>/dev/null | wc -l)
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
            # 如果有数据目录，认为还原成功
            if proot-distro login "$PROOT_DISTRO" -- test -d "$NODE_RED_DATA_DIR"; then
                echo "success"
            else
                echo "never"
            fi
        fi
    else
        # 没有还原日志，检查数据目录
        if proot-distro login "$PROOT_DISTRO" -- test -d "$NODE_RED_DATA_DIR"; then
            echo "success"
        else
            echo "never"
        fi
    fi
}

#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Mosquitto 服务管理 - 统一路径定义和公共函数
# 版本: v1.1.1
# 说明: 所有脚本应在开头引用这些路径定义，确保一致性
# 修复: 添加IPv4监听支持，MQTT维护功能，增强配置管理函数
# =============================================================================

# -----------------------------------------------------------------------------
# 基础标识和环境
# -----------------------------------------------------------------------------
SERVICE_ID="mosquitto"

# -----------------------------------------------------------------------------
# 主要目录路径 (Termux 环境)
# -----------------------------------------------------------------------------
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"
TERMUX_VAR_DIR="/data/data/com.termux/files/usr/var"
TERMUX_TMP_DIR="/data/data/com.termux/files/usr/tmp"
TERMUX_ETC_DIR="/data/data/com.termux/files/usr/etc"

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
RUN_FILE="$SERVICE_CONTROL_DIR/run"

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
INSTALL_HISTORY_FILE="$BACKUP_DIR/.install_history"
UPDATE_HISTORY_FILE="$BACKUP_DIR/.update_history"

# -----------------------------------------------------------------------------
# Mosquitto 相关路径
# -----------------------------------------------------------------------------
MOSQUITTO_CONF_DIR="$TERMUX_ETC_DIR/mosquitto"
MOSQUITTO_CONF_FILE="$MOSQUITTO_CONF_DIR/mosquitto.conf"
MOSQUITTO_PASSWD_FILE="$MOSQUITTO_CONF_DIR/passwd"
MOSQUITTO_LOG_DIR="$TERMUX_VAR_DIR/log/mosquitto"
MOSQUITTO_PID_FILE="$TERMUX_VAR_DIR/run/mosquitto.pid"

# -----------------------------------------------------------------------------
# 临时文件路径
# -----------------------------------------------------------------------------
TEMP_DIR="$TERMUX_TMP_DIR/${SERVICE_ID}_temp"
MOSQUITTO_VERSION_TEMP="$TERMUX_TMP_DIR/mosquitto_version.txt"

# -----------------------------------------------------------------------------
# 网络和端口
# -----------------------------------------------------------------------------
MOSQUITTO_PORT="1883"
MOSQUITTO_WS_PORT="9001"
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
    mkdir -p "$MOSQUITTO_LOG_DIR"
    mkdir -p "$MOSQUITTO_CONF_DIR"
    mkdir -p "$TEMP_DIR"
    
    # 确保备份目录下的历史记录文件可以被创建
    touch "$INSTALL_HISTORY_FILE" 2>/dev/null || true
    touch "$UPDATE_HISTORY_FILE" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# 辅助函数 - 日志记录
# -----------------------------------------------------------------------------
log() {
    local level="${2:-INFO}"
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

log_error() {
    log "$1" "ERROR"
}

log_warn() {
    log "$1" "WARN"
}

log_debug() {
    if [ "${DEBUG:-false}" = "true" ]; then
        log "$1" "DEBUG"
    fi
}

# -----------------------------------------------------------------------------
# 辅助函数 - 加载 MQTT 配置
# -----------------------------------------------------------------------------
load_mqtt_conf() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "Configuration file not found: $CONFIG_FILE"
        return 1
    fi
    
    MQTT_HOST=$(grep -Po '^[[:space:]]*host:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1)
    MQTT_PORT=$(grep -Po '^[[:space:]]*port:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1)
    MQTT_USER=$(grep -Po '^[[:space:]]*username:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1)
    MQTT_PASS=$(grep -Po '^[[:space:]]*password:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1)
    
    # 设置默认值
    MQTT_HOST="${MQTT_HOST:-127.0.0.1}"
    MQTT_PORT="${MQTT_PORT:-1883}"
    MQTT_USER="${MQTT_USER:-admin}"
    MQTT_PASS="${MQTT_PASS:-admin}"
}

# -----------------------------------------------------------------------------
# 辅助函数 - MQTT 消息发布（智能重试）
# -----------------------------------------------------------------------------
mqtt_report() {
    local topic="$1"
    local payload="$2"
    local retries="${3:-3}"
    local log_file="${4:-$LOG_FILE}"
    
    # 加载MQTT配置
    if ! load_mqtt_conf; then
        log_error "Failed to load MQTT configuration"
        return 1
    fi
    
    local attempt=1
    while [ $attempt -le $retries ]; do
        if timeout 10 mosquitto_pub \
            -h "$MQTT_HOST" \
            -p "$MQTT_PORT" \
            -u "$MQTT_USER" \
            -P "$MQTT_PASS" \
            -t "$topic" \
            -m "$payload" 2>/dev/null; then
            
            echo "[$(date '+%F %T')] [MQTT] $topic -> $payload" >> "$log_file"
            return 0
        else
            log_debug "MQTT publish failed (attempt $attempt/$retries): $topic"
            attempt=$((attempt + 1))
            sleep 2
        fi
    done
    
    log_debug "MQTT publish failed after $retries attempts: $topic"
    return 1
}

# -----------------------------------------------------------------------------
# 辅助函数 - 获取 Mosquitto 进程 PID（增强版）
# -----------------------------------------------------------------------------
get_mosquitto_pid() {
    # 方法1: 通过IPv4端口反查进程（优先）
    local port_pid=$(netstat -tnlp 2>/dev/null | grep "0.0.0.0:$MOSQUITTO_PORT " | awk '{print $7}' | cut -d'/' -f1 | head -n1)
    
    if [ -n "$port_pid" ] && [ "$port_pid" != "-" ]; then
        # 验证进程是否确实是 mosquitto
        local process_name=$(ps -p "$port_pid" -o comm= 2>/dev/null)
        if [[ "$process_name" == *"mosquitto"* ]]; then
            echo "$port_pid"
            return 0
        fi
    fi
    
    # 方法2: 通过任意1883端口反查进程
    port_pid=$(netstat -tnlp 2>/dev/null | grep ":$MOSQUITTO_PORT " | awk '{print $7}' | cut -d'/' -f1 | head -n1)
    
    if [ -n "$port_pid" ] && [ "$port_pid" != "-" ]; then
        # 验证进程是否确实是 mosquitto
        local process_name=$(ps -p "$port_pid" -o comm= 2>/dev/null)
        if [[ "$process_name" == *"mosquitto"* ]]; then
            echo "$port_pid"
            return 0
        fi
    fi
    
    # 方法3: 直接查找 mosquitto 进程
    local mosquitto_pid=$(pgrep -f "mosquitto.*mosquitto.conf" | head -n1)
    if [ -n "$mosquitto_pid" ]; then
        echo "$mosquitto_pid"
        return 0
    fi
    
    # 方法4: 通过配置文件查找
    local config_pid=$(pgrep -f "$MOSQUITTO_CONF_FILE" | head -n1)
    if [ -n "$config_pid" ]; then
        # 再次验证是否是mosquitto进程
        local cmd_line=$(ps -p "$config_pid" -o args= 2>/dev/null)
        if [[ "$cmd_line" == *"mosquitto"* ]]; then
            echo "$config_pid"
            return 0
        fi
    fi
    
    return 1
}

# -----------------------------------------------------------------------------
# 辅助函数 - 端口检测（IPv4优化）
# -----------------------------------------------------------------------------
check_port_listening() {
    local port="$1"
    local timeout="${2:-5}"
    local check_ipv4="${3:-false}"
    
    # 优先检查IPv4监听
    if [ "$check_ipv4" = "true" ]; then
        if netstat -tnl 2>/dev/null | grep -q "0.0.0.0:$port "; then
            return 0
        fi
    fi
    
    # 方法1: netstat检查任意监听
    if netstat -tnl 2>/dev/null | grep -q ":$port "; then
        return 0
    fi
    
    # 方法2: ss命令检查（如果可用）
    if command -v ss >/dev/null 2>&1; then
        if ss -tnl 2>/dev/null | grep -q ":$port "; then
            return 0
        fi
    fi
    
    # 方法3: nc连接测试
    if command -v nc >/dev/null 2>&1; then
        if timeout "$timeout" nc -z 127.0.0.1 "$port" 2>/dev/null; then
            return 0
        fi
    fi
    
    return 1
}

# -----------------------------------------------------------------------------
# 辅助函数 - IPv4监听检查
# -----------------------------------------------------------------------------
check_ipv4_listening() {
    local port="$1"
    if netstat -tnl 2>/dev/null | grep -q "0.0.0.0:$port "; then
        return 0
    fi
    return 1
}

# -----------------------------------------------------------------------------
# 辅助函数 - 获取版本信息
# -----------------------------------------------------------------------------
get_current_version() {
    if command -v mosquitto >/dev/null 2>&1; then
        mosquitto -h 2>/dev/null | grep -i 'version' | awk '{print $3}' 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
}

get_latest_version() {
    if [ -f "$SERVICEUPDATE_FILE" ]; then
        jq -r ".services[] | select(.id==\"$SERVICE_ID\") | .latest_service_version" "$SERVICEUPDATE_FILE" 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
}

get_script_version() {
    if [ -f "$VERSION_FILE" ]; then
        cat "$VERSION_FILE" 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
}

get_latest_script_version() {
    if [ -f "$SERVICEUPDATE_FILE" ]; then
        jq -r ".services[] | select(.id==\"$SERVICE_ID\") | .latest_script_version" "$SERVICEUPDATE_FILE" 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
}

get_upgrade_dependencies() {
    if [ -f "$SERVICEUPDATE_FILE" ]; then
        jq -c ".services[] | select(.id==\"$SERVICE_ID\") | .upgrade_dependencies" "$SERVICEUPDATE_FILE" 2>/dev/null || echo "[]"
    else
        echo "[]"
    fi
}

# -----------------------------------------------------------------------------
# 辅助函数 - 获取安装状态
# -----------------------------------------------------------------------------
get_install_status() {
    if command -v mosquitto >/dev/null 2>&1; then
        if [ -f "$MOSQUITTO_CONF_FILE" ]; then
            echo "success"
        else
            echo "partial"
        fi
    else
        echo "failed"
    fi
}

# -----------------------------------------------------------------------------
# 辅助函数 - 获取运行状态（IPv4监听验证）
# -----------------------------------------------------------------------------
get_run_status() {
    if get_mosquitto_pid > /dev/null 2>&1; then
        # 检查IPv4监听状态
        if check_ipv4_listening "$MOSQUITTO_PORT"; then
            echo "success"
        else
            echo "partial"  # 运行但IPv4监听有问题
        fi
    else
        echo "failed"
    fi
}

# -----------------------------------------------------------------------------
# 辅助函数 - 生成状态消息（IPv4监听感知）
# -----------------------------------------------------------------------------
generate_status_message() {
    local run_status="$1"
    local mosquitto_pid=$(get_mosquitto_pid || echo "")
    local uptime_seconds=0
    local ipv4_status=""
    
    if [ -n "$mosquitto_pid" ]; then
        uptime_seconds=$(ps -o etimes= -p "$mosquitto_pid" 2>/dev/null || echo 0)
        uptime_seconds=$(echo "$uptime_seconds" | tr -d '\n\r\t ' | grep -o '^[0-9]*' || echo 0)
        
        # 检查IPv4监听状态
        if check_ipv4_listening "$MOSQUITTO_PORT"; then
            ipv4_status=" (IPv4 listening)"
        else
            ipv4_status=" (IPv4 issue)"
        fi
    fi
    
    local uptime_minutes=$(( uptime_seconds / 60 ))
    
    case "$run_status" in
        "running"|"success")
            if [ $uptime_minutes -lt 5 ]; then
                echo "mosquitto restarted $uptime_minutes minutes ago$ipv4_status"
            elif [ $uptime_minutes -lt 60 ]; then
                echo "mosquitto running for $uptime_minutes minutes$ipv4_status"
            else
                local uptime_hours=$(( uptime_minutes / 60 ))
                echo "mosquitto running for $uptime_hours hours$ipv4_status"
            fi
            ;;
        "partial")
            echo "mosquitto running but IPv4 listening issue"
            ;;
        "starting")
            echo "mosquitto is starting up"
            ;;
        "stopping")
            echo "mosquitto is stopping"
            ;;
        "stopped")
            echo "mosquitto is not running"
            ;;
        "failed")
            echo "mosquitto failed to start"
            ;;
        *)
            echo "mosquitto status unknown"
            ;;
    esac
}

# -----------------------------------------------------------------------------
# 辅助函数 - 获取配置信息 (JSON格式，增强IPv4检查)
# -----------------------------------------------------------------------------
get_config_info() {
    if [ ! -f "$MOSQUITTO_CONF_FILE" ]; then
        echo '{"error": "Config file not found"}'
        return
    fi
    
    # 解析配置文件
    local port=""
    local bind_address=""
    local websocket_port=""
    
    # 检查新格式 listener 配置
    if grep -q "^listener.*1883" "$MOSQUITTO_CONF_FILE"; then
        port="1883"
        bind_address=$(grep "^listener.*1883" "$MOSQUITTO_CONF_FILE" | awk '{print $3}' | head -1)
        bind_address="${bind_address:-0.0.0.0}"
    elif grep -q "^port[[:space:]]" "$MOSQUITTO_CONF_FILE"; then
        # 检查旧格式 port 配置
        port=$(grep -E "^port[[:space:]]+" "$MOSQUITTO_CONF_FILE" | awk '{print $2}' || echo "1883")
        bind_address=$(grep -E "^bind_address[[:space:]]+" "$MOSQUITTO_CONF_FILE" | awk '{print $2}' || echo "127.0.0.1")
    else
        port="1883"
        bind_address="unknown"
    fi
    
    # 检查WebSocket配置
    if grep -q "^listener.*9001" "$MOSQUITTO_CONF_FILE"; then
        websocket_port="9001"
    else
        websocket_port="disabled"
    fi
    
    local allow_anonymous=$(grep -E "^allow_anonymous[[:space:]]+" "$MOSQUITTO_CONF_FILE" | awk '{print $2}' || echo "false")
    local password_file=$(grep -E "^password_file[[:space:]]+" "$MOSQUITTO_CONF_FILE" | awk '{print $2}' || echo "")
    local log_dest=$(grep -E "^log_dest[[:space:]]+" "$MOSQUITTO_CONF_FILE" | awk '{print $2}' || echo "file")
    local persistence=$(grep -E "^persistence[[:space:]]+" "$MOSQUITTO_CONF_FILE" | awk '{print $2}' || echo "true")
    
    # 添加IPv4监听状态
    local ipv4_listening="false"
    if check_ipv4_listening "$MOSQUITTO_PORT"; then
        ipv4_listening="true"
    fi
    
    echo "{\"port\":\"$port\",\"bind_address\":\"$bind_address\",\"websocket_port\":\"$websocket_port\",\"allow_anonymous\":\"$allow_anonymous\",\"password_file\":\"$password_file\",\"log_dest\":\"$log_dest\",\"persistence\":\"$persistence\",\"ipv4_listening\":$ipv4_listening}"
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
# 辅助函数 - 改进的状态检查函数
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
    if bash "$SERVICE_DIR/status.sh" --quiet 2>/dev/null; then
        # 进一步检查IPv4监听状态
        if check_ipv4_listening "$MOSQUITTO_PORT"; then
            echo "running"
        else
            echo "starting"  # 运行但IPv4未就绪
        fi
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
        local last_install_line=$(tail -n1 "$INSTALL_HISTORY_FILE" 2>/dev/null)
        if [ -n "$last_install_line" ]; then
            if echo "$last_install_line" | grep -q "UNINSTALL SUCCESS"; then
                echo "uninstalled"
                return
            elif echo "$last_install_line" | grep -q "INSTALL SUCCESS"; then
                if command -v mosquitto >/dev/null 2>&1 && [ -f "$MOSQUITTO_CONF_FILE" ]; then
                    echo "success"
                else
                    echo "uninstalled"
                fi
                return
            elif echo "$last_install_line" | grep -q "INSTALL FAILED"; then
                echo "failed"
                return
            fi
        fi
    fi
    
    # 没有历史记录，检查实际安装状态
    if command -v mosquitto >/dev/null 2>&1 && [ -f "$MOSQUITTO_CONF_FILE" ]; then
        echo "success"
    else
        echo "never"
    fi
}

# 改进的 BACKUP 状态检查
get_improved_backup_status() {
    if pgrep -f "$SERVICE_DIR/backup.sh" > /dev/null 2>&1; then
        echo "backuping"
        return
    fi
    
    local backup_files=$(ls -1 "$BACKUP_DIR"/mosquitto_backup_*.tar.gz 2>/dev/null | wc -l)
    backup_files=${backup_files:-0}
    
    if [ "$backup_files" -gt 0 ]; then
        if [ -f "$LOG_FILE_BACKUP" ] && [ -s "$LOG_FILE_BACKUP" ]; then
            local recent_log=$(tail -10 "$LOG_FILE_BACKUP" 2>/dev/null)
            if echo "$recent_log" | grep -q "backup skipped"; then
                echo "skipped"
            elif echo "$recent_log" | grep -q "backup completed.*successfully"; then
                echo "success"
            elif echo "$recent_log" | grep -q "backup.*failed\|failed.*backup"; then
                echo "failed"
            else
                echo "success"
            fi
        else
            echo "success"
        fi
    else
        echo "never"
    fi
}

# 改进的 UPDATE 状态检查
get_improved_update_status() {
    if pgrep -f "$SERVICE_DIR/update.sh" > /dev/null 2>&1; then
        echo "updating"
        return
    fi
    
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
}

# 改进的 RESTORE 状态检查
get_improved_restore_status() {
    if pgrep -f "$SERVICE_DIR/restore.sh" > /dev/null 2>&1; then
        echo "restoring"
        return
    fi
    
    if [ -f "$LOG_FILE_RESTORE" ] && [ -s "$LOG_FILE_RESTORE" ]; then
        local recent_log=$(tail -10 "$LOG_FILE_RESTORE" 2>/dev/null)
        if echo "$recent_log" | grep -q "restore.*complete\|configuration restored.*successfully"; then
            echo "success"
        elif echo "$recent_log" | grep -q "restore.*skipped\|backup.*skipped"; then
            echo "skipped"
        elif echo "$recent_log" | grep -q "restore.*failed\|failed.*restore"; then
            echo "failed"
        else
            if [ -f "$MOSQUITTO_CONF_FILE" ]; then
                echo "success"
            else
                echo "never"
            fi
        fi
    else
        if [ -f "$MOSQUITTO_CONF_FILE" ]; then
            echo "success"
        else
            echo "never"
        fi
    fi
}

# -----------------------------------------------------------------------------
# 配置管理函数 - autocheck.sh 依赖的核心函数
# -----------------------------------------------------------------------------

# 从serviceupdate.json读取配置
read_config_from_serviceupdate() {
    if [ ! -f "$SERVICEUPDATE_FILE" ]; then
        log_error "serviceupdate.json not found: $SERVICEUPDATE_FILE"
        return 1
    fi
    
    # 使用jq读取配置，提供默认值
    CONFIG_PORT=$(jq -r ".services[] | select(.id==\"$SERVICE_ID\") | .config.port // \"1883\"" "$SERVICEUPDATE_FILE" 2>/dev/null)
    CONFIG_BIND_ADDRESS=$(jq -r ".services[] | select(.id==\"$SERVICE_ID\") | .config.bind_address // \"0.0.0.0\"" "$SERVICEUPDATE_FILE" 2>/dev/null)
    CONFIG_USERNAME=$(jq -r ".services[] | select(.id==\"$SERVICE_ID\") | .config.username // \"admin\"" "$SERVICEUPDATE_FILE" 2>/dev/null)
    CONFIG_PASSWORD=$(jq -r ".services[] | select(.id==\"$SERVICE_ID\") | .config.password // \"admin\"" "$SERVICEUPDATE_FILE" 2>/dev/null)
    CONFIG_WEBSOCKET_PORT=$(jq -r ".services[] | select(.id==\"$SERVICE_ID\") | .config.websocket_port // \"9001\"" "$SERVICEUPDATE_FILE" 2>/dev/null)
    CONFIG_ALLOW_ANONYMOUS=$(jq -r ".services[] | select(.id==\"$SERVICE_ID\") | .config.allow_anonymous // \"false\"" "$SERVICEUPDATE_FILE" 2>/dev/null)
    CONFIG_PERSISTENCE=$(jq -r ".services[] | select(.id==\"$SERVICE_ID\") | .config.persistence // \"true\"" "$SERVICEUPDATE_FILE" 2>/dev/null)
    
    # 验证必需的配置是否成功读取
    if [ "$CONFIG_PORT" = "null" ] || [ -z "$CONFIG_PORT" ]; then
        log_error "Failed to read configuration from serviceupdate.json"
        return 1
    fi
    
    log_debug "Configuration read from serviceupdate.json: port=$CONFIG_PORT, bind_address=$CONFIG_BIND_ADDRESS"
    return 0
}

# 根据serviceupdate.json生成mosquitto.conf（确保IPv4监听）
generate_mosquitto_config_from_serviceupdate() {
    if ! read_config_from_serviceupdate; then
        log_error "Cannot generate mosquitto.conf: failed to read serviceupdate configuration"
        return 1
    fi
    
    # 确保配置目录存在
    mkdir -p "$(dirname "$MOSQUITTO_CONF_FILE")"
    
    log "Generating mosquitto.conf from serviceupdate.json configuration with IPv4 listening"
    
    cat > "$MOSQUITTO_CONF_FILE" << EOF
# Mosquitto Configuration File
# Auto-generated from serviceupdate.json config
# Generated on: $(date)
# Compatible with Mosquitto 2.0.22

# IPv4 Network Settings - Global listening
listener $CONFIG_PORT 0.0.0.0

# WebSocket Support
listener $CONFIG_WEBSOCKET_PORT 0.0.0.0
protocol websockets

# Authentication
allow_anonymous $CONFIG_ALLOW_ANONYMOUS
password_file $MOSQUITTO_PASSWD_FILE

# Persistence
persistence $CONFIG_PERSISTENCE
persistence_location $TERMUX_VAR_DIR/lib/mosquitto/

# Logging
log_dest file $MOSQUITTO_LOG_DIR/mosquitto.log
log_type error
log_type warning
log_type notice
log_type information
log_timestamp true

# Security and Performance
max_connections 100
max_inflight_messages 20
max_queued_messages 100

# Client settings
persistent_client_expiration 1m
EOF
    
    # 注意：Mosquitto 2.0.22 不支持 -t 参数进行配置验证
    # 配置正确性将在实际启动时验证
    log "mosquitto.conf generated successfully with IPv4 listening (validation at startup)"
    return 0
}

# 根据serviceupdate.json更新用户密码
update_users_from_serviceupdate() {
    if ! read_config_from_serviceupdate; then
        log_error "Cannot update users: failed to read serviceupdate configuration"
        return 1
    fi
    
    # 确保密码文件目录存在
    mkdir -p "$(dirname "$MOSQUITTO_PASSWD_FILE")"
    
    log "Updating MQTT user: $CONFIG_USERNAME"
    
    # 创建密码文件
    if echo "$CONFIG_USERNAME:$CONFIG_PASSWORD" | mosquitto_passwd -c "$MOSQUITTO_PASSWD_FILE" "$CONFIG_USERNAME" 2>/dev/null; then
        chmod 600 "$MOSQUITTO_PASSWD_FILE"
        log "MQTT user updated successfully: $CONFIG_USERNAME"
        return 0
    else
        log_error "Failed to update MQTT user: $CONFIG_USERNAME"
        return 1
    fi
}

# 同步到全局配置 configuration.yaml
sync_to_global_config() {
    if ! read_config_from_serviceupdate; then
        log_error "Cannot sync to global config: failed to read serviceupdate configuration"
        return 1
    fi
    
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "Global configuration file not found: $CONFIG_FILE"
        return 1
    fi
    
    log "Syncing configuration to global config: $CONFIG_FILE"
    
    # 创建备份
    cp "$CONFIG_FILE" "$CONFIG_FILE.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
    
    # 使用sed更新configuration.yaml中的mqtt配置
    sed -i "s/^[[:space:]]*host:[[:space:]].*/  host: $CONFIG_BIND_ADDRESS/" "$CONFIG_FILE"
    sed -i "s/^[[:space:]]*port:[[:space:]].*/  port: $CONFIG_PORT/" "$CONFIG_FILE"
    sed -i "s/^[[:space:]]*username:[[:space:]].*/  username: $CONFIG_USERNAME/" "$CONFIG_FILE"
    sed -i "s/^[[:space:]]*password:[[:space:]].*/  password: $CONFIG_PASSWORD/" "$CONFIG_FILE"
    
    # 检查websocket_port字段是否存在，不存在则添加
    if ! grep -q "websocket_port:" "$CONFIG_FILE"; then
        sed -i "/^[[:space:]]*port:/a\\  websocket_port: $CONFIG_WEBSOCKET_PORT" "$CONFIG_FILE"
    else
        sed -i "s/^[[:space:]]*websocket_port:[[:space:]].*/  websocket_port: $CONFIG_WEBSOCKET_PORT/" "$CONFIG_FILE"
    fi
    
    log "Global configuration synchronized successfully"
    return 0
}

# 检查配置变更
check_config_changes() {
    log_debug "Checking configuration changes..."
    
    # 检查serviceupdate.json与本地配置是否一致
    if compare_serviceupdate_with_local_config; then
        log_debug "Configuration changes detected: serviceupdate vs local"
        return 0  # 有变更
    fi
    
    # 检查本地配置与全局配置是否一致
    if compare_local_with_global_config; then
        log_debug "Configuration changes detected: local vs global"
        return 0  # 有变更
    fi
    
    log_debug "No configuration changes detected"
    return 1  # 无变更
}

# 对比serviceupdate配置与本地服务配置
compare_serviceupdate_with_local_config() {
    # 读取serviceupdate.json中的配置
    if ! read_config_from_serviceupdate; then
        log_error "Failed to read serviceupdate.json config for comparison"
        return 1
    fi
    
    # 读取当前mosquitto.conf中的配置
    if [ ! -f "$MOSQUITTO_CONF_FILE" ]; then
        log_debug "Mosquitto config file not found, needs creation"
        return 0  # 需要更新
    fi
    
    # 解析当前配置文件（支持新旧格式）
    local current_port=""
    local current_bind_address=""
    
    # 检查新格式 listener 配置
    if grep -q "^listener.*1883" "$MOSQUITTO_CONF_FILE"; then
        current_port="1883"
        current_bind_address=$(grep "^listener.*1883" "$MOSQUITTO_CONF_FILE" | awk '{print $3}' | head -1)
        current_bind_address="${current_bind_address:-0.0.0.0}"
    else
        # 检查旧格式配置
        current_port=$(grep -E "^port[[:space:]]+" "$MOSQUITTO_CONF_FILE" 2>/dev/null | awk '{print $2}' || echo "")
        current_bind_address=$(grep -E "^bind_address[[:space:]]+" "$MOSQUITTO_CONF_FILE" 2>/dev/null | awk '{print $2}' || echo "")
    fi
    
    local current_allow_anonymous=$(grep -E "^allow_anonymous[[:space:]]+" "$MOSQUITTO_CONF_FILE" 2>/dev/null | awk '{print $2}' || echo "")
    local current_persistence=$(grep -E "^persistence[[:space:]]+" "$MOSQUITTO_CONF_FILE" 2>/dev/null | awk '{print $2}' || echo "")
    
    # 读取当前用户信息
    local current_username=""
    if [ -f "$MOSQUITTO_PASSWD_FILE" ]; then
        current_username=$(head -n1 "$MOSQUITTO_PASSWD_FILE" 2>/dev/null | cut -d':' -f1 || echo "")
    fi
    
    # 对比配置
    local config_differs=false
    
    if [ "$CONFIG_PORT" != "$current_port" ]; then
        log_debug "Port differs: serviceupdate=$CONFIG_PORT, current=$current_port"
        config_differs=true
    fi
    
    if [ "$CONFIG_BIND_ADDRESS" != "$current_bind_address" ]; then
        log_debug "Bind address differs: serviceupdate=$CONFIG_BIND_ADDRESS, current=$current_bind_address"
        config_differs=true
    fi
    
    if [ "$CONFIG_ALLOW_ANONYMOUS" != "$current_allow_anonymous" ]; then
        log_debug "Allow anonymous differs: serviceupdate=$CONFIG_ALLOW_ANONYMOUS, current=$current_allow_anonymous"
        config_differs=true
    fi
    
    if [ "$CONFIG_PERSISTENCE" != "$current_persistence" ]; then
        log_debug "Persistence differs: serviceupdate=$CONFIG_PERSISTENCE, current=$current_persistence"
        config_differs=true
    fi
    
    if [ "$CONFIG_USERNAME" != "$current_username" ]; then
        log_debug "Username differs: serviceupdate=$CONFIG_USERNAME, current=$current_username"
        config_differs=true
    fi
    
    # 特别检查IPv4监听配置
    if ! grep -q "listener.*1883.*0.0.0.0" "$MOSQUITTO_CONF_FILE"; then
        log_debug "IPv4 listening configuration missing or incorrect"
        config_differs=true
    fi
    
    if [ "$config_differs" = true ]; then
        log "Local service config differs from serviceupdate.json"
        return 0  # 需要更新
    else
        log_debug "Local service config matches serviceupdate.json"
        return 1  # 不需要更新
    fi
}

# 对比本地配置与configuration.yaml中的mqtt信息
compare_local_with_global_config() {
    # 读取serviceupdate.json配置用于对比
    if ! read_config_from_serviceupdate; then
        log_error "Failed to read serviceupdate config for global comparison"
        return 1
    fi
    
    # 读取当前configuration.yaml中的mqtt配置
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "Global configuration file not found for comparison"
        return 1
    fi
    
    local global_host=$(grep -Po '^[[:space:]]*host:[[:space:]]*\K.*' "$CONFIG_FILE" 2>/dev/null | head -n1 || echo "")
    local global_port=$(grep -Po '^[[:space:]]*port:[[:space:]]*\K.*' "$CONFIG_FILE" 2>/dev/null | head -n1 || echo "")
    local global_username=$(grep -Po '^[[:space:]]*username:[[:space:]]*\K.*' "$CONFIG_FILE" 2>/dev/null | head -n1 || echo "")
    local global_password=$(grep -Po '^[[:space:]]*password:[[:space:]]*\K.*' "$CONFIG_FILE" 2>/dev/null | head -n1 || echo "")
    local global_websocket_port=$(grep -Po '^[[:space:]]*websocket_port:[[:space:]]*\K.*' "$CONFIG_FILE" 2>/dev/null | head -n1 || echo "")
    
    # 对比配置
    local global_differs=false
    
    if [ "$CONFIG_BIND_ADDRESS" != "$global_host" ]; then
        log_debug "Global host differs: local=$CONFIG_BIND_ADDRESS, global=$global_host"
        global_differs=true
    fi
    
    if [ "$CONFIG_PORT" != "$global_port" ]; then
        log_debug "Global port differs: local=$CONFIG_PORT, global=$global_port"
        global_differs=true
    fi
    
    if [ "$CONFIG_USERNAME" != "$global_username" ]; then
        log_debug "Global username differs: local=$CONFIG_USERNAME, global=$global_username"
        global_differs=true
    fi
    
    if [ "$CONFIG_PASSWORD" != "$global_password" ]; then
        log_debug "Global password differs: local=*****, global=*****"
        global_differs=true
    fi
    
    if [ "$CONFIG_WEBSOCKET_PORT" != "$global_websocket_port" ]; then
        log_debug "Global websocket_port differs: local=$CONFIG_WEBSOCKET_PORT, global=$global_websocket_port"
        global_differs=true
    fi
    
    if [ "$global_differs" = true ]; then
        log "Global configuration.yaml differs from local config"
        return 0  # 需要更新
    else
        log_debug "Global configuration.yaml matches local config"
        return 1  # 不需要更新
    fi
}

# -----------------------------------------------------------------------------
# MQTT Broker 维护功能
# -----------------------------------------------------------------------------

# 获取MQTT broker存储使用情况
get_mqtt_storage_usage() {
    local persistence_dir="$TERMUX_VAR_DIR/lib/mosquitto"
    local storage_info="{}"
    
    if [ -d "$persistence_dir" ]; then
        local total_size_kb=$(du -sk "$persistence_dir" 2>/dev/null | cut -f1 || echo "0")
        local file_count=$(find "$persistence_dir" -type f 2>/dev/null | wc -l || echo "0")
        local db_files=$(find "$persistence_dir" -name "*.db" -type f 2>/dev/null | wc -l || echo "0")
        
        # 获取最大和最旧的文件信息
        local largest_file=""
        local oldest_file=""
        local largest_size=0
        local oldest_date=""
        
        if [ "$file_count" -gt 0 ]; then
            # 查找最大文件
            while IFS= read -r file; do
                if [ -f "$file" ]; then
                    local size=$(du -k "$file" 2>/dev/null | cut -f1 || echo "0")
                    if [ "$size" -gt "$largest_size" ]; then
                        largest_size="$size"
                        largest_file="$(basename "$file")"
                    fi
                fi
            done < <(find "$persistence_dir" -type f 2>/dev/null)
            
            # 查找最旧文件
            oldest_file=$(find "$persistence_dir" -type f -printf '%T+ %p\n' 2>/dev/null | sort | head -1 | cut -d' ' -f2- | xargs basename 2>/dev/null || echo "")
            if [ -n "$oldest_file" ]; then
                oldest_date=$(stat -c %Y "$persistence_dir/$oldest_file" 2>/dev/null || echo "0")
            fi
        fi
        
        storage_info=$(cat << EOF
{
    "total_size_kb": $total_size_kb,
    "file_count": $file_count,
    "db_files": $db_files,
    "largest_file": "$largest_file",
    "largest_size_kb": $largest_size,
    "oldest_file": "$oldest_file",
    "oldest_date": $oldest_date,
    "path": "$persistence_dir"
}
EOF
        )
    else
        storage_info='{"error": "persistence directory not found"}'
    fi
    
    echo "$storage_info"
}

# 分析MQTT消息负载
analyze_mqtt_load() {
    local log_file="$MOSQUITTO_LOG_DIR/mosquitto.log"
    local analysis="{}"
    
    if [ -f "$log_file" ]; then
        # 分析最近10分钟的日志
        local recent_log=$(tail -1000 "$log_file" 2>/dev/null | tail -500)
        
        # 统计不同类型的消息
        local connections=$(echo "$recent_log" | grep -c "New connection" 2>/dev/null || echo "0")
        local disconnections=$(echo "$recent_log" | grep -c "disconnected" 2>/dev/null || echo "0")
        local publishes=$(echo "$recent_log" | grep -c "PUBLISH" 2>/dev/null || echo "0")
        local subscribes=$(echo "$recent_log" | grep -c "SUBSCRIBE" 2>/dev/null || echo "0")
        local errors=$(echo "$recent_log" | grep -ci "error" 2>/dev/null || echo "0")
        local warnings=$(echo "$recent_log" | grep -ci "warning" 2>/dev/null || echo "0")
        
        # 检测高频客户端
        local top_clients=$(echo "$recent_log" | grep -o "Client [a-zA-Z0-9_-]*" | sort | uniq -c | sort -nr | head -5 | while read count client; do
            echo "\"$client\": $count"
        done | paste -sd,)
        
        # 检测高频主题模式
        local topic_patterns=$(echo "$recent_log" | grep -o "on topic [^[:space:]]*" | cut -d' ' -f3 | cut -d'/' -f1-2 | sort | uniq -c | sort -nr | head -5 | while read count pattern; do
            echo "\"$pattern/*\": $count"
        done | paste -sd,)
        
        analysis=$(cat << EOF
{
    "timestamp": $(date +%s),
    "period_minutes": 10,
    "connections": $connections,
    "disconnections": $disconnections,
    "publishes": $publishes,
    "subscribes": $subscribes,
    "errors": $errors,
    "warnings": $warnings,
    "top_clients": {$top_clients},
    "topic_patterns": {$topic_patterns},
    "net_connections": $((connections - disconnections))
}
EOF
        )
    else
        analysis='{"error": "log file not found"}'
    fi
    
    echo "$analysis"
}

# 清理MQTT broker持久化数据
cleanup_mqtt_persistence() {
    local cleanup_level="${1:-normal}"  # normal, aggressive, emergency
    local persistence_dir="$TERMUX_VAR_DIR/lib/mosquitto"
    local cleaned_size=0
    local cleaned_files=0
    
    if [ ! -d "$persistence_dir" ]; then
        log "MQTT persistence directory not found, skipping cleanup"
        return 0
    fi
    
    log "Starting MQTT persistence cleanup (level: $cleanup_level)"
    
    # 获取清理前的大小
    local before_size=$(du -sk "$persistence_dir" 2>/dev/null | cut -f1 || echo "0")
    
    case "$cleanup_level" in
        "normal")
            # 清理7天前的数据
            local old_files=$(find "$persistence_dir" -name "*.db" -mtime +7 2>/dev/null)
            if [ -n "$old_files" ]; then
                echo "$old_files" | while read -r file; do
                    if [ -f "$file" ]; then
                        local size=$(du -k "$file" 2>/dev/null | cut -f1 || echo "0")
                        rm -f "$file"
                        cleaned_size=$((cleaned_size + size))
                        cleaned_files=$((cleaned_files + 1))
                        log_debug "Removed old persistence file: $(basename "$file") (${size}KB)"
                    fi
                done
            fi
            ;;
            
        "aggressive")
            # 清理3天前的数据和大文件
            local old_files=$(find "$persistence_dir" -name "*.db" -mtime +3 2>/dev/null)
            local large_files=$(find "$persistence_dir" -name "*.db" -size +10M 2>/dev/null)
            
            for file in $old_files $large_files; do
                if [ -f "$file" ]; then
                    local size=$(du -k "$file" 2>/dev/null | cut -f1 || echo "0")
                    rm -f "$file"
                    cleaned_size=$((cleaned_size + size))
                    cleaned_files=$((cleaned_files + 1))
                    log "Removed persistence file: $(basename "$file") (${size}KB)"
                fi
            done
            ;;
            
        "emergency")
            # 清理所有持久化数据（保留配置）
            log_warn "Emergency cleanup: removing all MQTT persistence data"
            
            # 备份当前持久化数据
            local backup_file="$BACKUP_DIR/mqtt_persistence_emergency_$(date +%Y%m%d_%H%M%S).tar.gz"
            if tar -czf "$backup_file" -C "$(dirname "$persistence_dir")" "$(basename "$persistence_dir")" 2>/dev/null; then
                log "Emergency backup created: $(basename "$backup_file")"
            fi
            
            # 清理所有.db文件
            find "$persistence_dir" -name "*.db" -type f -delete 2>/dev/null || true
            cleaned_files=$(find "$persistence_dir" -name "*.db" 2>/dev/null | wc -l || echo "0")
            ;;
    esac
    
    # 获取清理后的大小
    local after_size=$(du -sk "$persistence_dir" 2>/dev/null | cut -f1 || echo "0")
    cleaned_size=$((before_size - after_size))
    
    log "MQTT persistence cleanup completed: ${cleaned_files} files, ${cleaned_size}KB freed"
    
    # 上报清理结果（如果服务运行中）
    if bash "$SERVICE_DIR/status.sh" --quiet 2>/dev/null; then
        mqtt_report "isg/maintenance/$SERVICE_ID/mqtt_cleanup" \
            "{\"level\":\"$cleanup_level\",\"files_removed\":$cleaned_files,\"size_freed_kb\":$cleaned_size,\"before_size_kb\":$before_size,\"after_size_kb\":$after_size,\"timestamp\":$(date +%s)}" \
            1 2>/dev/null || log "MQTT cleanup report failed"
    fi
    
    return 0
}

# 优化MQTT broker配置
optimize_mqtt_config() {
    local optimization_level="${1:-normal}"  # normal, performance, memory
    local config_changed=false
    
    if [ ! -f "$MOSQUITTO_CONF_FILE" ]; then
        log_error "Mosquitto config file not found, cannot optimize"
        return 1
    fi
    
    log "Starting MQTT configuration optimization (level: $optimization_level)"
    
    # 备份当前配置
    cp "$MOSQUITTO_CONF_FILE" "$MOSQUITTO_CONF_FILE.backup.$(date +%Y%m%d_%H%M%S)"
    
    case "$optimization_level" in
        "normal")
            # 基础优化：调整连接和消息限制
            if ! grep -q "max_connections" "$MOSQUITTO_CONF_FILE"; then
                echo "max_connections 100" >> "$MOSQUITTO_CONF_FILE"
                config_changed=true
            fi
            
            if ! grep -q "max_inflight_messages" "$MOSQUITTO_CONF_FILE"; then
                echo "max_inflight_messages 20" >> "$MOSQUITTO_CONF_FILE"
                config_changed=true
            fi
            
            if ! grep -q "max_queued_messages" "$MOSQUITTO_CONF_FILE"; then
                echo "max_queued_messages 100" >> "$MOSQUITTO_CONF_FILE"
                config_changed=true
            fi
            ;;
            
        "performance")
            # 性能优化：增加限制，优化吞吐量
            sed -i 's/max_connections .*/max_connections 200/' "$MOSQUITTO_CONF_FILE"
            sed -i 's/max_inflight_messages .*/max_inflight_messages 50/' "$MOSQUITTO_CONF_FILE"
            sed -i 's/max_queued_messages .*/max_queued_messages 1000/' "$MOSQUITTO_CONF_FILE"
            
            # 添加性能相关配置
            if ! grep -q "message_size_limit" "$MOSQUITTO_CONF_FILE"; then
                echo "message_size_limit 1048576" >> "$MOSQUITTO_CONF_FILE"  # 1MB
                config_changed=true
            fi
            
            if ! grep -q "sys_interval" "$MOSQUITTO_CONF_FILE"; then
                echo "sys_interval 30" >> "$MOSQUITTO_CONF_FILE"
                config_changed=true
            fi
            ;;
            
        "memory")
            # 内存优化：降低限制，减少内存使用
            sed -i 's/max_connections .*/max_connections 50/' "$MOSQUITTO_CONF_FILE"
            sed -i 's/max_inflight_messages .*/max_inflight_messages 10/' "$MOSQUITTO_CONF_FILE"
            sed -i 's/max_queued_messages .*/max_queued_messages 50/' "$MOSQUITTO_CONF_FILE"
            
            # 添加内存优化配置
            if ! grep -q "persistent_client_expiration" "$MOSQUITTO_CONF_FILE"; then
                echo "persistent_client_expiration 1m" >> "$MOSQUITTO_CONF_FILE"
                config_changed=true
            fi
            
            # 禁用某些功能以节省内存
            if ! grep -q "allow_zero_length_clientid" "$MOSQUITTO_CONF_FILE"; then
                echo "allow_zero_length_clientid false" >> "$MOSQUITTO_CONF_FILE"
                config_changed=true
            fi
            ;;
    esac
    
    if [ "$config_changed" = true ]; then
        # 验证配置
        if mosquitto -c "$MOSQUITTO_CONF_FILE" -t 2>/dev/null; then
            log "MQTT configuration optimized and validated (level: $optimization_level)"
            return 0
        else
            log_error "Optimized configuration validation failed, restoring backup"
            # 恢复备份
            local backup_file="$MOSQUITTO_CONF_FILE.backup.$(date +%Y%m%d_%H%M%S)"
            if [ -f "$backup_file" ]; then
                cp "$backup_file" "$MOSQUITTO_CONF_FILE"
            fi
            return 1
        fi
    else
        log "MQTT configuration already optimized"
        return 0
    fi
}

# 监控和告警MQTT负载
monitor_mqtt_load() {
    local storage_info=$(get_mqtt_storage_usage)
    local load_info=$(analyze_mqtt_load)
    
    # 提取关键指标
    local total_size_kb=$(echo "$storage_info" | jq -r '.total_size_kb // 0' 2>/dev/null || echo "0")
    local file_count=$(echo "$storage_info" | jq -r '.file_count // 0' 2>/dev/null || echo "0")
    local publishes=$(echo "$load_info" | jq -r '.publishes // 0' 2>/dev/null || echo "0")
    local errors=$(echo "$load_info" | jq -r '.errors // 0' 2>/dev/null || echo "0")
    local warnings=$(echo "$load_info" | jq -r '.warnings // 0' 2>/dev/null || echo "0")
    
    # 定义告警阈值
    local size_warning_mb=100
    local size_critical_mb=500
    local error_warning=5
    local error_critical=20
    local publish_warning=1000
    local publish_critical=5000
    
    local size_mb=$((total_size_kb / 1024))
    local alert_level="normal"
    local alert_messages=()
    
    # 检查存储使用
    if [ "$size_mb" -gt $size_critical_mb ]; then
        alert_level="critical"
        alert_messages+=("CRITICAL: MQTT storage usage ${size_mb}MB exceeds ${size_critical_mb}MB")
        # 自动执行紧急清理
        cleanup_mqtt_persistence "emergency"
    elif [ "$size_mb" -gt $size_warning_mb ]; then
        alert_level="warning"
        alert_messages+=("WARNING: MQTT storage usage ${size_mb}MB exceeds ${size_warning_mb}MB")
        # 自动执行常规清理
        cleanup_mqtt_persistence "normal"
    fi
    
    # 检查错误率
    if [ "$errors" -gt $error_critical ]; then
        alert_level="critical"
        alert_messages+=("CRITICAL: High MQTT error count: $errors")
    elif [ "$errors" -gt $error_warning ]; then
        if [ "$alert_level" != "critical" ]; then
            alert_level="warning"
        fi
        alert_messages+=("WARNING: Elevated MQTT error count: $errors")
    fi
    
    # 检查发布频率
    if [ "$publishes" -gt $publish_critical ]; then
        alert_level="critical"
        alert_messages+=("CRITICAL: Very high MQTT publish rate: $publishes/10min")
    elif [ "$publishes" -gt $publish_warning ]; then
        if [ "$alert_level" != "critical" ]; then
            alert_level="warning"
        fi
        alert_messages+=("WARNING: High MQTT publish rate: $publishes/10min")
    fi
    
    # 发送告警（如果服务运行中）
    if [ "$alert_level" != "normal" ]; then
        local alert_message=$(IFS='; '; echo "${alert_messages[*]}")
        log_warn "MQTT Load Alert ($alert_level): $alert_message"
        
        if bash "$SERVICE_DIR/status.sh" --quiet 2>/dev/null; then
            mqtt_report "isg/alert/$SERVICE_ID/mqtt_load" \
                "{\"level\":\"$alert_level\",\"message\":\"$alert_message\",\"storage_mb\":$size_mb,\"errors\":$errors,\"publishes\":$publishes,\"timestamp\":$(date +%s)}" \
                1 2>/dev/null || log "MQTT alert report failed"
        fi
        
        # 自动优化配置
        if [ "$alert_level" = "critical" ]; then
            optimize_mqtt_config "memory"
        fi
    fi
    
    # 上报监控数据（如果服务运行中）
    if bash "$SERVICE_DIR/status.sh" --quiet 2>/dev/null; then
        mqtt_report "isg/monitor/$SERVICE_ID/mqtt_metrics" \
            "{\"storage\":$storage_info,\"load\":$load_info,\"alert_level\":\"$alert_level\",\"timestamp\":$(date +%s)}" \
            1 2>/dev/null || log "MQTT metrics report failed"
    fi
    
    log_debug "MQTT load monitoring completed: $alert_level level"
}

# MQTT broker维护主函数
maintain_mqtt_broker() {
    local maintenance_type="${1:-monitor}"  # monitor, cleanup, optimize, full
    
    log "Starting MQTT broker maintenance (type: $maintenance_type)"
    
    case "$maintenance_type" in
        "monitor")
            monitor_mqtt_load
            ;;
        "cleanup")
            cleanup_mqtt_persistence "normal"
            ;;
        "optimize")
            optimize_mqtt_config "normal"
            ;;
        "full")
            monitor_mqtt_load
            cleanup_mqtt_persistence "normal"
            optimize_mqtt_config "normal"
            ;;
        *)
            log_error "Unknown MQTT maintenance type: $maintenance_type"
            return 1
            ;;
    esac
    
    log "MQTT broker maintenance completed (type: $maintenance_type)"
}

# -----------------------------------------------------------------------------
# 辅助函数 - 配置验证（适配Mosquitto 2.0.22）
# -----------------------------------------------------------------------------
validate_config() {
    local config_file="$1"
    local config_type="${2:-mosquitto}"
    
    case "$config_type" in
        "mosquitto")
            if [ ! -f "$config_file" ]; then
                log_error "Mosquitto config file not found: $config_file"
                return 1
            fi
            
            # Mosquitto 2.0.22 不支持 -t 参数，所以只检查文件存在性和基本语法
            # 实际验证将在启动时进行
            if [ -r "$config_file" ] && [ -s "$config_file" ]; then
                log_debug "Mosquitto config file exists and is readable: $config_file"
                return 0
            else
                log_error "Mosquitto config file is empty or not readable: $config_file"
                return 1
            fi
            ;;
        "json")
            if [ ! -f "$config_file" ]; then
                log_error "JSON config file not found: $config_file"
                return 1
            fi
            
            if ! jq empty "$config_file" 2>/dev/null; then
                log_error "JSON config validation failed: $config_file"
                return 1
            fi
            ;;
        "yaml")
            if [ ! -f "$config_file" ]; then
                log_error "YAML config file not found: $config_file"
                return 1
            fi
            
            # 简单的YAML语法检查
            if command -v python3 >/dev/null 2>&1; then
                if ! python3 -c "import yaml; yaml.safe_load(open('$config_file'))" 2>/dev/null; then
                    log_error "YAML config validation failed: $config_file"
                    return 1
                fi
            fi
            ;;
    esac
    
    log_debug "Config validation passed: $config_file"
    return 0
}

# -----------------------------------------------------------------------------
# 辅助函数 - MQTT连接测试
# -----------------------------------------------------------------------------
test_mqtt_connection() {
    local timeout="${1:-10}"
    
    # 读取配置
    if ! load_mqtt_conf; then
        log_error "Failed to load MQTT configuration for connection test"
        return 1
    fi
    
    # 测试发布消息
    if timeout "$timeout" mosquitto_pub \
        -h "$MQTT_HOST" \
        -p "$MQTT_PORT" \
        -u "$MQTT_USER" \
        -P "$MQTT_PASS" \
        -t "test/connectivity" \
        -m "test_$(date +%s)" \
        2>/dev/null; then
        log_debug "MQTT connection test successful"
        return 0
    else
        log_error "MQTT connection test failed"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# 辅助函数 - 服务重启检测
# -----------------------------------------------------------------------------
detect_service_restart() {
    local current_pid=$(get_mosquitto_pid 2>/dev/null)
    local last_pid_file="$SERVICE_DIR/.last_pid"
    
    if [ -n "$current_pid" ]; then
        if [ -f "$last_pid_file" ]; then
            local last_pid=$(cat "$last_pid_file" 2>/dev/null)
            if [ "$current_pid" != "$last_pid" ]; then
                echo "restarted"
                echo "$current_pid" > "$last_pid_file"
                return 0
            fi
        else
            echo "$current_pid" > "$last_pid_file"
        fi
    else
        if [ -f "$last_pid_file" ]; then
            rm -f "$last_pid_file"
            echo "stopped"
            return 0
        fi
    fi
    
    echo "stable"
    return 1
}

# -----------------------------------------------------------------------------
# 辅助函数 - 日志清理
# -----------------------------------------------------------------------------
trim_log() {
    local log_file="${1:-$LOG_FILE}"
    local max_lines="${2:-500}"
    
    if [ -f "$log_file" ]; then
        tail -n "$max_lines" "$log_file" > "$log_file.tmp" && mv "$log_file.tmp" "$log_file"
        log_debug "Log file trimmed: $(basename "$log_file")"
    fi
}

# -----------------------------------------------------------------------------
# 辅助函数 - 清理函数
# -----------------------------------------------------------------------------
cleanup_on_error() {
    # 清理临时文件
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
        log_debug "Cleaned up temporary directory: $TEMP_DIR"
    fi
    
    # 释放锁文件
    if [ -n "$LOCK_FILE_AUTOCHECK" ] && [ -f "$LOCK_FILE_AUTOCHECK" ]; then
        rm -f "$LOCK_FILE_AUTOCHECK"
        log_debug "Released lock file: $LOCK_FILE_AUTOCHECK"
    fi
}

# -----------------------------------------------------------------------------
# 辅助函数 - 依赖检查
# -----------------------------------------------------------------------------
check_dependencies() {
    local missing_deps=()
    
    # 检查必需的命令
    local required_commands=("mosquitto" "mosquitto_pub" "mosquitto_passwd" "jq" "netstat")
    
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_deps+=("$cmd")
        fi
    done
    
    # 检查必需的目录
    local required_dirs=("$MOSQUITTO_CONF_DIR" "$MOSQUITTO_LOG_DIR" "$BACKUP_DIR")
    
    for dir in "${required_dirs[@]}"; do
        if [ ! -d "$dir" ]; then
            if ! mkdir -p "$dir" 2>/dev/null; then
                log_error "Cannot create required directory: $dir"
                return 1
            fi
        fi
    done
    
    # 检查必需的文件
    local required_files=("$CONFIG_FILE" "$SERVICEUPDATE_FILE")
    
    for file in "${required_files[@]}"; do
        if [ ! -f "$file" ]; then
            log_error "Required file not found: $file"
            return 1
        fi
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_error "Missing dependencies: ${missing_deps[*]}"
        return 1
    fi
    
    log_debug "All dependencies check passed"
    return 0
}

# -----------------------------------------------------------------------------
# 辅助函数 - 错误处理
# -----------------------------------------------------------------------------
handle_error() {
    local exit_code=$?
    local line_number="$1"
    local command="$2"
    
    log_error "Command failed at line $line_number: $command (exit code: $exit_code)"
    
    # 发送错误到MQTT（如果服务可用）
    if bash "$SERVICE_DIR/status.sh" --quiet 2>/dev/null; then
        mqtt_report "isg/error/$SERVICE_ID/status" \
            "{\"error\":\"script_error\",\"line\":$line_number,\"command\":\"$command\",\"exit_code\":$exit_code,\"timestamp\":$(date +%s)}" \
            1 2>/dev/null || true
    fi
    
    # 清理资源
    cleanup_on_error
    
    exit $exit_code
}

# 设置错误处理陷阱
set_error_trap() {
    trap 'handle_error ${LINENO} "$BASH_COMMAND"' ERR
}

# -----------------------------------------------------------------------------
# 辅助函数 - 权限检查
# -----------------------------------------------------------------------------
check_permissions() {
    local files_to_check=(
        "$MOSQUITTO_CONF_FILE"
        "$MOSQUITTO_PASSWD_FILE"
        "$MOSQUITTO_LOG_DIR"
        "$BACKUP_DIR"
    )
    
    for item in "${files_to_check[@]}"; do
        if [ -e "$item" ]; then
            if [ -f "$item" ] && [ ! -r "$item" ]; then
                log_error "File not readable: $item"
                return 1
            elif [ -d "$item" ] && [ ! -w "$item" ]; then
                log_error "Directory not writable: $item"
                return 1
            fi
        fi
    done
    
    # 检查密码文件权限
    if [ -f "$MOSQUITTO_PASSWD_FILE" ]; then
        local perms=$(stat -c %a "$MOSQUITTO_PASSWD_FILE" 2>/dev/null)
        if [ "$perms" != "600" ]; then
            log_warn "Password file permissions not secure: $perms, fixing to 600"
            chmod 600 "$MOSQUITTO_PASSWD_FILE"
        fi
    fi
    
    log_debug "Permissions check passed"
    return 0
}

# -----------------------------------------------------------------------------
# 辅助函数 - 综合预检查
# -----------------------------------------------------------------------------
pre_flight_check() {
    log_debug "Starting pre-flight checks..."
    
    # 依赖检查
    if ! check_dependencies; then
        return 1
    fi
    
    # 权限检查
    if ! check_permissions; then
        return 1
    fi
    
    # 配置文件验证
    if [ -f "$CONFIG_FILE" ] && ! validate_config "$CONFIG_FILE" "yaml"; then
        return 1
    fi
    
    if [ -f "$SERVICEUPDATE_FILE" ] && ! validate_config "$SERVICEUPDATE_FILE" "json"; then
        return 1
    fi
    
    log_debug "Pre-flight checks completed successfully"
    return 0
}

# -----------------------------------------------------------------------------
# 辅助函数 - IPv4监听诊断
# -----------------------------------------------------------------------------
diagnose_ipv4_listening() {
    log "=== IPv4 LISTENING DIAGNOSTIC ==="
    
    # 检查进程状态
    local mosquitto_pid=$(get_mosquitto_pid || echo "none")
    log "Mosquitto PID: $mosquitto_pid"
    
    if [ "$mosquitto_pid" != "none" ]; then
        log "Process command line:"
        ps -p "$mosquitto_pid" -o args= 2>/dev/null || echo "Process not found"
        
        log "Process runtime:"
        ps -p "$mosquitto_pid" -o etime= 2>/dev/null || echo "Process not found"
    fi
    
    # 检查端口监听状态
    log "All 1883 port listeners:"
    netstat -tnlp 2>/dev/null | grep ":1883" || echo "No listeners on port 1883"
    
    log "IPv4 global listeners (0.0.0.0):"
    netstat -tnlp 2>/dev/null | grep "0.0.0.0:1883" || echo "No IPv4 global listeners"
    
    log "All 9001 port listeners:"
    netstat -tnlp 2>/dev/null | grep ":9001" || echo "No listeners on port 9001"
    
    # 检查配置文件
    log "Configuration file status:"
    if [ -f "$MOSQUITTO_CONF_FILE" ]; then
        log "Config file exists: $MOSQUITTO_CONF_FILE"
        log "Config validation:"
        mosquitto -c "$MOSQUITTO_CONF_FILE" -t 2>&1 || echo "Config validation failed"
        
        log "Listener configurations:"
        grep -n "^listener\|^port\|^bind_address" "$MOSQUITTO_CONF_FILE" || echo "No listener config found"
    else
        log "Config file not found: $MOSQUITTO_CONF_FILE"
    fi
    
    # 检查服务控制状态
    log "Service control status:"
    if [ -d "$SERVICE_CONTROL_DIR" ]; then
        ls -la "$SERVICE_CONTROL_DIR/" 2>/dev/null || echo "Cannot list service control directory"
        
        if [ -f "$DOWN_FILE" ]; then
            log "Service is disabled (down file exists)"
        else
            log "Service is enabled (no down file)"
        fi
    else
        log "Service control directory not found: $SERVICE_CONTROL_DIR"
    fi
    
    log "=== END DIAGNOSTIC ==="
}

# -----------------------------------------------------------------------------
# 辅助函数 - 网络连通性测试
# -----------------------------------------------------------------------------
test_network_connectivity() {
    local target_host="${1:-127.0.0.1}"
    local target_port="${2:-1883}"
    local timeout="${3:-5}"
    
    log_debug "Testing network connectivity to $target_host:$target_port"
    
    # 方法1: nc测试
    if command -v nc >/dev/null 2>&1; then
        if timeout "$timeout" nc -z "$target_host" "$target_port" 2>/dev/null; then
            log_debug "Network connectivity test passed (nc)"
            return 0
        fi
    fi
    
    # 方法2: telnet测试（如果可用）
    if command -v telnet >/dev/null 2>&1; then
        if timeout "$timeout" bash -c "echo '' | telnet $target_host $target_port" 2>/dev/null | grep -q "Connected"; then
            log_debug "Network connectivity test passed (telnet)"
            return 0
        fi
    fi
    
    # 方法3: 使用mosquitto_pub测试
    if command -v mosquitto_pub >/dev/null 2>&1; then
        if timeout "$timeout" mosquitto_pub -h "$target_host" -p "$target_port" -t "test/connectivity" -m "test" -u "test" -P "test" 2>/dev/null; then
            log_debug "Network connectivity test passed (mosquitto_pub)"
            return 0
        fi
    fi
    
    log_debug "Network connectivity test failed"
    return 1
}

# -----------------------------------------------------------------------------
# 辅助函数 - 系统资源检查
# -----------------------------------------------------------------------------
check_system_resources() {
    log_debug "Checking system resources..."
    
    # 检查内存使用
    local memory_info=$(free -m 2>/dev/null | awk 'NR==2{printf "%.1f", $3*100/$2}' 2>/dev/null || echo "unknown")
    log_debug "Memory usage: ${memory_info}%"
    
    # 检查磁盘空间
    local disk_usage=$(df -h "$TERMUX_VAR_DIR" 2>/dev/null | awk 'NR==2{print $5}' 2>/dev/null || echo "unknown")
    log_debug "Disk usage: $disk_usage"
    
    # 检查进程数
    local process_count=$(ps aux | wc -l 2>/dev/null || echo "unknown")
    log_debug "Total processes: $process_count"
    
    # 检查网络连接数
    local connection_count=$(netstat -tn 2>/dev/null | grep -c ESTABLISHED 2>/dev/null || echo "unknown")
    log_debug "Active connections: $connection_count"
    
    return 0
}

# -----------------------------------------------------------------------------
# 辅助函数 - 性能基准测试
# -----------------------------------------------------------------------------
benchmark_mqtt_performance() {
    local test_duration="${1:-10}"
    local test_messages="${2:-100}"
    
    log "Starting MQTT performance benchmark..."
    
    if ! load_mqtt_conf; then
        log_error "Cannot load MQTT config for benchmark"
        return 1
    fi
    
    local start_time=$(date +%s)
    local success_count=0
    local error_count=0
    
    for i in $(seq 1 "$test_messages"); do
        if timeout 5 mosquitto_pub \
            -h "$MQTT_HOST" \
            -p "$MQTT_PORT" \
            -u "$MQTT_USER" \
            -P "$MQTT_PASS" \
            -t "test/benchmark" \
            -m "benchmark_message_$i" 2>/dev/null; then
            success_count=$((success_count + 1))
        else
            error_count=$((error_count + 1))
        fi
        
        # 检查是否超时
        local current_time=$(date +%s)
        if [ $((current_time - start_time)) -gt "$test_duration" ]; then
            break
        fi
    done
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local success_rate=$(( success_count * 100 / (success_count + error_count) ))
    local messages_per_second=$(( success_count / duration ))
    
    log "MQTT Performance Benchmark Results:"
    log "  Duration: ${duration}s"
    log "  Messages sent: $success_count"
    log "  Errors: $error_count"
    log "  Success rate: ${success_rate}%"
    log "  Messages/second: $messages_per_second"
    
    # 上报性能基准结果（如果服务运行中）
    if bash "$SERVICE_DIR/status.sh" --quiet 2>/dev/null; then
        mqtt_report "isg/benchmark/$SERVICE_ID/performance" \
            "{\"duration\":$duration,\"messages_sent\":$success_count,\"errors\":$error_count,\"success_rate\":$success_rate,\"messages_per_second\":$messages_per_second,\"timestamp\":$(date +%s)}" \
            1 2>/dev/null || log "Benchmark report failed"
    fi
    
    return 0
}
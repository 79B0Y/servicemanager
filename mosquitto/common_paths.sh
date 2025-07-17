#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Mosquitto 服务管理 - 统一路径定义和公共函数
# 版本: v1.1.0
# 说明: 所有脚本应在开头引用这些路径定义，确保一致性
# 更新: 添加了autocheck.sh依赖的缺失配置管理函数
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
# 辅助函数 - MQTT 消息发布
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
            log_warn "MQTT publish failed (attempt $attempt/$retries): $topic"
            attempt=$((attempt + 1))
            sleep 2
        fi
    done
    
    log_error "MQTT publish failed after $retries attempts: $topic"
    return 1
}

# -----------------------------------------------------------------------------
# 辅助函数 - 获取 Mosquitto 进程 PID
# -----------------------------------------------------------------------------
get_mosquitto_pid() {
    # 方法1: 通过端口反查进程
    local port_pid=$(netstat -tnlp 2>/dev/null | grep ":$MOSQUITTO_PORT " | awk '{print $7}' | cut -d'/' -f1 | head -n1)
    
    if [ -n "$port_pid" ] && [ "$port_pid" != "-" ]; then
        # 验证进程是否确实是 mosquitto
        local process_name=$(ps -p "$port_pid" -o comm= 2>/dev/null)
        if [[ "$process_name" == *"mosquitto"* ]]; then
            echo "$port_pid"
            return 0
        fi
    fi
    
    # 方法2: 直接查找 mosquitto 进程
    local mosquitto_pid=$(pgrep -f "mosquitto.*mosquitto.conf" | head -n1)
    if [ -n "$mosquitto_pid" ]; then
        echo "$mosquitto_pid"
        return 0
    fi
    
    # 方法3: 通过配置文件查找
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
# 辅助函数 - 端口检测
# -----------------------------------------------------------------------------
check_port_listening() {
    local port="$1"
    local timeout="${2:-5}"
    
    # 方法1: netstat检查
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
# 辅助函数 - 获取版本信息
# -----------------------------------------------------------------------------
get_current_version() {
    mosquitto -h 2>/dev/null | grep -i 'version' | awk '{print $3}' 2>/dev/null || echo "unknown"
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
# 辅助函数 - 获取运行状态
# -----------------------------------------------------------------------------
get_run_status() {
    if get_mosquitto_pid > /dev/null 2>&1; then
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
    local mosquitto_pid=$(get_mosquitto_pid || echo "")
    local uptime_seconds=0
    
    if [ -n "$mosquitto_pid" ]; then
        uptime_seconds=$(ps -o etimes= -p "$mosquitto_pid" 2>/dev/null || echo 0)
        uptime_seconds=$(echo "$uptime_seconds" | tr -d '\n\r\t ' | grep -o '^[0-9]*' || echo 0)
    fi
    
    local uptime_minutes=$(( uptime_seconds / 60 ))
    
    case "$run_status" in
        "running")
            if [ $uptime_minutes -lt 5 ]; then
                echo "mosquitto restarted $uptime_minutes minutes ago"
            elif [ $uptime_minutes -lt 60 ]; then
                echo "mosquitto running for $uptime_minutes minutes"
            else
                local uptime_hours=$(( uptime_minutes / 60 ))
                echo "mosquitto running for $uptime_hours hours"
            fi
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
# 辅助函数 - 获取配置信息 (JSON格式)
# -----------------------------------------------------------------------------
get_config_info() {
    if [ ! -f "$MOSQUITTO_CONF_FILE" ]; then
        echo '{"error": "Config file not found"}'
        return
    fi
    
    local port=$(grep -E "^port[[:space:]]+" "$MOSQUITTO_CONF_FILE" | awk '{print $2}' || echo "1883")
    local bind_address=$(grep -E "^bind_address[[:space:]]+" "$MOSQUITTO_CONF_FILE" | awk '{print $2}' || echo "127.0.0.1")
    local allow_anonymous=$(grep -E "^allow_anonymous[[:space:]]+" "$MOSQUITTO_CONF_FILE" | awk '{print $2}' || echo "false")
    local password_file=$(grep -E "^password_file[[:space:]]+" "$MOSQUITTO_CONF_FILE" | awk '{print $2}' || echo "")
    local log_dest=$(grep -E "^log_dest[[:space:]]+" "$MOSQUITTO_CONF_FILE" | awk '{print $2}' || echo "file")
    local persistence=$(grep -E "^persistence[[:space:]]+" "$MOSQUITTO_CONF_FILE" | awk '{print $2}' || echo "true")
    
    echo "{\"port\":\"$port\",\"bind_address\":\"$bind_address\",\"allow_anonymous\":\"$allow_anonymous\",\"password_file\":\"$password_file\",\"log_dest\":\"$log_dest\",\"persistence\":\"$persistence\"}"
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
# 配置管理函数 - autocheck.sh 依赖的缺失函数
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

# 在 common_paths.sh 中修复 generate_mosquitto_config_from_serviceupdate 函数

generate_mosquitto_config_from_serviceupdate() {
    if ! read_config_from_serviceupdate; then
        log_error "Cannot generate mosquitto.conf: failed to read serviceupdate configuration"
        return 1
    fi
    
    # 确保配置目录存在
    mkdir -p "$(dirname "$MOSQUITTO_CONF_FILE")"
    
    log "Generating mosquitto.conf from serviceupdate.json configuration"
    
    # 处理绑定地址：如果是 0.0.0.0 则绑定所有接口，否则使用指定地址
    local bind_spec=""
    if [ "$CONFIG_BIND_ADDRESS" = "0.0.0.0" ]; then
        bind_spec="0.0.0.0"  # 绑定所有接口
    else
        bind_spec="$CONFIG_BIND_ADDRESS"  # 绑定指定接口
    fi
    
    cat > "$MOSQUITTO_CONF_FILE" << EOF
# Mosquitto Configuration File
# Auto-generated from serviceupdate.json config
# Generated on: $(date)
# Compatible with Mosquitto 2.0+

# Network Settings - 绑定到指定接口
listener $CONFIG_PORT $bind_spec

# WebSocket Support - 也绑定到相同接口
listener $CONFIG_WEBSOCKET_PORT $bind_spec
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

# Memory optimization
max_packet_size 100000000
EOF
    
    # 验证生成的配置文件
    if mosquitto -c "$MOSQUITTO_CONF_FILE" -t 2>/dev/null; then
        log "mosquitto.conf generated and validated successfully"
        log "Binding to: $bind_spec:$CONFIG_PORT (MQTT) and $bind_spec:$CONFIG_WEBSOCKET_PORT (WebSocket)"
        return 0
    else
        log_error "Generated mosquitto.conf failed validation"
        # 显示详细错误信息
        mosquitto -c "$MOSQUITTO_CONF_FILE" -t
        return 1
    fi
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
    
    local current_port=$(grep -E "^port[[:space:]]+" "$MOSQUITTO_CONF_FILE" 2>/dev/null | awk '{print $2}' || echo "")
    local current_bind_address=$(grep -E "^bind_address[[:space:]]+" "$MOSQUITTO_CONF_FILE" 2>/dev/null | awk '{print $2}' || echo "")
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
# 辅助函数 - 配置验证
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
            
            if ! mosquitto -c "$config_file" -t 2>/dev/null; then
                log_error "Mosquitto config validation failed: $config_file"
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
    
    # 发送错误到MQTT
    mqtt_report "isg/error/$SERVICE_ID/status" \
        "{\"error\":\"script_error\",\"line\":$line_number,\"command\":\"$command\",\"exit_code\":$exit_code,\"timestamp\":$(date +%s)}" \
        1 2>/dev/null || true
    
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

#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# isgtrigger 服务管理 - 统一路径定义和公共函数
# 版本: v1.0.0
# 说明: 所有脚本应在开头引用这些路径定义，确保一致性
# =============================================================================

# -----------------------------------------------------------------------------
# 基础标识和环境
# -----------------------------------------------------------------------------
SERVICE_ID="isgtrigger"

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
# isgtrigger 特定路径
# -----------------------------------------------------------------------------
ISGTRIGGER_INSTALL_DIR="/data/data/com.termux/files/usr/var/service/isgtrigger"
ISGTRIGGER_BINARY="$ISGTRIGGER_INSTALL_DIR/isgtrigger"

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
INSTALL_HISTORY_FILE="$BACKUP_DIR/.install_history"
UPDATE_HISTORY_FILE="$BACKUP_DIR/.update_history"

# -----------------------------------------------------------------------------
# 网络和端口
# -----------------------------------------------------------------------------
ISGTRIGGER_PORT="61833"
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
# 下载配置
# -----------------------------------------------------------------------------
ISGTRIGGER_DEB_URL="https://eucfg.linklinkiot.com/isg/isgtrigger-2.2.1-3-g88e159e-88e159e-termux-arm.deb"
ISGTRIGGER_DEB_FILE="isgtrigger.deb"

# -----------------------------------------------------------------------------
# 辅助函数 - 确保目录存在
# -----------------------------------------------------------------------------
ensure_directories() {
    mkdir -p "$LOG_DIR"
    mkdir -p "$BACKUP_DIR"
    mkdir -p "$SERVICE_CONTROL_DIR"
    
    # 确保备份目录下的历史记录文件可以被创建
    touch "$INSTALL_HISTORY_FILE" 2>/dev/null || true
    touch "$UPDATE_HISTORY_FILE" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# 辅助函数 - 加载 MQTT 配置
# -----------------------------------------------------------------------------
load_mqtt_conf() {
    if [ -f "$CONFIG_FILE" ]; then
        MQTT_HOST=$(grep -Po '^[[:space:]]*host:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1)
        MQTT_PORT_CONFIG=$(grep -Po '^[[:space:]]*port:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1)
        MQTT_USER=$(grep -Po '^[[:space:]]*username:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1)
        MQTT_PASS=$(grep -Po '^[[:space:]]*password:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1)
        
        # 设置默认值
        MQTT_HOST=${MQTT_HOST:-127.0.0.1}
        MQTT_PORT_CONFIG=${MQTT_PORT_CONFIG:-1883}
        MQTT_USER=${MQTT_USER:-admin}
        MQTT_PASS=${MQTT_PASS:-admin}
    else
        MQTT_HOST="127.0.0.1"
        MQTT_PORT_CONFIG="1883"
        MQTT_USER="admin"
        MQTT_PASS="admin"
    fi
}

# -----------------------------------------------------------------------------
# 辅助函数 - MQTT 消息发布
# -----------------------------------------------------------------------------
mqtt_report() {
    local topic="$1"
    local payload="$2"
    local log_file="${3:-$LOG_FILE}"
    
    # 检查 mosquitto 是否运行，如果没有运行则只记录日志不发送
    if ! pgrep mosquitto > /dev/null 2>&1; then
        echo "[$(date '+%F %T')] [MQTT-OFFLINE] $topic -> $payload" >> "$log_file"
        return 0
    fi
    
    load_mqtt_conf
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT_CONFIG" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload" 2>/dev/null || true
    echo "[$(date '+%F %T')] [MQTT] $topic -> $payload" >> "$log_file"
}

# -----------------------------------------------------------------------------
# 辅助函数 - 统一日志记录
# -----------------------------------------------------------------------------
log() {
    echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"
}

# -----------------------------------------------------------------------------
# 辅助函数 - 获取 isgtrigger 进程 PID
# -----------------------------------------------------------------------------
get_isgtrigger_pid() {
    local port_pid=$(netstat -tnlp 2>/dev/null | grep ":$ISGTRIGGER_PORT " | awk '{print $7}' | cut -d'/' -f1 | head -n1)
    
    if [ -n "$port_pid" ] && [ "$port_pid" != "-" ]; then
        # 验证是否为 isgtrigger 进程
        local process_name=$(ps -p "$port_pid" -o comm= 2>/dev/null)
        if [ "$process_name" = "isgtrigger" ]; then
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
    dpkg -s isgtrigger 2>/dev/null | grep 'Version' | awk '{print $2}' 2>/dev/null || echo "unknown"
}

get_latest_version() {
    jq -r ".services[] | select(.id==\"$SERVICE_ID\") | .latest_service_version" "$SERVICEUPDATE_FILE" 2>/dev/null || echo "unknown"
}

get_script_version() {
    cat "$VERSION_FILE" 2>/dev/null || echo "v1.0.0"
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
    if command -v isgtrigger >/dev/null 2>&1 || [ -f "$ISGTRIGGER_BINARY" ]; then
        echo "success"
    else
        echo "failed"
    fi
}

# -----------------------------------------------------------------------------
# 辅助函数 - 获取运行状态
# -----------------------------------------------------------------------------
get_run_status() {
    if get_isgtrigger_pid > /dev/null 2>&1; then
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
    local isgtrigger_pid=$(get_isgtrigger_pid || echo "")
    local uptime_seconds=0
    
    if [ -n "$isgtrigger_pid" ]; then
        uptime_seconds=$(ps -o etimes= -p "$isgtrigger_pid" 2>/dev/null || echo 0)
    fi
    
    local uptime_minutes=$(( uptime_seconds / 60 ))
    
    case "$run_status" in
        "running")
            if [ $uptime_minutes -lt 5 ]; then
                echo "isgtrigger restarted $uptime_minutes minutes ago"
            elif [ $uptime_minutes -lt 60 ]; then
                echo "isgtrigger running for $uptime_minutes minutes"
            else
                local uptime_hours=$(( uptime_minutes / 60 ))
                echo "isgtrigger running for $uptime_hours hours"
            fi
            ;;
        "starting")
            echo "isgtrigger is starting up"
            ;;
        "stopping")
            echo "isgtrigger is stopping"
            ;;
        "stopped")
            echo "isgtrigger is not running"
            ;;
        "failed")
            echo "isgtrigger failed to start"
            ;;
        *)
            echo "isgtrigger status unknown"
            ;;
    esac
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
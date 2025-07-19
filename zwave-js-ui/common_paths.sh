#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Z-Wave JS UI 服务管理 - 统一路径定义和公共函数
# 版本: v1.0.0
# 说明: 所有脚本应在开头引用这些路径定义，确保一致性
# 注意: 根据要求，每个脚本使用独立参数，无需依赖此文件
# =============================================================================

# -----------------------------------------------------------------------------
# 基础标识和环境
# -----------------------------------------------------------------------------
SERVICE_ID="zwave-js-ui"
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
SERIAL_RESULT_FILE="/sdcard/isgbackup/serialport/latest.json"
DEFAULT_CONFIG_FILE="$BACKUP_DIR/settings_default.json"
INSTALL_HISTORY_FILE="$BACKUP_DIR/.install_history"
UPDATE_HISTORY_FILE="$BACKUP_DIR/.update_history"

# -----------------------------------------------------------------------------
# 容器内路径 (Proot Ubuntu)
# -----------------------------------------------------------------------------
ZWAVE_INSTALL_DIR="/root/.pnpm-global/global/5/node_modules/zwave-js-ui"
ZWAVE_STORE_DIR="${ZWAVE_STORE_DIR:-$ZWAVE_INSTALL_DIR/store}"
ZWAVE_CONFIG_FILE="$ZWAVE_STORE_DIR/settings.json"

# -----------------------------------------------------------------------------
# 临时文件路径
# -----------------------------------------------------------------------------
TEMP_DIR="$TERMUX_TMP_DIR/${SERVICE_ID}_temp"
RESTORE_TEMP_DIR="$TERMUX_TMP_DIR/restore_temp_$$"

# -----------------------------------------------------------------------------
# 网络和端口
# -----------------------------------------------------------------------------
ZWAVE_PORT="8091"
MQTT_TIMEOUT="10"

# -----------------------------------------------------------------------------
# 脚本参数和配置
# -----------------------------------------------------------------------------
MAX_TRIES="${MAX_TRIES:-30}"
RETRY_INTERVAL="${RETRY_INTERVAL:-60}"
MAX_WAIT="${MAX_WAIT:-300}"
INTERVAL="${INTERVAL:-5}"

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

# -----------------------------------------------------------------------------
# 辅助函数 - MQTT 消息发布
# -----------------------------------------------------------------------------
mqtt_report() {
    local topic="$1"
    local payload="$2"
    local log_file="${3:-$LOG_FILE}"
    
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
# 辅助函数 - 获取 Z-Wave JS UI 进程 PID
# -----------------------------------------------------------------------------
get_zwave_pid() {
    local port_pid=$(netstat -tnlp 2>/dev/null | grep ":$ZWAVE_PORT " | awk '{print $7}' | cut -d'/' -f1 | head -n1)
    
    if [ -n "$port_pid" ] && [ "$port_pid" != "-" ]; then
        # 验证是否为 zwave-js-ui 进程
        local cwd=$(ls -l /proc/$port_pid/cwd 2>/dev/null | grep -o 'zwave-js-ui' || true)
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
    proot-distro login "$PROOT_DISTRO" -- bash -c "
        export SHELL=/data/data/com.termux/files/usr/bin/bash
        export PNPM_HOME=\"/root/.local/share/pnpm\"
        export PATH=\"\$PNPM_HOME:\$PATH\"
        source ~/.bashrc 2>/dev/null || true
        
        # 尝试多种方式获取版本
        if [ -f '$ZWAVE_INSTALL_DIR/package.json' ]; then
            grep -m1 '\"version\"' '$ZWAVE_INSTALL_DIR/package.json' | cut -d'\"' -f4
        elif command -v zwave-js-ui >/dev/null 2>&1; then
            zwave-js-ui --version 2>/dev/null | head -n1 || echo 'unknown'
        else
            echo 'unknown'
        fi
    " 2>/dev/null || echo "unknown"
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
    if proot-distro login "$PROOT_DISTRO" -- test -d "$ZWAVE_INSTALL_DIR"; then
        if proot-distro login "$PROOT_DISTRO" -- test -f "$ZWAVE_INSTALL_DIR/package.json"; then
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
    if get_zwave_pid > /dev/null 2>&1; then
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
    local zwave_pid=$(get_zwave_pid || echo "")
    local uptime_seconds=0
    
    if [ -n "$zwave_pid" ]; then
        uptime_seconds=$(ps -o etimes= -p "$zwave_pid" 2>/dev/null || echo 0)
    fi
    
    local uptime_minutes=$(( uptime_seconds / 60 ))
    
    case "$run_status" in
        "running")
            if [ $uptime_minutes -lt 5 ]; then
                echo "zwave-js-ui restarted $uptime_minutes minutes ago"
            elif [ $uptime_minutes -lt 60 ]; then
                echo "zwave-js-ui running for $uptime_minutes minutes"
            else
                local uptime_hours=$(( uptime_minutes / 60 ))
                echo "zwave-js-ui running for $uptime_hours hours"
            fi
            ;;
        "starting")
            echo "zwave-js-ui is starting up"
            ;;
        "stopping")
            echo "zwave-js-ui is stopping"
            ;;
        "stopped")
            echo "zwave-js-ui is not running"
            ;;
        "failed")
            echo "zwave-js-ui failed to start"
            ;;
        *)
            echo "zwave-js-ui status unknown"
            ;;
    esac
}

# -----------------------------------------------------------------------------
# 辅助函数 - 获取配置信息 (JSON格式)
# -----------------------------------------------------------------------------
get_config_info() {
    if ! proot-distro login "$PROOT_DISTRO" -- test -f "$ZWAVE_CONFIG_FILE"; then
        echo '{"error": "Config file not found"}'
        return
    fi
    
    local config_json=$(proot-distro login "$PROOT_DISTRO" -- python3 -c "
import sys
try:
    import json
    
    with open('$ZWAVE_CONFIG_FILE', 'r') as f:
        config = json.load(f)
    
    result = {
        'port': config.get('zwave', {}).get('port', ''),
        'network_key': 'configured' if config.get('zwave', {}).get('networkKey') else 'not configured',
        'mqtt_enabled': config.get('mqtt', {}).get('enabled', False),
        'mqtt_host': config.get('mqtt', {}).get('host', ''),
        'mqtt_port': config.get('mqtt', {}).get('port', 1883),
        'web_port': config.get('gateway', {}).get('port', 8091)
    }
    print(json.dumps(result))
    
except Exception as e:
    print('{\"error\": \"Failed to parse config\"}')
" 2>/dev/null)
    
    if [ -z "$config_json" ] || [[ "$config_json" == *"error"* ]]; then
        config_json='{"error": "Config not accessible"}'
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

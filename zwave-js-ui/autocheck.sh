#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Z-Wave JS UI 自检脚本
# 版本: v1.0.0
# 功能: 单服务自检、性能监控和健康检查，汇总所有脚本状态
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# 路径和变量定义
# -----------------------------------------------------------------------------
SERVICE_ID="zwave-js-ui"
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"

CONFIG_FILE="$BASE_DIR/configuration.yaml"
SERVICEUPDATE_FILE="$BASE_DIR/serviceupdate.json"
VERSION_FILE="$SERVICE_DIR/VERSION"
ZWAVE_INSTALL_DIR="/root/.local/share/pnpm/global/5/node_modules/zwave-js-ui"
ZWAVE_STORE_DIR="$ZWAVE_INSTALL_DIR/store"
ZWAVE_CONFIG_FILE="$ZWAVE_STORE_DIR/settings.json"

LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/autocheck.log"
DISABLED_FLAG="$SERVICE_DIR/.disabled"
LOCK_FILE_AUTOCHECK="$SERVICE_DIR/.lock_autocheck"
LAST_CHECK_FILE="$SERVICE_DIR/.lastcheck"
BACKUP_DIR="/sdcard/isgbackup/$SERVICE_ID"
UPDATE_HISTORY_FILE="$BACKUP_DIR/.update_history"

ZWAVE_PORT="8091"
MAX_TRIES=30
RETRY_INTERVAL=60

# -----------------------------------------------------------------------------
# 辅助函数
# -----------------------------------------------------------------------------
ensure_directories() {
    mkdir -p "$LOG_DIR"
    mkdir -p "$BACKUP_DIR"
    touch "$UPDATE_HISTORY_FILE" 2>/dev/null || true
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

get_zwave_pid() {
    local port_pid=$(netstat -tnlp 2>/dev/null | grep ":$ZWAVE_PORT " | awk '{print $7}' | cut -d'/' -f1 | head -n1)
    
    if [ -n "$port_pid" ] && [ "$port_pid" != "-" ]; then
        local cwd=$(ls -l /proc/$port_pid/cwd 2>/dev/null | grep -o 'zwave-js-ui' || true)
        if [ -n "$cwd" ]; then
            echo "$port_pid"
            return 0
        fi
    fi
    return 1
}

mqtt_report() {
    local topic="$1"
    local payload="$2"
    
    # 检查 zwave-js-ui 是否运行，如果没有运行则只记录日志不发送
    if ! get_zwave_pid > /dev/null 2>&1; then
        echo "[$(date '+%F %T')] [MQTT-OFFLINE] $topic -> $payload" >> "$LOG_FILE"
        return 0
    fi
    
    load_mqtt_conf
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT_CONFIG" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload" 2>/dev/null || true
    echo "[$(date '+%F %T')] [MQTT] $topic -> $payload" >> "$LOG_FILE"
}

get_current_version() {
    proot-distro login "$PROOT_DISTRO" -- bash -c "
        export SHELL=/data/data/com.termux/files/usr/bin/bash
        export PNPM_HOME=\"/root/.local/share/pnpm\"
        export PATH=\"\$PNPM_HOME:\$PATH\"
        source ~/.bashrc 2>/dev/null || true
        
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
# 获取各脚本状态
# -----------------------------------------------------------------------------
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
    
    # 检查实际安装状态
    if proot-distro login "$PROOT_DISTRO" -- test -d "$ZWAVE_INSTALL_DIR" 2>/dev/null && \
       proot-distro login "$PROOT_DISTRO" -- test -f "$ZWAVE_INSTALL_DIR/package.json" 2>/dev/null; then
        echo "success"
    else
        echo "failed"
    fi
}

get_improved_backup_status() {
    # 检查是否有 backup.sh 进程在运行
    if pgrep -f "$SERVICE_DIR/backup.sh" > /dev/null 2>&1; then
        echo "backuping"
        return
    fi
    
    # 检查备份目录是否有备份文件
    local backup_files=$(ls -1 "$BACKUP_DIR"/zwave-js-ui_backup_*.tar.gz 2>/dev/null | wc -l)
    backup_files=${backup_files:-0}
    
    if [ "$backup_files" -gt 0 ]; then
        echo "success"
    else
        echo "never"
    fi
}

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
        echo "never"
    fi
}

get_improved_restore_status() {
    # 检查是否有 restore.sh 进程在运行
    if pgrep -f "$SERVICE_DIR/restore.sh" > /dev/null 2>&1; then
        echo "restoring"
        return
    fi
    
    # 检查配置文件是否存在
    if proot-distro login "$PROOT_DISTRO" -- test -f "$ZWAVE_CONFIG_FILE"; then
        echo "success"
    else
        echo "never"
    fi
}

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

get_update_info() {
    if [ -f "$UPDATE_HISTORY_FILE" ]; then
        local last_update_line=$(tail -n1 "$UPDATE_HISTORY_FILE" 2>/dev/null)
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
# 主自检流程
# -----------------------------------------------------------------------------
ensure_directories

# 创建锁文件，防止重复执行
exec 200>"$LOCK_FILE_AUTOCHECK"
flock -n 200 || exit 0

NOW=$(date +%s)
RESULT_STATUS="healthy"

log "开始 $SERVICE_ID 自检"
mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"status\":\"start\",\"run\":\"unknown\",\"config\":{},\"install\":\"checking\",\"current_version\":\"unknown\",\"latest_version\":\"unknown\",\"update\":\"checking\",\"message\":\"starting autocheck process\",\"timestamp\":$NOW}"

# -----------------------------------------------------------------------------
# 检查必要脚本是否存在
# -----------------------------------------------------------------------------
for script in start.sh stop.sh install.sh status.sh; do
    if [ ! -f "$SERVICE_DIR/$script" ]; then
        RESULT_STATUS="problem"
        mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"status\":\"problem\",\"message\":\"missing $script\"}"
        exit 1
    fi
done

# -----------------------------------------------------------------------------
# 获取版本信息
# -----------------------------------------------------------------------------
ZWAVE_VERSION=$(get_current_version)
LATEST_ZWAVE_VERSION=$(get_latest_version)
SCRIPT_VERSION=$(get_script_version)
LATEST_SCRIPT_VERSION=$(get_latest_script_version)
UPGRADE_DEPS=$(get_upgrade_dependencies)

# -----------------------------------------------------------------------------
# 获取各脚本状态
# -----------------------------------------------------------------------------
RUN_STATUS=$(get_improved_run_status)
INSTALL_STATUS=$(get_improved_install_status)
BACKUP_STATUS=$(get_improved_backup_status)
UPDATE_STATUS=$(get_improved_update_status)
RESTORE_STATUS=$(get_improved_restore_status)
UPDATE_INFO=$(get_update_info)

log "状态检查结果:"
log "  run: $RUN_STATUS"
log "  install: $INSTALL_STATUS"
log "  backup: $BACKUP_STATUS"
log "  update: $UPDATE_STATUS"
log "  restore: $RESTORE_STATUS"

# -----------------------------------------------------------------------------
# 检查是否被禁用
# -----------------------------------------------------------------------------
if [ -f "$DISABLED_FLAG" ]; then
    CONFIG_INFO=$(get_config_info)
    mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"status\":\"disabled\",\"run\":\"disabled\",\"config\":$CONFIG_INFO,\"install\":\"$INSTALL_STATUS\",\"backup\":\"$BACKUP_STATUS\",\"restore\":\"$RESTORE_STATUS\",\"update\":\"$UPDATE_STATUS\",\"current_version\":\"$ZWAVE_VERSION\",\"latest_version\":\"$LATEST_ZWAVE_VERSION\",\"update_info\":\"$UPDATE_INFO\",\"message\":\"service is disabled\",\"timestamp\":$NOW}"
    RESULT_STATUS="disabled"
    exit 0
fi

# -----------------------------------------------------------------------------
# 检查服务状态并尝试恢复
# -----------------------------------------------------------------------------
if [ "$RUN_STATUS" = "stopped" ]; then
    log "zwave-js-ui 未运行，尝试启动"
    for i in $(seq 1 $MAX_TRIES); do
        bash "$SERVICE_DIR/start.sh"
        sleep $RETRY_INTERVAL
        NEW_RUN_STATUS=$(get_improved_run_status)
        if [ "$NEW_RUN_STATUS" = "running" ]; then
            log "服务在第 $i 次尝试后恢复"
            mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"status\":\"recovered\",\"message\":\"service recovered after restart attempts\",\"timestamp\":$(date +%s)}"
            RUN_STATUS="running"
            break
        fi
        [ $i -eq $MAX_TRIES ] && {
            RESULT_STATUS="problem"
            RUN_STATUS="failed"
        }
    done
fi

# -----------------------------------------------------------------------------
# 检查服务重启情况
# -----------------------------------------------------------------------------
ZWAVE_PID=$(get_zwave_pid || echo "")
if [ -n "$ZWAVE_PID" ]; then
    ZWAVE_UPTIME=$(ps -o etimes= -p "$ZWAVE_PID" 2>/dev/null | head -n1 | awk '{print $1}' || echo 0)
    # 确保是数字，移除任何非数字字符
    ZWAVE_UPTIME=$(echo "$ZWAVE_UPTIME" | tr -d '\n\r\t ' | grep -o '^[0-9]*' || echo 0)
    ZWAVE_UPTIME=${ZWAVE_UPTIME:-0}
else
    ZWAVE_UPTIME=0
fi

LAST_CHECK=$(cat "$LAST_CHECK_FILE" 2>/dev/null | head -n1 | tr -d '\n\r\t ' || echo 0)
# 确保LAST_CHECK是数字
LAST_CHECK=${LAST_CHECK:-0}

if [ "$LAST_CHECK" -gt 0 ] && [ "$ZWAVE_UPTIME" -lt $((NOW - LAST_CHECK)) ]; then
    RESULT_STATUS="problem"
fi
echo "$NOW" > "$LAST_CHECK_FILE"

# -----------------------------------------------------------------------------
# 性能监控
# -----------------------------------------------------------------------------
if [ -n "$ZWAVE_PID" ]; then
    CPU=$(top -b -n 1 -p "$ZWAVE_PID" 2>/dev/null | awk '/'"$ZWAVE_PID"'/ {print $9}' | head -n1)
    MEM=$(top -b -n 1 -p "$ZWAVE_PID" 2>/dev/null | awk '/'"$ZWAVE_PID"'/ {print $10}' | head -n1)
    # 确保是数字
    CPU=${CPU:-0.0}
    MEM=${MEM:-0.0}
else
    CPU="0.0"
    MEM="0.0"
fi

mqtt_report "isg/autocheck/$SERVICE_ID/performance" "{\"cpu\":\"$CPU\",\"mem\":\"$MEM\",\"timestamp\":$NOW}"
mqtt_report "isg/status/$SERVICE_ID/performance" "{\"cpu\":\"$CPU\",\"mem\":\"$MEM\",\"timestamp\":$NOW}"

# -----------------------------------------------------------------------------
# 版本信息上报
# -----------------------------------------------------------------------------
log "script_version: $SCRIPT_VERSION"
log "latest_script_version: $LATEST_SCRIPT_VERSION"
log "zwave_version: $ZWAVE_VERSION"
log "latest_zwave_version: $LATEST_ZWAVE_VERSION"
log "upgrade_dependencies: $UPGRADE_DEPS"

mqtt_report "isg/autocheck/$SERVICE_ID/version" "{\"script_version\":\"$SCRIPT_VERSION\",\"latest_script_version\":\"$LATEST_SCRIPT_VERSION\",\"zwave_version\":\"$ZWAVE_VERSION\",\"latest_zwave_version\":\"$LATEST_ZWAVE_VERSION\",\"upgrade_dependencies\":$UPGRADE_DEPS}"

# -----------------------------------------------------------------------------
# 检查 Web 界面状态
# -----------------------------------------------------------------------------
WEB_STATE="offline"
if timeout 5 nc -z 127.0.0.1 "$ZWAVE_PORT" 2>/dev/null; then
    WEB_STATE="online"
elif [ -n "$ZWAVE_PID" ]; then
    WEB_STATE="starting"
fi

if [ "$WEB_STATE" != "online" ] && [ -n "$ZWAVE_PID" ]; then
    RESULT_STATUS="problem"
fi

# -----------------------------------------------------------------------------
# 获取配置信息和状态消息
# -----------------------------------------------------------------------------
CONFIG_INFO=$(get_config_info 2>/dev/null)
STATUS_MESSAGE=$(generate_status_message "$RUN_STATUS")

# -----------------------------------------------------------------------------
# 生成最终的综合状态消息
# -----------------------------------------------------------------------------
log "autocheck 完成"

# 构建最终状态消息
FINAL_MESSAGE="{"
FINAL_MESSAGE="$FINAL_MESSAGE\"status\":\"$RESULT_STATUS\","
FINAL_MESSAGE="$FINAL_MESSAGE\"run\":\"$RUN_STATUS\","
FINAL_MESSAGE="$FINAL_MESSAGE\"config\":$CONFIG_INFO,"
FINAL_MESSAGE="$FINAL_MESSAGE\"install\":\"$INSTALL_STATUS\","
FINAL_MESSAGE="$FINAL_MESSAGE\"backup\":\"$BACKUP_STATUS\","
FINAL_MESSAGE="$FINAL_MESSAGE\"restore\":\"$RESTORE_STATUS\","
FINAL_MESSAGE="$FINAL_MESSAGE\"update\":\"$UPDATE_STATUS\","
FINAL_MESSAGE="$FINAL_MESSAGE\"current_version\":\"$ZWAVE_VERSION\","
FINAL_MESSAGE="$FINAL_MESSAGE\"latest_version\":\"$LATEST_ZWAVE_VERSION\","
FINAL_MESSAGE="$FINAL_MESSAGE\"update_info\":\"$UPDATE_INFO\","
FINAL_MESSAGE="$FINAL_MESSAGE\"message\":\"$STATUS_MESSAGE\","
FINAL_MESSAGE="$FINAL_MESSAGE\"web_state\":\"$WEB_STATE\","
FINAL_MESSAGE="$FINAL_MESSAGE\"timestamp\":$NOW"
FINAL_MESSAGE="$FINAL_MESSAGE}"

mqtt_report "isg/autocheck/$SERVICE_ID/status" "$FINAL_MESSAGE"

# -----------------------------------------------------------------------------
# 清理日志文件
# -----------------------------------------------------------------------------
trim_log() {
    tail -n 500 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
}
trim_log
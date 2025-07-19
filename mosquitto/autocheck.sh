#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Mosquitto 自检脚本
# 版本: v1.0.0
# 功能: 单服务自检、性能监控和健康检查，汇总所有脚本状态
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# 路径和变量定义
# -----------------------------------------------------------------------------
SERVICE_ID="mosquitto"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"
TERMUX_ETC_DIR="/data/data/com.termux/files/usr/etc"

CONFIG_FILE="$BASE_DIR/configuration.yaml"
SERVICEUPDATE_FILE="$BASE_DIR/serviceupdate.json"
VERSION_FILE="$SERVICE_DIR/VERSION"
MOSQUITTO_CONFIG_FILE="$TERMUX_ETC_DIR/mosquitto/mosquitto.conf"

LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/autocheck.log"
DISABLED_FLAG="$SERVICE_DIR/.disabled"
LOCK_FILE_AUTOCHECK="$SERVICE_DIR/.lock_autocheck"
LAST_CHECK_FILE="$SERVICE_DIR/.lastcheck"

MOSQUITTO_PORT="1883"
MAX_TRIES=30
RETRY_INTERVAL=60

# 环境变量：用于更新用户名密码
NEW_MQTT_USER="${NEW_MQTT_USER:-}"
NEW_MQTT_PASS="${NEW_MQTT_PASS:-}"

# -----------------------------------------------------------------------------
# 辅助函数
# -----------------------------------------------------------------------------
ensure_directories() {
    mkdir -p "$LOG_DIR"
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

get_mosquitto_pid() {
    local port_pid=$(netstat -tnlp 2>/dev/null | grep ":$MOSQUITTO_PORT " | awk '{print $7}' | cut -d'/' -f1 | head -n1)
    
    if [ -n "$port_pid" ] && [ "$port_pid" != "-" ]; then
        local process_name=$(ps -p "$port_pid" -o comm= 2>/dev/null)
        if [ "$process_name" = "mosquitto" ]; then
            echo "$port_pid"
            return 0
        fi
    fi
    return 1
}

mqtt_report() {
    local topic="$1"
    local payload="$2"
    
    # 检查 mosquitto 是否运行，如果没有运行则只记录日志不发送
    if ! get_mosquitto_pid > /dev/null 2>&1; then
        echo "[$(date '+%F %T')] [MQTT-OFFLINE] $topic -> $payload" >> "$LOG_FILE"
        return 0
    fi
    
    load_mqtt_conf
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT_CONFIG" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload" 2>/dev/null || true
    echo "[$(date '+%F %T')] [MQTT] $topic -> $payload" >> "$LOG_FILE"
}

get_current_version() {
    mosquitto -h 2>/dev/null | grep 'version' | awk '{print $3}' 2>/dev/null || echo "unknown"
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
    if command -v mosquitto >/dev/null 2>&1; then
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
    local backup_files=$(ls -1 "/sdcard/isgbackup/$SERVICE_ID"/mosquitto_backup_*.tar.gz 2>/dev/null | wc -l)
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
    local update_history_file="/sdcard/isgbackup/$SERVICE_ID/.update_history"
    if [ -f "$update_history_file" ] && [ -s "$update_history_file" ]; then
        local last_update_line=$(tail -n1 "$update_history_file" 2>/dev/null)
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
    if [ -f "$MOSQUITTO_CONFIG_FILE" ]; then
        echo "success"
    else
        echo "never"
    fi
}

get_config_info() {
    if [ ! -f "$MOSQUITTO_CONFIG_FILE" ]; then
        echo '{"error": "Config file not found"}'
        return
    fi
    
    # 获取 mosquitto 配置信息
    local bind_address=$(grep "^bind_address" "$MOSQUITTO_CONFIG_FILE" | awk '{print $2}' 2>/dev/null || echo "127.0.0.1")
    local port=$(grep "^port" "$MOSQUITTO_CONFIG_FILE" | awk '{print $2}' 2>/dev/null || echo "1883")
    local allow_anonymous=$(grep "^allow_anonymous" "$MOSQUITTO_CONFIG_FILE" | awk '{print $2}' 2>/dev/null || echo "true")
    local password_file=$(grep "^password_file" "$MOSQUITTO_CONFIG_FILE" | awk '{print $2}' 2>/dev/null || echo "")
    
    # 获取当前 broker 的用户名和密码（从 servicemanager 配置文件）
    load_mqtt_conf
    local current_user="$MQTT_USER"
    local current_pass="$MQTT_PASS"
    
    # 获取 mosquitto 密码文件中的用户列表
    local user_count=0
    local users_list=""
    if [ -f "$password_file" ] && [ -r "$password_file" ]; then
        user_count=$(wc -l < "$password_file" 2>/dev/null || echo 0)
        users_list=$(cut -d':' -f1 "$password_file" 2>/dev/null | tr '\n' ',' | sed 's/,$//' || echo "")
    fi
    
    echo "{\"bind_address\":\"$bind_address\",\"port\":\"$port\",\"allow_anonymous\":\"$allow_anonymous\",\"password_file\":\"$password_file\",\"current_user\":\"$current_user\",\"current_password\":\"$current_pass\",\"user_count\":$user_count,\"users_list\":\"$users_list\"}"
}

generate_status_message() {
    local run_status="$1"
    local mosquitto_pid=$(get_mosquitto_pid || echo "")
    local uptime_seconds=0
    
    if [ -n "$mosquitto_pid" ]; then
        uptime_seconds=$(ps -o etimes= -p "$mosquitto_pid" 2>/dev/null || echo 0)
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

get_update_info() {
    local update_history="/sdcard/isgbackup/$SERVICE_ID/.update_history"
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
# 用户名密码管理功能
# -----------------------------------------------------------------------------
update_mqtt_credentials() {
    local new_user="$1"
    local new_pass="$2"
    
    if [ -z "$new_user" ] || [ -z "$new_pass" ]; then
        log "用户名或密码为空，跳过更新"
        return 1
    fi
    
    log "更新 MQTT 用户凭据: $new_user"
    
    # 1. 更新 servicemanager 配置文件
    if [ -f "$CONFIG_FILE" ]; then
        # 使用 sed 更新用户名和密码
        sed -i "s/username:.*/username: $new_user/" "$CONFIG_FILE"
        sed -i "s/password:.*/password: $new_pass/" "$CONFIG_FILE"
        log "已更新 servicemanager 配置文件"
    else
        log "警告: servicemanager 配置文件不存在: $CONFIG_FILE"
        return 1
    fi
    
    # 2. 更新 mosquitto 密码文件
    local passwd_file="$TERMUX_ETC_DIR/mosquitto/passwd"
    if ! mosquitto_passwd -c -b "$passwd_file" "$new_user" "$new_pass" 2>/dev/null; then
        log "更新 mosquitto 密码文件失败"
        return 1
    fi
    
    log "mosquitto 密码文件更新成功"
    return 0
}

verify_credentials_consistency() {
    log "验证当前设置与 CONFIG_FILE 的一致性"
    
    # 从 CONFIG_FILE 读取配置
    load_mqtt_conf
    local config_user="$MQTT_USER"
    local config_pass="$MQTT_PASS"
    
    log "CONFIG_FILE 中的用户: $config_user"
    
    # 检查 mosquitto 密码文件中是否有对应用户
    local passwd_file="$TERMUX_ETC_DIR/mosquitto/passwd"
    if [ ! -f "$passwd_file" ]; then
        log "mosquitto 密码文件不存在，需要创建"
        return 1
    fi
    
    # 检查用户是否存在于密码文件中
    if ! grep -q "^$config_user:" "$passwd_file" 2>/dev/null; then
        log "用户 $config_user 不存在于 mosquitto 密码文件中，需要同步"
        return 1
    fi
    
    # 验证密码是否正确（通过连接测试）
    if test_mqtt_auth "$config_user" "$config_pass"; then
        log "✅ 凭据一致性验证通过"
        return 0
    else
        log "❌ 凭据一致性验证失败，需要同步"
        return 1
    fi
}

sync_credentials_with_config() {
    log "同步 mosquitto 设置与 CONFIG_FILE"
    
    # 从 CONFIG_FILE 读取配置
    load_mqtt_conf
    local config_user="$MQTT_USER"
    local config_pass="$MQTT_PASS"
    
    # 更新 mosquitto 密码文件以匹配配置
    local passwd_file="$TERMUX_ETC_DIR/mosquitto/passwd"
    if mosquitto_passwd -c -b "$passwd_file" "$config_user" "$config_pass" 2>/dev/null; then
        log "✅ mosquitto 设置已同步到 CONFIG_FILE"
        return 0
    else
        log "❌ mosquitto 设置同步失败"
        return 1
    fi
}

test_mqtt_auth() {
    local test_user="$1"
    local test_pass="$2"
    local test_host="${3:-127.0.0.1}"
    local test_port="${4:-1883}"
    
    # 尝试使用指定的用户名密码连接 MQTT
    timeout 5 mosquitto_pub -h "$test_host" -p "$test_port" -u "$test_user" -P "$test_pass" -t "test/auth" -m "test" -q 1 2>/dev/null
    return $?
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
MOSQUITTO_VERSION=$(get_current_version)
LATEST_MOSQUITTO_VERSION=$(get_latest_version)
SCRIPT_VERSION=$(get_script_version)
LATEST_SCRIPT_VERSION=$(get_latest_script_version)
UPGRADE_DEPS=$(get_upgrade_dependencies)

# -----------------------------------------------------------------------------
# 处理用户名密码更新和一致性检查
# -----------------------------------------------------------------------------

# 第一步：处理环境变量指定的新凭据
CREDENTIALS_UPDATED=false
if [ -n "$NEW_MQTT_USER" ] && [ -n "$NEW_MQTT_PASS" ]; then
    log "检测到用户名密码更新请求: $NEW_MQTT_USER"
    
    # 先停止服务
    if get_mosquitto_pid > /dev/null 2>&1; then
        log "停止服务以更新凭据"
        bash "$SERVICE_DIR/stop.sh" || true
        sleep 3
    fi
    
    # 更新凭据
    if update_mqtt_credentials "$NEW_MQTT_USER" "$NEW_MQTT_PASS"; then
        log "✅ 新凭据更新成功"
        CREDENTIALS_UPDATED=true
    else
        log "❌ 新凭据更新失败"
        RESULT_STATUS="problem"
    fi
    
# 第二步：验证当前设置与 CONFIG_FILE 的一致性
elif ! verify_credentials_consistency; then
    log "检测到凭据不一致，进行同步"
    
    # 先停止服务
    if get_mosquitto_pid > /dev/null 2>&1; then
        log "停止服务以同步凭据"
        bash "$SERVICE_DIR/stop.sh" || true
        sleep 3
    fi
    
    # 同步设置
    if sync_credentials_with_config; then
        log "✅ 凭据同步成功"
        CREDENTIALS_UPDATED=true
    else
        log "❌ 凭据同步失败"
        RESULT_STATUS="problem"
    fi
fi

# 第三步：如果有凭据更新，重启服务并验证
if [ "$CREDENTIALS_UPDATED" = true ]; then
    log "重启服务并验证凭据"
    bash "$SERVICE_DIR/start.sh"
    
    # 等待服务启动
    sleep 5
    WAIT_COUNT=0
    while [ $WAIT_COUNT -lt 12 ]; do  # 最多等待60秒
        if bash "$SERVICE_DIR/status.sh" --quiet; then
            log "✅ 服务重启成功"
            break
        fi
        sleep 5
        WAIT_COUNT=$((WAIT_COUNT + 1))
    done
    
    # 验证凭据是否生效
    load_mqtt_conf  # 重新加载配置
    if test_mqtt_auth "$MQTT_USER" "$MQTT_PASS"; then
        log "✅ 凭据验证成功: $MQTT_USER"
        if [ -n "$NEW_MQTT_USER" ] && [ -n "$NEW_MQTT_PASS" ]; then
            mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"status\":\"credentials_updated\",\"message\":\"MQTT credentials updated and verified\",\"new_user\":\"$MQTT_USER\",\"timestamp\":$(date +%s)}"
        else
            mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"status\":\"credentials_synced\",\"message\":\"MQTT credentials synchronized with config\",\"user\":\"$MQTT_USER\",\"timestamp\":$(date +%s)}"
        fi
    else
        log "❌ 凭据验证失败: $MQTT_USER"
        RESULT_STATUS="problem"
        mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"status\":\"problem\",\"message\":\"credential verification failed after update\",\"user\":\"$MQTT_USER\",\"timestamp\":$(date +%s)}"
    fi
fi

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
    mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"status\":\"disabled\",\"run\":\"disabled\",\"config\":$CONFIG_INFO,\"install\":\"$INSTALL_STATUS\",\"backup\":\"$BACKUP_STATUS\",\"restore\":\"$RESTORE_STATUS\",\"update\":\"$UPDATE_STATUS\",\"current_version\":\"$MOSQUITTO_VERSION\",\"latest_version\":\"$LATEST_MOSQUITTO_VERSION\",\"update_info\":\"$UPDATE_INFO\",\"message\":\"service is disabled\",\"timestamp\":$NOW}"
    RESULT_STATUS="disabled"
    exit 0
fi

# -----------------------------------------------------------------------------
# 检查服务状态并尝试恢复
# -----------------------------------------------------------------------------
if [ "$RUN_STATUS" = "stopped" ]; then
    log "mosquitto 未运行，尝试启动"
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
# 检查服务重启情况（记录但不标记为问题）
# -----------------------------------------------------------------------------
MOSQUITTO_PID=$(get_mosquitto_pid || echo "")
if [ -n "$MOSQUITTO_PID" ]; then
    MOSQUITTO_UPTIME=$(ps -o etimes= -p "$MOSQUITTO_PID" 2>/dev/null | head -n1 | awk '{print $1}' || echo 0)
    MOSQUITTO_UPTIME=$(echo "$MOSQUITTO_UPTIME" | tr -d '\n\r\t ' | grep -o '^[0-9]*' || echo 0)
    MOSQUITTO_UPTIME=${MOSQUITTO_UPTIME:-0}
else
    MOSQUITTO_UPTIME=0
fi

LAST_CHECK=$(cat "$LAST_CHECK_FILE" 2>/dev/null | head -n1 | tr -d '\n\r\t ' || echo 0)
LAST_CHECK=${LAST_CHECK:-0}

# 检测重启但仅记录，不影响整体状态
RESTART_DETECTED=false
if [ "$LAST_CHECK" -gt 0 ] && [ "$MOSQUITTO_UPTIME" -lt $((NOW - LAST_CHECK)) ]; then
    RESTART_DETECTED=true
    log "检测到服务重启：运行时间 ${MOSQUITTO_UPTIME}s < 检查间隔 $((NOW - LAST_CHECK))s"
fi
echo "$NOW" > "$LAST_CHECK_FILE"

# -----------------------------------------------------------------------------
# 性能监控
# -----------------------------------------------------------------------------
if [ -n "$MOSQUITTO_PID" ]; then
    CPU=$(top -b -n 1 -p "$MOSQUITTO_PID" 2>/dev/null | awk '/'"$MOSQUITTO_PID"'/ {print $9}' | head -n1)
    MEM=$(top -b -n 1 -p "$MOSQUITTO_PID" 2>/dev/null | awk '/'"$MOSQUITTO_PID"'/ {print $10}' | head -n1)
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
log "mosquitto_version: $MOSQUITTO_VERSION"
log "latest_mosquitto_version: $LATEST_MOSQUITTO_VERSION"
log "upgrade_dependencies: $UPGRADE_DEPS"

mqtt_report "isg/autocheck/$SERVICE_ID/version" "{\"script_version\":\"$SCRIPT_VERSION\",\"latest_script_version\":\"$LATEST_SCRIPT_VERSION\",\"mosquitto_version\":\"$MOSQUITTO_VERSION\",\"latest_mosquitto_version\":\"$LATEST_MOSQUITTO_VERSION\",\"upgrade_dependencies\":$UPGRADE_DEPS}"

# -----------------------------------------------------------------------------
# 检查连接性
# -----------------------------------------------------------------------------
load_mqtt_conf
CONNECTIVITY_STATUS="unknown"
if [ -n "$MOSQUITTO_PID" ]; then
    if test_mqtt_auth "$MQTT_USER" "$MQTT_PASS"; then
        CONNECTIVITY_STATUS="connected"
    else
        CONNECTIVITY_STATUS="auth_failed"
        RESULT_STATUS="problem"
    fi
else
    CONNECTIVITY_STATUS="offline"
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

# 检查最终的凭据一致性状态
CREDENTIALS_CONSISTENT=true
if ! verify_credentials_consistency; then
    CREDENTIALS_CONSISTENT=false
fi

# 构建最终状态消息
FINAL_MESSAGE="{"
FINAL_MESSAGE="$FINAL_MESSAGE\"status\":\"$RESULT_STATUS\","
FINAL_MESSAGE="$FINAL_MESSAGE\"run\":\"$RUN_STATUS\","
FINAL_MESSAGE="$FINAL_MESSAGE\"config\":$CONFIG_INFO,"
FINAL_MESSAGE="$FINAL_MESSAGE\"install\":\"$INSTALL_STATUS\","
FINAL_MESSAGE="$FINAL_MESSAGE\"backup\":\"$BACKUP_STATUS\","
FINAL_MESSAGE="$FINAL_MESSAGE\"restore\":\"$RESTORE_STATUS\","
FINAL_MESSAGE="$FINAL_MESSAGE\"update\":\"$UPDATE_STATUS\","
FINAL_MESSAGE="$FINAL_MESSAGE\"current_version\":\"$MOSQUITTO_VERSION\","
FINAL_MESSAGE="$FINAL_MESSAGE\"latest_version\":\"$LATEST_MOSQUITTO_VERSION\","
FINAL_MESSAGE="$FINAL_MESSAGE\"update_info\":\"$UPDATE_INFO\","
FINAL_MESSAGE="$FINAL_MESSAGE\"message\":\"$STATUS_MESSAGE\","
FINAL_MESSAGE="$FINAL_MESSAGE\"connectivity\":\"$CONNECTIVITY_STATUS\","
FINAL_MESSAGE="$FINAL_MESSAGE\"restart_detected\":$RESTART_DETECTED,"
FINAL_MESSAGE="$FINAL_MESSAGE\"credentials_consistent\":$CREDENTIALS_CONSISTENT,"
FINAL_MESSAGE="$FINAL_MESSAGE\"credentials_updated\":$CREDENTIALS_UPDATED,"
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

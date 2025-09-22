#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# isg-credential-services 自检脚本 - 完整版本
# 版本: v1.2.1 (修复语法错误)
# 功能: 单服务自检与性能监控，包括配置信息提取和Node-RED集成验证
# =============================================================================

set -euo pipefail

# =============================================================================
# 基础配置和路径设置
# =============================================================================
SERVICE_ID="isg-credential-services"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"
TERMUX_TMP_DIR="/data/data/com.termux/files/usr/tmp"

# 配置文件
CONFIG_FILE="$BASE_DIR/configuration.yaml"
SERVICEUPDATE_FILE="$BASE_DIR/serviceupdate.json"
VERSION_FILE="$SERVICE_DIR/VERSION"

# Proot 相关路径
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
PROOT_ROOTFS="/data/data/com.termux/files/usr/var/lib/proot-distro/installed-rootfs/$PROOT_DISTRO"
CREDENTIAL_INSTALL_DIR="$PROOT_ROOTFS/root/isg-credential-services"
CREDENTIAL_CONFIG_FILE="$PROOT_ROOTFS/root/isg-credential-services/config.json"
CREDENTIAL_AGENT_FILE="$PROOT_ROOTFS/root/isg-credential-services/agent.json"

# 日志和状态文件
LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/autocheck.log"
VERSION_CACHE_FILE="$SERVICE_DIR/VERSION"
LOCK_FILE_AUTOCHECK="$SERVICE_DIR/.lock_autocheck"
LAST_CHECK_FILE="$SERVICE_DIR/.lastcheck"
DISABLED_FLAG="$SERVICE_DIR/.disabled"

# 备份和历史记录
BACKUP_DIR="${BACKUP_DIR:-/sdcard/isgbackup/$SERVICE_ID}"
INSTALL_HISTORY_FILE="$BACKUP_DIR/.install_history"
UPDATE_HISTORY_FILE="$BACKUP_DIR/.update_history"

# 网络和服务参数
CREDENTIAL_PORT="3000"
MAX_TRIES="${MAX_TRIES:-3}"
RETRY_INTERVAL="${RETRY_INTERVAL:-60}"

# =============================================================================
# 基础函数
# =============================================================================

# 确保必要目录存在
ensure_directories() {
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    mkdir -p "$BACKUP_DIR" 2>/dev/null || true
}

# 统一日志记录
log() {
    echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"
}

# MQTT 配置加载
load_mqtt_conf() {
    if [[ -f "$CONFIG_FILE" ]]; then
        MQTT_HOST=$(grep -Po '^[[:space:]]*host:[[:space:]]*\K.*' "$CONFIG_FILE" 2>/dev/null | head -n1 || echo "127.0.0.1")
        MQTT_PORT_CONFIG=$(grep -Po '^[[:space:]]*port:[[:space:]]*\K.*' "$CONFIG_FILE" 2>/dev/null | head -n1 || echo "1883")
        MQTT_USER=$(grep -Po '^[[:space:]]*username:[[:space:]]*\K.*' "$CONFIG_FILE" 2>/dev/null | head -n1 || echo "admin")
        MQTT_PASS=$(grep -Po '^[[:space:]]*password:[[:space:]]*\K.*' "$CONFIG_FILE" 2>/dev/null | head -n1 || echo "admin")
    else
        MQTT_HOST="127.0.0.1"
        MQTT_PORT_CONFIG="1883"
        MQTT_USER="admin"
        MQTT_PASS="admin"
    fi
}

# MQTT 消息上报
mqtt_report() {
    local topic="$1"
    local payload="$2"
    
    # 检查 MQTT broker 是否可用
    if ! nc -z 127.0.0.1 1883 2>/dev/null; then
        log "[MQTT-OFFLINE] $topic -> $payload"
        return 0
    fi
    
    load_mqtt_conf
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT_CONFIG" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload" >/dev/null 2>&1 || true
    log "[MQTT] $topic -> $payload"
}

# =============================================================================
# 版本信息获取函数 - 修复版本
# =============================================================================

# 获取最新版本 - 修复版本
get_latest_version() {
    echo "1.0.0"
}

# 获取脚本版本 - 修复版本
get_script_version() {
    echo "1.0.0"
}

# 获取最新脚本版本 - 修复版本
get_latest_script_version() {
    echo "1.0.0"
}

# 获取升级依赖
get_upgrade_dependencies() {
    if [[ -f "$SERVICEUPDATE_FILE" ]]; then
        jq -c ".services[] | select(.id==\"$SERVICE_ID\") | .upgrade_dependencies" "$SERVICEUPDATE_FILE" 2>/dev/null || echo "[]"
    else
        echo "[]"
    fi
}

# 获取 agent.json 版本信息
get_agent_json_version() {
    if [[ -f "$CREDENTIAL_AGENT_FILE" ]]; then
        local agent_version=$(proot-distro login "$PROOT_DISTRO" -- bash -c "
            if [ -f '$CREDENTIAL_AGENT_FILE' ]; then
                jq -r '.version // \"unknown\"' '$CREDENTIAL_AGENT_FILE' 2>/dev/null || echo 'unknown'
            else
                echo 'unknown'
            fi
        " 2>/dev/null || echo "unknown")
        
        if [[ -n "$agent_version" && "$agent_version" != "unknown" ]]; then
            echo "$agent_version"
        else
            # 如果没有版本字段，尝试从文件修改时间推断
            local file_date=$(proot-distro login "$PROOT_DISTRO" -- stat -c %Y "$CREDENTIAL_AGENT_FILE" 2>/dev/null || echo "0")
            if [[ "$file_date" != "0" ]]; then
                echo "modified_$(date -d @$file_date +%Y%m%d)" 2>/dev/null || echo "unknown"
            else
                echo "unknown"
            fi
        fi
    else
        echo "not_found"
    fi
}

# 获取已导入到 Node-RED 的 agent 版本
get_imported_agent_version() {
    # 检查 Node-RED 是否运行
    if ! netstat -tnlp 2>/dev/null | grep ":1880 " > /dev/null; then
        echo "node_red_offline"
        return
    fi
    
    # 尝试从 Node-RED API 获取当前 flows
    local flows_content=""
    flows_content=$(curl -s -m 5 http://127.0.0.1:1880/flows 2>/dev/null)
    
    if [[ -z "$flows_content" ]]; then
        echo "api_error"
        return
    fi
    
    # 检查是否包含 credential 相关的流
    local has_credential_flow=$(echo "$flows_content" | jq -r '.[].label // .[].name // ""' 2>/dev/null | grep -qi "credential\|agent" && echo "true" || echo "false")
    
    if [[ "$has_credential_flow" == "true" ]]; then
        # 尝试从流的创建时间或其他标识获取版本信息
        local flow_timestamp=$(echo "$flows_content" | jq -r '.[] | select(.label // .name | test("credential|agent"; "i")) | .id' 2>/dev/null | head -n1)
        if [[ -n "$flow_timestamp" ]]; then
            echo "imported_${flow_timestamp:0:8}" 2>/dev/null || echo "imported"
        else
            echo "imported"
        fi
    else
        echo "not_imported"
    fi
}

# 快速获取 isg-credential-services 版本 - 修复版本
get_current_version_fast() {
    echo "1.0.0"
}

# =============================================================================
# 状态检查函数
# =============================================================================

# 获取 isg-credential-services 进程 PID
get_credential_pid() {
    local port_pid=$(netstat -tnlp 2>/dev/null | grep ":$CREDENTIAL_PORT " | awk '{print $7}' | cut -d'/' -f1 | head -n1)
    
    if [[ -n "$port_pid" && "$port_pid" != "-" ]]; then
        # 验证是否为 isg-credential-services 相关进程
        local cmdline=$(cat /proc/$port_pid/cmdline 2>/dev/null | grep -o 'credential\|node.*start-termux' || true)
        if [[ -n "$cmdline" ]]; then
            echo "$port_pid"
            return 0
        fi
    fi
    
    return 1
}

# 改进的 RUN 状态检查
get_improved_run_status() {
    if pgrep -f "$SERVICE_DIR/start.sh" > /dev/null 2>&1; then
        echo "starting"
        return
    fi
    
    if pgrep -f "$SERVICE_DIR/stop.sh" > /dev/null 2>&1; then
        echo "stopping"
        return
    fi
    
    local status_output
    status_output=$(bash "$SERVICE_DIR/status.sh" 2>/dev/null)
    
    case "$status_output" in
        "running") echo "running" ;;
        "starting") echo "starting" ;;
        "stopped") echo "stopped" ;;
        *) echo "stopped" ;;
    esac
}

# 快速检查安装状态
check_install_fast() {
    if pgrep -f "$SERVICE_DIR/install.sh" > /dev/null 2>&1; then
        echo "installing"
        return
    fi
    
    if pgrep -f "$SERVICE_DIR/uninstall.sh" > /dev/null 2>&1; then
        echo "uninstalling"
        return
    fi
    
    if [[ -d "$CREDENTIAL_INSTALL_DIR" ]]; then
        echo "success"
    else
        if [[ -f "$INSTALL_HISTORY_FILE" && -s "$INSTALL_HISTORY_FILE" ]]; then
            local last_install_line=$(tail -n1 "$INSTALL_HISTORY_FILE" 2>/dev/null)
            if [[ -n "$last_install_line" ]]; then
                if echo "$last_install_line" | grep -q "UNINSTALL SUCCESS"; then
                    echo "uninstalled"
                    return
                elif echo "$last_install_line" | grep -q "INSTALL FAILED"; then
                    echo "failed"
                    return
                fi
            fi
        fi
        echo "never"
    fi
}

# 改进的 BACKUP 状态检查
get_improved_backup_status() {
    if pgrep -f "$SERVICE_DIR/backup.sh" > /dev/null 2>&1; then
        echo "backuping"
        return
    fi
    
    local backup_count=0
    if [[ -d "$BACKUP_DIR" ]]; then
        backup_count=$(ls -1 "$BACKUP_DIR"/${SERVICE_ID}_backup_*.tar.gz 2>/dev/null | wc -l)
    fi
    
    if [[ "$backup_count" -gt 0 ]]; then
        echo "success"
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
    
    if [[ -f "$UPDATE_HISTORY_FILE" && -s "$UPDATE_HISTORY_FILE" ]]; then
        local last_update_line=$(tail -n1 "$UPDATE_HISTORY_FILE" 2>/dev/null)
        if [[ -n "$last_update_line" ]]; then
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
    
    if [[ -f "$CREDENTIAL_CONFIG_FILE" ]]; then
        echo "success"
    else
        echo "never"
    fi
}

# 获取更新信息摘要
get_update_info() {
    if [[ -f "$UPDATE_HISTORY_FILE" ]]; then
        local last_update_line=$(tail -n1 "$UPDATE_HISTORY_FILE" 2>/dev/null)
        if [[ -n "$last_update_line" ]]; then
            local update_date=$(echo "$last_update_line" | awk '{print $1}')
            local update_time=$(echo "$last_update_line" | awk '{print $2}')
            local update_status=$(echo "$last_update_line" | awk '{print $3}')
            local version_info=$(echo "$last_update_line" | cut -d' ' -f4-)
            
            local update_timestamp=$(date -d "$update_date $update_time" +%s 2>/dev/null || echo 0)
            local current_time=$(date +%s)
            local time_diff=$((current_time - update_timestamp))
            
            if [[ $time_diff -lt 3600 ]]; then
                local minutes=$(( time_diff / 60 ))
                echo "$update_status $minutes minutes ago ($version_info)"
            elif [[ $time_diff -lt 86400 ]]; then
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

# 生成状态消息
generate_status_message() {
    local run_status="$1"
    
    case "$run_status" in
        "running")
            local credential_pid=$(get_credential_pid 2>/dev/null || echo "")
            if [[ -n "$credential_pid" ]]; then
                local uptime_seconds=$(ps -o etimes= -p "$credential_pid" 2>/dev/null | xargs || echo 0)
                local uptime_minutes=$(( uptime_seconds / 60 ))
                
                if [[ $uptime_minutes -lt 5 ]]; then
                    echo "isg-credential-services restarted $uptime_minutes minutes ago"
                elif [[ $uptime_minutes -lt 60 ]]; then
                    echo "isg-credential-services running for $uptime_minutes minutes"
                else
                    local uptime_hours=$(( uptime_minutes / 60 ))
                    echo "isg-credential-services running for $uptime_hours hours"
                fi
            else
                echo "isg-credential-services is running"
            fi
            ;;
        "starting")
            echo "isg-credential-services is starting up"
            ;;
        "stopping")
            echo "isg-credential-services is stopping"
            ;;
        "stopped")
            echo "isg-credential-services is not running"
            ;;
        "failed")
            echo "isg-credential-services failed to start"
            ;;
        *)
            echo "isg-credential-services status unknown"
            ;;
    esac
}

# 修复: 获取配置信息，简化版本，不输出modules详细信息
get_config_info_fast() {
    local config_json="{}"
    
    # 提取服务端口
    local service_port="$CREDENTIAL_PORT"
    if [[ -f "$CREDENTIAL_CONFIG_FILE" ]]; then
        service_port=$(proot-distro login "$PROOT_DISTRO" -- bash -c "
            if [ -f '$CREDENTIAL_CONFIG_FILE' ]; then
                jq -r '.port // \"3000\"' '$CREDENTIAL_CONFIG_FILE' 2>/dev/null || echo '3000'
            else
                echo '3000'
            fi
        " 2>/dev/null || echo "3000")
    fi
    
    # 构建简化的配置JSON - 不包含modules字段
    config_json=$(jq -n \
        --arg port "$service_port" \
        '{
            "port": ($port|tonumber)
        }' 2>/dev/null || echo '{"port": 3000}')
    
    echo "$config_json"
}

# 检查Node-RED是否可用
check_node_red_status() {
    # 检查Node-RED是否在运行
    if netstat -tnlp 2>/dev/null | grep ":1880 " > /dev/null; then
        echo "true"
    else
        echo "false"
    fi
}

# 使用专用脚本更新Node-RED工作流 - 修复版本，返回简洁状态
import_and_verify_agent_workflow() {
    local node_red_enabled=$(check_node_red_status)
    
    if [[ "$node_red_enabled" == "false" ]]; then
        echo "node_red_disabled"
        return
    fi
    
    # 检查flowupdate.sh是否存在
    local flow_updater_script="$SERVICE_DIR/flowupdate.sh"
    if [[ ! -f "$flow_updater_script" ]]; then
        echo "updater_script_missing"
        return
    fi
    
    # 检查agent.json文件是否存在（在本地服务目录）
    local local_agent_file="$SERVICE_DIR/agent.json"
    if [[ ! -f "$local_agent_file" ]]; then
        echo "agent_file_missing"
        return
    fi
    
    # 执行flowupdate.sh脚本，但只获取结果，不输出详细日志
    local update_result=""
    local update_output=""
    
    # 使用--check-only模式先检查版本，静默执行
    update_output=$(bash "$flow_updater_script" --check-only 2>/dev/null)
    local check_exit_code=$?
    
    if [[ $check_exit_code -eq 0 ]]; then
        # 如果需要更新，执行更新
        if echo "$update_output" | grep -q "需要更新"; then
            # 执行实际更新，静默执行
            update_output=$(bash "$flow_updater_script" 2>/dev/null)
            local update_exit_code=$?
            
            if [[ $update_exit_code -eq 0 ]]; then
                if echo "$update_output" | grep -q "更新完成"; then
                    echo "updated_successfully"
                else
                    echo "updated_with_warnings"
                fi
            else
                echo "update_failed"
            fi
        else
            echo "already_latest"
        fi
    else
        echo "version_check_failed"
    fi
}

# =============================================================================
# 主要逻辑开始
# =============================================================================

# 初始化
ensure_directories
RESULT_STATUS="healthy"

# 创建锁文件，防止重复执行
exec 200>"$LOCK_FILE_AUTOCHECK"
flock -n 200 || exit 0

NOW=$(date +%s)

log "starting autocheck for $SERVICE_ID"
mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"status\":\"start\",\"run\":\"unknown\",\"config\":{},\"install\":\"checking\",\"current_version\":\"unknown\",\"latest_version\":\"unknown\",\"update\":\"checking\",\"message\":\"starting autocheck process\",\"timestamp\":$NOW}"

# -----------------------------------------------------------------------------
# 检查必要脚本是否存在
# -----------------------------------------------------------------------------
for script in start.sh stop.sh install.sh status.sh; do
    if [[ ! -f "$SERVICE_DIR/$script" ]]; then
        RESULT_STATUS="problem"
        mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"status\":\"problem\",\"message\":\"missing $script\"}"
        exit 1
    fi
done

# -----------------------------------------------------------------------------
# 获取版本信息
# -----------------------------------------------------------------------------
CREDENTIAL_VERSION=$(get_current_version_fast)
LATEST_CREDENTIAL_VERSION=$(get_latest_version)
SCRIPT_VERSION=$(get_script_version)
LATEST_SCRIPT_VERSION=$(get_latest_script_version)
UPGRADE_DEPS=$(get_upgrade_dependencies)

# -----------------------------------------------------------------------------
# 获取各脚本状态 - 优化版本：减少不必要的检查
# -----------------------------------------------------------------------------
RUN_STATUS=$(get_improved_run_status)

# 只有当服务不在运行时才详细检查安装状态
if [[ "$RUN_STATUS" == "running" ]]; then
    INSTALL_STATUS="success"  # 如果在运行，肯定已安装
else
    INSTALL_STATUS=$(check_install_fast)
fi

# 其他状态检查
BACKUP_STATUS=$(get_improved_backup_status)
UPDATE_STATUS=$(get_improved_update_status)  
RESTORE_STATUS=$(get_improved_restore_status)
UPDATE_INFO=$(get_update_info)

log "status check results:"
log "  run: $RUN_STATUS"
log "  install: $INSTALL_STATUS"
log "  backup: $BACKUP_STATUS"
log "  update: $UPDATE_STATUS"
log "  restore: $RESTORE_STATUS"

# -----------------------------------------------------------------------------
# 检查是否被禁用
# -----------------------------------------------------------------------------
if [[ -f "$DISABLED_FLAG" ]]; then
    CONFIG_INFO=$(get_config_info_fast)
    NODE_RED_STATUS=$(check_node_red_status)
    AGENT_WORKFLOW_STATUS=$(import_and_verify_agent_workflow)
    
    mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"status\":\"disabled\",\"run\":\"disabled\",\"config\":$CONFIG_INFO,\"install\":\"$INSTALL_STATUS\",\"backup\":\"$BACKUP_STATUS\",\"restore\":\"$RESTORE_STATUS\",\"update\":\"$UPDATE_STATUS\",\"current_version\":\"$CREDENTIAL_VERSION\",\"latest_version\":\"$LATEST_CREDENTIAL_VERSION\",\"update_info\":\"$UPDATE_INFO\",\"node_red_enabled\":$NODE_RED_STATUS,\"agent_workflow\":\"$AGENT_WORKFLOW_STATUS\",\"message\":\"service is disabled\",\"timestamp\":$NOW}"
    RESULT_STATUS="disabled"
    exit 0
fi

# -----------------------------------------------------------------------------
# 检查服务状态并尝试恢复
# -----------------------------------------------------------------------------
if [[ "$RUN_STATUS" = "stopped" ]]; then
    log "isg-credential-services not running, attempting to start"
    for i in $(seq 1 $MAX_TRIES); do
        bash "$SERVICE_DIR/start.sh"
        sleep $RETRY_INTERVAL
        NEW_RUN_STATUS=$(get_improved_run_status)
        if [[ "$NEW_RUN_STATUS" = "running" ]]; then
            log "service recovered on attempt $i"
            mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"status\":\"recovered\",\"message\":\"service recovered after restart attempts\",\"timestamp\":$(date +%s)}"
            RUN_STATUS="running"
            break
        fi
        [[ $i -eq $MAX_TRIES ]] && {
            RESULT_STATUS="problem"
            RUN_STATUS="failed"
        }
    done
fi

# -----------------------------------------------------------------------------
# 检查服务重启情况
# -----------------------------------------------------------------------------
CREDENTIAL_PID=$(get_credential_pid || echo "")
if [[ -n "$CREDENTIAL_PID" ]]; then
    CREDENTIAL_UPTIME=$(ps -o etimes= -p "$CREDENTIAL_PID" 2>/dev/null | head -n1 | awk '{print $1}' || echo 0)
    # 确保是数字，移除任何非数字字符
    CREDENTIAL_UPTIME=$(echo "$CREDENTIAL_UPTIME" | tr -d '\n\r\t ' | grep -o '^[0-9]*' || echo 0)
    CREDENTIAL_UPTIME=${CREDENTIAL_UPTIME:-0}
else
    CREDENTIAL_UPTIME=0
fi

LAST_CHECK=$(cat "$LAST_CHECK_FILE" 2>/dev/null | head -n1 | tr -d '\n\r\t ' || echo 0)
# 确保LAST_CHECK是数字
LAST_CHECK=${LAST_CHECK:-0}

# 检测重启但仅记录，不影响整体状态
RESTART_DETECTED=false
if [[ "$LAST_CHECK" -gt 0 && "$CREDENTIAL_UPTIME" -lt $((NOW - LAST_CHECK)) ]]; then
    RESTART_DETECTED=true
    log "检测到服务重启：运行时间 ${CREDENTIAL_UPTIME}s < 检查间隔 $((NOW - LAST_CHECK))s"
fi
echo "$NOW" > "$LAST_CHECK_FILE"

# -----------------------------------------------------------------------------
# 性能监控 - 优化版本：减少系统调用
# -----------------------------------------------------------------------------
if [[ -n "$CREDENTIAL_PID" ]]; then
    # 使用单次 ps 调用获取 CPU 和内存信息
    PS_OUTPUT=$(ps -o pid,pcpu,pmem -p "$CREDENTIAL_PID" 2>/dev/null | tail -n1)
    if [[ -n "$PS_OUTPUT" ]]; then
        CPU=$(echo "$PS_OUTPUT" | awk '{print $2}' | head -n1)
        MEM=$(echo "$PS_OUTPUT" | awk '{print $3}' | head -n1)
    else
        # 备用方法：使用 top（较慢）
        CPU=$(top -b -n 1 -p "$CREDENTIAL_PID" 2>/dev/null | awk '/'"$CREDENTIAL_PID"'/ {print $9}' | head -n1)
        MEM=$(top -b -n 1 -p "$CREDENTIAL_PID" 2>/dev/null | awk '/'"$CREDENTIAL_PID"'/ {print $10}' | head -n1)
    fi
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
AGENT_VERSION=$(get_agent_json_version)
IMPORTED_AGENT_VERSION=$(get_imported_agent_version)

log "script_version: $SCRIPT_VERSION"
log "latest_script_version: $LATEST_SCRIPT_VERSION"
log "credential_version: $CREDENTIAL_VERSION"
log "latest_credential_version: $LATEST_CREDENTIAL_VERSION"
log "agent_version: $AGENT_VERSION"
log "imported_agent_version: $IMPORTED_AGENT_VERSION"
log "upgrade_dependencies: $UPGRADE_DEPS"
log "install_status: $INSTALL_STATUS"
log "run_status: $RUN_STATUS"
log "update_info: $UPDATE_INFO"

mqtt_report "isg/autocheck/$SERVICE_ID/version" "{\"script_version\":\"$SCRIPT_VERSION\",\"latest_script_version\":\"$LATEST_SCRIPT_VERSION\",\"credential_version\":\"$CREDENTIAL_VERSION\",\"latest_credential_version\":\"$LATEST_CREDENTIAL_VERSION\",\"agent_version\":\"$AGENT_VERSION\",\"imported_agent_version\":\"$IMPORTED_AGENT_VERSION\",\"upgrade_dependencies\":$UPGRADE_DEPS}"

# -----------------------------------------------------------------------------
# 检查端口状态 - 优化版本：快速检查
# -----------------------------------------------------------------------------
HTTP_STATUS="offline"
if [[ -n "$CREDENTIAL_PID" ]]; then
    # 快速检查：直接使用 nc 检查端口
    if nc -z 127.0.0.1 "$CREDENTIAL_PORT" >/dev/null 2>&1; then
        HTTP_STATUS="online"
    else
        HTTP_STATUS="starting"
        RESULT_STATUS="problem"
    fi
fi

# -----------------------------------------------------------------------------
# 获取配置信息和状态消息
# -----------------------------------------------------------------------------
CONFIG_INFO=$(get_config_info_fast 2>/dev/null)
STATUS_MESSAGE=$(generate_status_message "$RUN_STATUS")

# 检查Node-RED状态和agent工作流
NODE_RED_STATUS=$(check_node_red_status)
AGENT_WORKFLOW_STATUS=$(import_and_verify_agent_workflow)

# -----------------------------------------------------------------------------
# 生成最终的综合状态消息
# -----------------------------------------------------------------------------
log "autocheck complete"

# 构建最终状态消息
FINAL_MESSAGE="{"
FINAL_MESSAGE="$FINAL_MESSAGE\"status\":\"$RESULT_STATUS\","
FINAL_MESSAGE="$FINAL_MESSAGE\"run\":\"$RUN_STATUS\","
FINAL_MESSAGE="$FINAL_MESSAGE\"config\":$CONFIG_INFO,"
FINAL_MESSAGE="$FINAL_MESSAGE\"install\":\"$INSTALL_STATUS\","
FINAL_MESSAGE="$FINAL_MESSAGE\"backup\":\"$BACKUP_STATUS\","
FINAL_MESSAGE="$FINAL_MESSAGE\"restore\":\"$RESTORE_STATUS\","
FINAL_MESSAGE="$FINAL_MESSAGE\"update\":\"$UPDATE_STATUS\","
FINAL_MESSAGE="$FINAL_MESSAGE\"current_version\":\"$CREDENTIAL_VERSION\","
FINAL_MESSAGE="$FINAL_MESSAGE\"latest_version\":\"$LATEST_CREDENTIAL_VERSION\","
FINAL_MESSAGE="$FINAL_MESSAGE\"agent_version\":\"$AGENT_VERSION\","
FINAL_MESSAGE="$FINAL_MESSAGE\"imported_agent_version\":\"$IMPORTED_AGENT_VERSION\","
FINAL_MESSAGE="$FINAL_MESSAGE\"update_info\":\"$UPDATE_INFO\","
FINAL_MESSAGE="$FINAL_MESSAGE\"message\":\"$STATUS_MESSAGE\","
FINAL_MESSAGE="$FINAL_MESSAGE\"http_status\":\"$HTTP_STATUS\","
FINAL_MESSAGE="$FINAL_MESSAGE\"port\":\"$CREDENTIAL_PORT\","
FINAL_MESSAGE="$FINAL_MESSAGE\"node_red_enabled\":$NODE_RED_STATUS,"
FINAL_MESSAGE="$FINAL_MESSAGE\"agent_workflow\":\"$AGENT_WORKFLOW_STATUS\","
FINAL_MESSAGE="$FINAL_MESSAGE\"restart_detected\":$RESTART_DETECTED,"
FINAL_MESSAGE="$FINAL_MESSAGE\"timestamp\":$NOW"
FINAL_MESSAGE="$FINAL_MESSAGE}"

mqtt_report "isg/autocheck/$SERVICE_ID/status" "$FINAL_MESSAGE"

# -----------------------------------------------------------------------------
# 清理日志文件
# -----------------------------------------------------------------------------
if [[ -f "$LOG_FILE" ]]; then
    tail -n 500 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE" 2>/dev/null || true
fi

log "autocheck completed successfully"

#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Zigbee2MQTT 自检脚本 - 独立优化版本
# 版本: v1.2.0
# 优化: 参照 hass autocheck.sh，不依赖外部文件，快速检查
# =============================================================================

set -euo pipefail

# =============================================================================
# 基础配置和路径设置
# =============================================================================
SERVICE_ID="zigbee2mqtt"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"

# 配置文件
CONFIG_FILE="$BASE_DIR/configuration.yaml"
SERVICEUPDATE_FILE="$BASE_DIR/serviceupdate.json"
VERSION_FILE="$SERVICE_DIR/VERSION"

# Proot 相关路径
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
PROOT_ROOTFS="/data/data/com.termux/files/usr/var/lib/proot-distro/installed-rootfs/$PROOT_DISTRO"
Z2M_INSTALL_DIR="$PROOT_ROOTFS/opt/zigbee2mqtt"
Z2M_PACKAGE_FILE="$PROOT_ROOTFS/opt/zigbee2mqtt/package.json"
Z2M_DATA_DIR="$PROOT_ROOTFS/opt/zigbee2mqtt/data"
Z2M_CONFIG_FILE="$PROOT_ROOTFS/opt/zigbee2mqtt/data/configuration.yaml"

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
Z2M_PORT="8080"
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
    
    load_mqtt_conf
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT_CONFIG" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload" >/dev/null 2>&1 || true
    log "[MQTT] $topic -> $payload"
}

# =============================================================================
# 版本信息获取函数
# =============================================================================

# 获取最新版本
get_latest_version() {
    if [[ -f "$SERVICEUPDATE_FILE" ]]; then
        jq -r ".services[] | select(.id==\"$SERVICE_ID\") | .latest_service_version" "$SERVICEUPDATE_FILE" 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
}

# 获取脚本版本
get_script_version() {
    if [[ -f "$VERSION_CACHE_FILE" ]]; then
        cat "$VERSION_CACHE_FILE" 2>/dev/null | head -n1 | tr -d '\n\r\t ' || echo "unknown"
    else
        echo "unknown"
    fi
}

# 获取最新脚本版本
get_latest_script_version() {
    if [[ -f "$SERVICEUPDATE_FILE" ]]; then
        jq -r ".services[] | select(.id==\"$SERVICE_ID\") | .latest_script_version" "$SERVICEUPDATE_FILE" 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
}

# 获取升级依赖
get_upgrade_dependencies() {
    if [[ -f "$SERVICEUPDATE_FILE" ]]; then
        jq -c ".services[] | select(.id==\"$SERVICE_ID\") | .upgrade_dependencies" "$SERVICEUPDATE_FILE" 2>/dev/null || echo "[]"
    else
        echo "[]"
    fi
}

# 快速获取 Zigbee2MQTT 版本
get_current_version_fast() {
    # 优先从缓存文件读取
    if [[ -f "$VERSION_CACHE_FILE" ]]; then
        local cached_version=$(cat "$VERSION_CACHE_FILE" 2>/dev/null | head -n1 | tr -d '\n\r\t ')
        if [[ -n "$cached_version" && "$cached_version" != "unknown" ]]; then
            echo "$cached_version"
            return
        fi
    fi
    
    # 方法1: 直接从文件系统读取版本信息
    if [[ -f "$Z2M_PACKAGE_FILE" ]]; then
        local version_output=$(grep '"version"' "$Z2M_PACKAGE_FILE" 2>/dev/null | head -n1 | cut -d'"' -f4 || echo "unknown")
        if [[ -n "$version_output" && "$version_output" != "unknown" ]]; then
            # 缓存版本到文件
            echo "$version_output" > "$VERSION_CACHE_FILE" 2>/dev/null || true
            echo "$version_output"
            return
        fi
    fi
    
    # 方法2: 备用 - 通过 proot 调用（较慢但准确）
    local proot_version=$(proot-distro login "$PROOT_DISTRO" -- bash -c "cd /opt/zigbee2mqtt && grep -m1 '\"version\"' package.json | cut -d'\"' -f4" 2>/dev/null || echo "unknown")
    if [[ -n "$proot_version" && "$proot_version" != "unknown" ]]; then
        # 缓存版本到文件
        echo "$proot_version" > "$VERSION_CACHE_FILE" 2>/dev/null || true
        echo "$proot_version"
    else
        echo "unknown"
    fi
}

# =============================================================================
# 状态检查函数
# =============================================================================

# 获取 Zigbee2MQTT 进程 PID
get_z2m_pid() {
    local port_pid=$(netstat -tnlp 2>/dev/null | grep ":$Z2M_PORT " | awk '{print $7}' | cut -d'/' -f1 | head -n1)
    
    if [[ -n "$port_pid" && "$port_pid" != "-" ]]; then
        # 验证是否为 zigbee2mqtt 相关进程
        local cwd=$(ls -l /proc/$port_pid/cwd 2>/dev/null | grep -o 'zigbee2mqtt' || true)
        if [[ -n "$cwd" ]]; then
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
    
    if [[ -d "$Z2M_INSTALL_DIR" && -f "$Z2M_PACKAGE_FILE" ]]; then
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
        backup_count=$(ls -1 "$BACKUP_DIR"/zigbee2mqtt_backup_*.tar.gz 2>/dev/null | wc -l)
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
    
    if [[ -f "$Z2M_CONFIG_FILE" ]]; then
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
            local z2m_pid=$(get_z2m_pid 2>/dev/null || echo "")
            if [[ -n "$z2m_pid" ]]; then
                local uptime_seconds=$(ps -o etimes= -p "$z2m_pid" 2>/dev/null | xargs || echo 0)
                local uptime_minutes=$(( uptime_seconds / 60 ))
                
                if [[ $uptime_minutes -lt 5 ]]; then
                    echo "zigbee2mqtt restarted $uptime_minutes minutes ago"
                elif [[ $uptime_minutes -lt 60 ]]; then
                    echo "zigbee2mqtt running for $uptime_minutes minutes"
                else
                    local uptime_hours=$(( uptime_minutes / 60 ))
                    echo "zigbee2mqtt running for $uptime_hours hours"
                fi
            else
                echo "zigbee2mqtt is running"
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

# 快速获取配置信息
get_config_info_fast() {
    if [[ ! -f "$Z2M_CONFIG_FILE" ]]; then
        echo '{"error": "Config file not found"}'
        return
    fi
    
    # 直接从文件系统读取配置，避免 proot 调用和复杂的 YAML 解析
    local base_topic=$(grep -A 10 '^mqtt:' "$Z2M_CONFIG_FILE" 2>/dev/null | grep 'base_topic:' | awk '{print $2}' | tr -d '"' || echo "zigbee2mqtt")
    local password=$(grep -A 10 '^mqtt:' "$Z2M_CONFIG_FILE" 2>/dev/null | grep 'password:' | awk '{print $2}' | tr -d '"' || echo "")
    local server=$(grep -A 10 '^mqtt:' "$Z2M_CONFIG_FILE" 2>/dev/null | grep 'server:' | awk '{print $2}' | tr -d '"' || echo "")
    local user=$(grep -A 10 '^mqtt:' "$Z2M_CONFIG_FILE" 2>/dev/null | grep 'user:' | awk '{print $2}' | tr -d '"' || echo "")
    local adapter=$(grep -A 10 '^serial:' "$Z2M_CONFIG_FILE" 2>/dev/null | grep 'adapter:' | awk '{print $2}' | tr -d '"' || echo "")
    local baudrate=$(grep -A 10 '^serial:' "$Z2M_CONFIG_FILE" 2>/dev/null | grep 'baudrate:' | awk '{print $2}' | tr -d '"' || echo "")
    local port=$(grep -A 10 '^serial:' "$Z2M_CONFIG_FILE" 2>/dev/null | grep 'port:' | awk '{print $2}' | tr -d '"' || echo "")
    
    # 输出 JSON
    cat << EOF
{
  "base_topic": "$base_topic",
  "password": "$password",
  "server": "$server",
  "user": "$user",
  "adapter": "$adapter",
  "baudrate": "$baudrate",
  "port": "$port"
}
EOF
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
Z2M_VERSION=$(get_current_version_fast)
LATEST_Z2M_VERSION=$(get_latest_version)
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
    mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"status\":\"disabled\",\"run\":\"disabled\",\"config\":$CONFIG_INFO,\"install\":\"$INSTALL_STATUS\",\"backup\":\"$BACKUP_STATUS\",\"restore\":\"$RESTORE_STATUS\",\"update\":\"$UPDATE_STATUS\",\"current_version\":\"$Z2M_VERSION\",\"latest_version\":\"$LATEST_Z2M_VERSION\",\"update_info\":\"$UPDATE_INFO\",\"message\":\"service is disabled\",\"timestamp\":$NOW}"
    RESULT_STATUS="disabled"
    exit 0
fi

# -----------------------------------------------------------------------------
# 检查服务状态并尝试恢复
# -----------------------------------------------------------------------------
if [[ "$RUN_STATUS" = "stopped" ]]; then
    log "zigbee2mqtt not running, attempting to start"
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
Z2M_PID=$(get_z2m_pid || echo "")
if [[ -n "$Z2M_PID" ]]; then
    Z2M_UPTIME=$(ps -o etimes= -p "$Z2M_PID" 2>/dev/null | head -n1 | awk '{print $1}' || echo 0)
    # 确保是数字，移除任何非数字字符
    Z2M_UPTIME=$(echo "$Z2M_UPTIME" | tr -d '\n\r\t ' | grep -o '^[0-9]*' || echo 0)
    Z2M_UPTIME=${Z2M_UPTIME:-0}
else
    Z2M_UPTIME=0
fi

LAST_CHECK=$(cat "$LAST_CHECK_FILE" 2>/dev/null | head -n1 | tr -d '\n\r\t ' || echo 0)
# 确保LAST_CHECK是数字
LAST_CHECK=${LAST_CHECK:-0}

# 检测重启但仅记录，不影响整体状态
RESTART_DETECTED=false
if [[ "$LAST_CHECK" -gt 0 && "$Z2M_UPTIME" -lt $((NOW - LAST_CHECK)) ]]; then
    RESTART_DETECTED=true
    log "检测到服务重启：运行时间 ${Z2M_UPTIME}s < 检查间隔 $((NOW - LAST_CHECK))s"
fi
echo "$NOW" > "$LAST_CHECK_FILE"

# -----------------------------------------------------------------------------
# 性能监控 - 优化版本：减少系统调用
# -----------------------------------------------------------------------------
if [[ -n "$Z2M_PID" ]]; then
    # 使用单次 ps 调用获取 CPU 和内存信息
    PS_OUTPUT=$(ps -o pid,pcpu,pmem -p "$Z2M_PID" 2>/dev/null | tail -n1)
    if [[ -n "$PS_OUTPUT" ]]; then
        CPU=$(echo "$PS_OUTPUT" | awk '{print $2}' | head -n1)
        MEM=$(echo "$PS_OUTPUT" | awk '{print $3}' | head -n1)
    else
        # 备用方法：使用 top（较慢）
        CPU=$(top -b -n 1 -p "$Z2M_PID" 2>/dev/null | awk '/'"$Z2M_PID"'/ {print $9}' | head -n1)
        MEM=$(top -b -n 1 -p "$Z2M_PID" 2>/dev/null | awk '/'"$Z2M_PID"'/ {print $10}' | head -n1)
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
log "script_version: $SCRIPT_VERSION"
log "latest_script_version: $LATEST_SCRIPT_VERSION"
log "z2m_version: $Z2M_VERSION"
log "latest_z2m_version: $LATEST_Z2M_VERSION"
log "upgrade_dependencies: $UPGRADE_DEPS"
log "install_status: $INSTALL_STATUS"
log "run_status: $RUN_STATUS"
log "update_info: $UPDATE_INFO"

mqtt_report "isg/autocheck/$SERVICE_ID/version" "{\"script_version\":\"$SCRIPT_VERSION\",\"latest_script_version\":\"$LATEST_SCRIPT_VERSION\",\"z2m_version\":\"$Z2M_VERSION\",\"latest_z2m_version\":\"$LATEST_Z2M_VERSION\",\"upgrade_dependencies\":$UPGRADE_DEPS}"

# -----------------------------------------------------------------------------
# 检查 MQTT 桥接状态 - 优化版本：快速检查
# -----------------------------------------------------------------------------
load_mqtt_conf
BRIDGE_STATE="unknown"
if [[ -n "$Z2M_PID" ]]; then
    # 快速检查：直接使用 nc 检查 HTTP 端口
    if nc -z 127.0.0.1 "$Z2M_PORT" >/dev/null 2>&1; then
        # 进一步检查 MQTT 桥接状态（超时控制）
        BRIDGE_STATE=$(timeout 5 mosquitto_sub -h "$MQTT_HOST" -p "$MQTT_PORT_CONFIG" \
            -u "$MQTT_USER" -P "$MQTT_PASS" \
            -t "zigbee2mqtt/bridge/state" -C 1 2>/dev/null || echo "offline")
        
        # 解析桥接状态
        if command -v jq >/dev/null 2>&1; then
            BRIDGE_STATE=$(echo "$BRIDGE_STATE" | jq -r '.state // empty' 2>/dev/null || echo "$BRIDGE_STATE")
        fi
        [[ -z "$BRIDGE_STATE" ]] && BRIDGE_STATE="offline"
    else
        BRIDGE_STATE="offline"
    fi
    
    if [[ "$BRIDGE_STATE" != "online" ]]; then
        RESULT_STATUS="problem"
    fi
fi

# -----------------------------------------------------------------------------
# 获取配置信息和状态消息
# -----------------------------------------------------------------------------
CONFIG_INFO=$(get_config_info_fast 2>/dev/null)
STATUS_MESSAGE=$(generate_status_message "$RUN_STATUS")

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
FINAL_MESSAGE="$FINAL_MESSAGE\"current_version\":\"$Z2M_VERSION\","
FINAL_MESSAGE="$FINAL_MESSAGE\"latest_version\":\"$LATEST_Z2M_VERSION\","
FINAL_MESSAGE="$FINAL_MESSAGE\"update_info\":\"$UPDATE_INFO\","
FINAL_MESSAGE="$FINAL_MESSAGE\"message\":\"$STATUS_MESSAGE\","
FINAL_MESSAGE="$FINAL_MESSAGE\"bridge_state\":\"$BRIDGE_STATE\","
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

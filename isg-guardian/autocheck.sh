#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# isg-guardian 自检脚本
# 版本: v1.0.0
# 功能: 单服务自检与性能监控
# =============================================================================

set -euo pipefail

# =============================================================================
# 基础配置和路径设置
# =============================================================================
SERVICE_ID="isg-guardian"
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
GUARDIAN_INSTALL_DIR="$PROOT_ROOTFS/root/isg-guardian"
GUARDIAN_VENV_DIR="$PROOT_ROOTFS/root/isg-guardian/venv"
GUARDIAN_CONFIG_FILE="$PROOT_ROOTFS/root/isg-guardian/config.yaml"
GUARDIAN_DATA_DIR="$PROOT_ROOTFS/root/isg-guardian/data"

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

# 脚本参数
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
        cat "$VERSION_CACHE_FILE" 2>/dev/null | head -n1 | tr -d '\n\r\t ' || echo "v1.0.0"
    else
        echo "v1.0.0"
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

# 快速获取 isg-guardian 版本
get_current_version_fast() {
    # 优先从缓存文件读取
    if [[ -f "$VERSION_CACHE_FILE" ]]; then
        local cached_version=$(cat "$VERSION_CACHE_FILE" 2>/dev/null | head -n1 | tr -d '\n\r\t ')
        if [[ -n "$cached_version" && "$cached_version" != "unknown" && "$cached_version" != "v1.0.0" ]]; then
            echo "$cached_version"
            return
        fi
    fi
    
    # 使用标准版本获取方法
    local proot_version=$(proot-distro login "$PROOT_DISTRO" -- bash -c '
        if [ -f "/root/isg-guardian/venv/bin/activate" ]; then
            source "/root/isg-guardian/venv/bin/activate"
            cd "/root/isg-guardian"
            if [ -f "isg-guardian" ]; then
                grep "VERSION = " isg-guardian 2>/dev/null | sed "s/.*VERSION = [\"'"'"']\(.*\)[\"'"'"'].*/\1/" || echo "unknown"
            else
                echo "unknown"
            fi
        else
            echo "unknown"
        fi
    ' 2>/dev/null || echo "unknown")
    
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

# 获取 isg-guardian 进程 PID
get_guardian_pid() {
    local pid=$(proot-distro login "$PROOT_DISTRO" -- bash -c "pgrep -f 'isg-guardian' | head -n1" 2>/dev/null || echo "")
    
    if [[ -n "$pid" ]]; then
        # 验证是否为 isg-guardian 相关进程
        local cmdline=$(proot-distro login "$PROOT_DISTRO" -- bash -c "cat /proc/$pid/cmdline 2>/dev/null | tr '\0' ' ' | grep -i 'isg-guardian'" 2>/dev/null || echo "")
        if [[ -n "$cmdline" ]]; then
            echo "$pid"
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
    
    if [[ -d "$GUARDIAN_INSTALL_DIR" && -d "$GUARDIAN_VENV_DIR" ]]; then
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
        backup_count=$(ls -1 "$BACKUP_DIR"/isg-guardian_backup_*.tar.gz 2>/dev/null | wc -l)
    fi
    
    if [[ "$backup_count" -gt 0 ]]; then
        echo "success"
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
    
    if [[ -f "$GUARDIAN_CONFIG_FILE" || -d "$GUARDIAN_DATA_DIR" ]]; then
        echo "success"
    else
        echo "never"
    fi
}

# 生成状态消息
generate_status_message() {
    local run_status="$1"
    
    case "$run_status" in
        "running")
            local guardian_pid=$(get_guardian_pid 2>/dev/null || echo "")
            if [[ -n "$guardian_pid" ]]; then
                local uptime_seconds=$(proot-distro login "$PROOT_DISTRO" -- bash -c "ps -o etimes= -p $guardian_pid 2>/dev/null | head -n1 | awk '{print \$1}'" 2>/dev/null || echo 0)
                local uptime_minutes=$(( uptime_seconds / 60 ))
                
                if [[ $uptime_minutes -lt 5 ]]; then
                    echo "isg-guardian restarted $uptime_minutes minutes ago"
                elif [[ $uptime_minutes -lt 60 ]]; then
                    echo "isg-guardian running for $uptime_minutes minutes"
                else
                    local uptime_hours=$(( uptime_minutes / 60 ))
                    echo "isg-guardian running for $uptime_hours hours"
                fi
            else
                echo "isg-guardian is running"
            fi
            ;;
        "starting")
            echo "isg-guardian is starting up"
            ;;
        "stopping")
            echo "isg-guardian is stopping"
            ;;
        "stopped")
            echo "isg-guardian is not running"
            ;;
        "failed")
            echo "isg-guardian failed to start"
            ;;
        *)
            echo "isg-guardian status unknown"
            ;;
    esac
}

# 简化配置信息获取，只提取 mqtt 配置和 ADB 连接配置
get_config_info_fast() {
    if [[ ! -f "$GUARDIAN_CONFIG_FILE" ]]; then
        echo '{"error": "Config file not found"}'
        return
    fi
    
    # 只提取 mqtt 配置信息
    local mqtt_broker=$(grep -A5 'mqtt:' "$GUARDIAN_CONFIG_FILE" 2>/dev/null | grep 'broker:' | sed -E 's/.*broker: *['"'"'"](.*)['"'"'"]/\1/' || echo "")
    local mqtt_username=$(grep -A5 'mqtt:' "$GUARDIAN_CONFIG_FILE" 2>/dev/null | grep 'username:' | sed -E 's/.*username: *['"'"'"](.*)['"'"'"]/\1/' || echo "")
    local mqtt_enabled=$(grep -A5 'mqtt:' "$GUARDIAN_CONFIG_FILE" 2>/dev/null | grep 'enabled:' | sed -E 's/.*enabled: *(.*)/\1/' || echo "false")
    
    # ADB 连接配置（如果存在）
    local adb_host=$(grep -A5 'adb:' "$GUARDIAN_CONFIG_FILE" 2>/dev/null | grep 'host:' | sed -E 's/.*host: *['"'"'"](.*)['"'"'"]/\1/' || echo "")
    local adb_port=$(grep -A5 'adb:' "$GUARDIAN_CONFIG_FILE" 2>/dev/null | grep 'port:' | sed -E 's/.*port: *([0-9]+).*/\1/' || echo "")
    
    # 输出简化的 JSON
    cat << EOF
{
  "mqtt_broker": "$mqtt_broker",
  "mqtt_username": "$mqtt_username",
  "mqtt_enabled": $mqtt_enabled,
  "adb_host": "$adb_host",
  "adb_port": "$adb_port"
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
mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"status\":\"start\",\"run\":\"unknown\",\"config\":{},\"install\":\"checking\",\"current_version\":\"unknown\",\"latest_version\":\"unknown\",\"message\":\"starting autocheck process\",\"timestamp\":$NOW}"

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
FINAL_MESSAGE="$FINAL_MESSAGE\"current_version\":\"$GUARDIAN_VERSION\","
FINAL_MESSAGE="$FINAL_MESSAGE\"latest_version\":\"$LATEST_GUARDIAN_VERSION\","
FINAL_MESSAGE="$FINAL_MESSAGE\"message\":\"$STATUS_MESSAGE\","
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
GUARDIAN_VERSION=$(get_current_version_fast)
LATEST_GUARDIAN_VERSION=$(get_latest_version)
SCRIPT_VERSION=$(get_script_version)
LATEST_SCRIPT_VERSION=$(get_latest_script_version)

# -----------------------------------------------------------------------------
# 获取各脚本状态
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
RESTORE_STATUS=$(get_improved_restore_status)

log "status check results:"
log "  run: $RUN_STATUS"
log "  install: $INSTALL_STATUS"
log "  backup: $BACKUP_STATUS"
log "  restore: $RESTORE_STATUS"

# -----------------------------------------------------------------------------
# 检查是否被禁用
# -----------------------------------------------------------------------------
if [[ -f "$DISABLED_FLAG" ]]; then
    CONFIG_INFO=$(get_config_info_fast)
    mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"status\":\"disabled\",\"run\":\"disabled\",\"config\":$CONFIG_INFO,\"install\":\"$INSTALL_STATUS\",\"backup\":\"$BACKUP_STATUS\",\"restore\":\"$RESTORE_STATUS\",\"current_version\":\"$GUARDIAN_VERSION\",\"latest_version\":\"$LATEST_GUARDIAN_VERSION\",\"message\":\"service is disabled\",\"timestamp\":$NOW}"
    RESULT_STATUS="disabled"
    exit 0
fi

# -----------------------------------------------------------------------------
# 检查服务状态并尝试恢复
# -----------------------------------------------------------------------------
if [[ "$RUN_STATUS" = "stopped" ]]; then
    log "isg-guardian not running, attempting to start"
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
GUARDIAN_PID=$(get_guardian_pid || echo "")
if [[ -n "$GUARDIAN_PID" ]]; then
    GUARDIAN_UPTIME=$(proot-distro login "$PROOT_DISTRO" -- bash -c "ps -o etimes= -p $GUARDIAN_PID 2>/dev/null | head -n1 | awk '{print \$1}'" 2>/dev/null || echo 0)
    # 确保是数字，移除任何非数字字符
    GUARDIAN_UPTIME=$(echo "$GUARDIAN_UPTIME" | tr -d '\n\r\t ' | grep -o '^[0-9]*' || echo 0)
    GUARDIAN_UPTIME=${GUARDIAN_UPTIME:-0}
else
    GUARDIAN_UPTIME=0
fi

LAST_CHECK=$(cat "$LAST_CHECK_FILE" 2>/dev/null | head -n1 | tr -d '\n\r\t ' || echo 0)
# 确保LAST_CHECK是数字
LAST_CHECK=${LAST_CHECK:-0}

# 检测重启但仅记录，不影响整体状态
RESTART_DETECTED=false
if [[ "$LAST_CHECK" -gt 0 && "$GUARDIAN_UPTIME" -lt $((NOW - LAST_CHECK)) ]]; then
    RESTART_DETECTED=true
    log "检测到服务重启：运行时间 ${GUARDIAN_UPTIME}s < 检查间隔 $((NOW - LAST_CHECK))s"
fi
echo "$NOW" > "$LAST_CHECK_FILE"

# -----------------------------------------------------------------------------
# 性能监控
# -----------------------------------------------------------------------------
if [[ -n "$GUARDIAN_PID" ]]; then
    # 使用单次调用获取 CPU 和内存信息
    PS_OUTPUT=$(proot-distro login "$PROOT_DISTRO" -- bash -c "ps -o pid,pcpu,pmem -p $GUARDIAN_PID 2>/dev/null | tail -n1" || echo "")
    if [[ -n "$PS_OUTPUT" ]]; then
        CPU=$(echo "$PS_OUTPUT" | awk '{print $2}' | head -n1)
        MEM=$(echo "$PS_OUTPUT" | awk '{print $3}' | head -n1)
    else
        CPU="0.0"
        MEM="0.0"
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
log "guardian_version: $GUARDIAN_VERSION"
log "latest_guardian_version: $LATEST_GUARDIAN_VERSION"
log "install_status: $INSTALL_STATUS"
log "run_status: $RUN_STATUS"

mqtt_report "isg/autocheck/$SERVICE_ID/version" "{\"script_version\":\"$SCRIPT_VERSION\",\"latest_script_version\":\"$LATEST_SCRIPT_VERSION\",\"guardian_version\":\"$GUARDIAN_VERSION\",\"latest_guardian_version\":\"$LATEST_GUARDIAN_VERSION\"}"

# -----------------------------------------------------------------------------
# 获取配置信息和状态消息
# -----------------------------------------------------------------------------
CONFIG_INFO=$(get_config_info_fast 2>/dev/null)
STATUS_MESSAGE=$(generate_status_message "$RUN_STATUS")

# -----------------------------------------------------------------------------

#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Z-Wave JS UI 自检脚本 - 独立优化版本
# 版本: v2.0.0 
# 优化: 直接文件访问，减少 proot 调用，不依赖 common_paths.sh
# 参照: Home Assistant autocheck.sh 的最佳实践
# =============================================================================

set -euo pipefail

# =============================================================================
# 基础配置和路径设置
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_ID="zwave-js-ui"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"

# 日志和配置文件
LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/autocheck.log"
CONFIG_FILE="$BASE_DIR/configuration.yaml"
SERVICEUPDATE_FILE="$BASE_DIR/serviceupdate.json"
VERSION_FILE="$SERVICE_DIR/VERSION"

# Proot 相关路径
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
PROOT_ROOTFS="/data/data/com.termux/files/usr/var/lib/proot-distro/installed-rootfs/$PROOT_DISTRO"
FAST_ZUI_INSTALL="$PROOT_ROOTFS/root/.pnpm-global/global/5/node_modules/zwave-js-ui"
FAST_ZUI_CONFIG="$PROOT_ROOTFS/root/.pnpm-global/global/5/node_modules/zwave-js-ui/store"
ZUI_VENV_DIR="/root/.pnpm-global"

# 备份和历史记录
BACKUP_DIR="${BACKUP_DIR:-/sdcard/isgbackup/$SERVICE_ID}"
INSTALL_HISTORY_FILE="$BACKUP_DIR/.install_history"
UPDATE_HISTORY_FILE="$BACKUP_DIR/.update_history"

# 状态文件
VERSION_CACHE_FILE="$SERVICE_DIR/VERSION"
LOCK_FILE_AUTOCHECK="$SERVICE_DIR/.lock_autocheck"
LAST_CHECK_FILE="$SERVICE_DIR/.lastcheck"
DISABLED_FLAG="$SERVICE_DIR/.disabled"

# 网络和服务参数
ZUI_PORT="8091"
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
        MQTT_PORT=$(grep -Po '^[[:space:]]*port:[[:space:]]*\K.*' "$CONFIG_FILE" 2>/dev/null | head -n1 || echo "1883")
        MQTT_USER=$(grep -Po '^[[:space:]]*username:[[:space:]]*\K.*' "$CONFIG_FILE" 2>/dev/null | head -n1 || echo "admin")
        MQTT_PASS=$(grep -Po '^[[:space:]]*password:[[:space:]]*\K.*' "$CONFIG_FILE" 2>/dev/null | head -n1 || echo "admin")
    else
        MQTT_HOST="127.0.0.1"
        MQTT_PORT="1883"
        MQTT_USER="admin"
        MQTT_PASS="admin"
    fi
}

# MQTT 消息上报
mqtt_report() {
    local topic="$1"
    local payload="$2"
    load_mqtt_conf
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload" >/dev/null 2>&1 || true
    log "[MQTT] $topic -> $payload"
}

# =============================================================================
# 版本信息获取函数
# =============================================================================

# 获取最新 Z-Wave JS UI 版本
get_latest_zui_version() {
    if [[ -f "$SERVICEUPDATE_FILE" ]]; then
        jq -r ".services[] | select(.id==\"$SERVICE_ID\") | .latest_service_version" "$SERVICEUPDATE_FILE" 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
}

# 获取脚本版本
get_script_version() {
    if [[ -f "$VERSION_FILE" ]]; then
        cat "$VERSION_FILE" 2>/dev/null | head -n1 || echo "unknown"
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

# 快速获取 Z-Wave JS UI 版本
get_zui_version_fast() {
    if [[ -f "$FAST_ZUI_INSTALL/package.json" ]]; then
        # 方法1: 优先从缓存的 VERSION 文件读取
        if [[ -f "$VERSION_CACHE_FILE" ]]; then
            local cached_version=$(cat "$VERSION_CACHE_FILE" 2>/dev/null | head -n1 | tr -d '\n\r\t ')
            if [[ -n "$cached_version" && "$cached_version" != "unknown" ]]; then
                echo "$cached_version"
                return
            fi
        fi
        
        # 方法2: 直接从 package.json 读取版本
        local version_output=$(grep -Po '"version":\s*"\K[^"]+' "$FAST_ZUI_INSTALL/package.json" 2>/dev/null)
        if [[ -n "$version_output" ]]; then
            echo "$version_output"
            return
        fi
        
        # 方法3: 备用 - 通过 proot 调用（较慢但准确）
        local proot_version=$(proot-distro login "$PROOT_DISTRO" -- bash -c "
            export PNPM_HOME=/root/.pnpm-global
            export PATH=\$PNPM_HOME:\$PATH
            source ~/.bashrc 2>/dev/null || true
            
            if [ -f '$FAST_ZUI_INSTALL/package.json' ]; then
                grep -Po '\"version\":\s*\"\K[^\"]+' '$FAST_ZUI_INSTALL/package.json'
            elif command -v pnpm >/dev/null 2>&1; then
                pnpm list -g zwave-js-ui 2>/dev/null | grep 'zwave-js-ui@' | sed -E 's/.*zwave-js-ui@([0-9.]+).*/\1/' || echo 'unknown'
            else
                echo 'unknown'
            fi
        " 2>/dev/null || echo "unknown")
        
        if [[ -n "$proot_version" && "$proot_version" != "unknown" ]]; then
            # 缓存版本到文件，下次可以快速读取
            echo "$proot_version" > "$VERSION_CACHE_FILE" 2>/dev/null || true
            echo "$proot_version"
            return
        fi
        
        echo "unknown"
    else
        echo "unknown"
    fi
}

# =============================================================================
# 状态检查函数
# =============================================================================

# 获取 Z-Wave JS UI 进程 PID
get_zui_pid() {
    local pids=$(pgrep -f 'zwave-js-ui\|zwavejs2mqtt' 2>/dev/null)
    for pid in $pids; do
        if netstat -tnlp 2>/dev/null | grep -q ":$ZUI_PORT.*$pid/"; then
            echo "$pid"
            return 0
        fi
    done
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
    
    if [[ -f "$FAST_ZUI_INSTALL/package.json" && -d "$FAST_ZUI_INSTALL" ]]; then
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
        backup_count=$(ls -1 "$BACKUP_DIR"/zwave-js-ui_backup_*.tar.gz 2>/dev/null | wc -l)
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
    
    if [[ -f "$FAST_ZUI_CONFIG/settings.json" ]]; then
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
            local zui_pid=$(get_zui_pid 2>/dev/null || echo "")
            if [[ -n "$zui_pid" ]]; then
                local uptime_seconds=$(ps -o etimes= -p "$zui_pid" 2>/dev/null | xargs || echo 0)
                local uptime_minutes=$(( uptime_seconds / 60 ))
                
                if [[ $uptime_minutes -lt 5 ]]; then
                    echo "Z-Wave JS UI restarted $uptime_minutes minutes ago"
                elif [[ $uptime_minutes -lt 60 ]]; then
                    echo "Z-Wave JS UI running for $uptime_minutes minutes"
                else
                    local uptime_hours=$(( uptime_minutes / 60 ))
                    echo "Z-Wave JS UI running for $uptime_hours hours"
                fi
            else
                echo "Z-Wave JS UI is running"
            fi
            ;;
        "starting")
            echo "Z-Wave JS UI is starting up"
            ;;
        "stopping")
            echo "Z-Wave JS UI is stopping"
            ;;
        "stopped")
            echo "Z-Wave JS UI is not running"
            ;;
        "failed")
            echo "Z-Wave JS UI failed to start"
            ;;
        *)
            echo "Z-Wave JS UI status unknown"
            ;;
    esac
}

# 快速获取配置信息
get_config_info_fast() {
    local config_file="$FAST_ZUI_CONFIG/settings.json"
    if [[ ! -f "$config_file" ]]; then
        echo '{"error": "Config file not found"}'
        return
    fi
    
    # 使用简化解析，避免复杂的 proot 调用
    local web_port=8091
    local serial_port="unknown"
    local mqtt_host="127.0.0.1"
    local mqtt_port=1883
    local hass_discovery=false
    
    # 快速解析主要配置项
    if command -v python3 >/dev/null 2>&1; then
        local config_json=$(python3 -c "
import json
try:
    with open('$config_file', 'r') as f:
        config = json.load(f)
    
    result = {
        'web_port': config.get('gateway', {}).get('port', 8091),
        'serial_port': config.get('zwave', {}).get('port', 'unknown'),
        'serial_exists': False,  # 简化检查
        'detection_method': 'script_available' if __import__('os').path.exists('$BASE_DIR/detect_serial_adapters.py') else 'manual',
        'mqtt_host': config.get('mqtt', {}).get('host', '127.0.0.1'),
        'mqtt_port': config.get('mqtt', {}).get('port', 1883),
        'mqtt_user': config.get('mqtt', {}).get('username', 'admin'),
        'hass_discovery': config.get('gateway', {}).get('hassDiscovery', False)
    }
    print(json.dumps(result))
except:
    print('{\"error\": \"failed to parse config\"}')
" 2>/dev/null || echo '{"error": "parse failed"}')
        echo "$config_json"
    else
        # 输出默认 JSON
        cat << EOF
{
  "web_port": $web_port,
  "serial_port": "$serial_port",
  "serial_exists": false,
  "detection_method": "unknown",
  "mqtt_host": "$mqtt_host",
  "mqtt_port": $mqtt_port,
  "mqtt_user": "admin",
  "hass_discovery": $hass_discovery
}
EOF
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
ZUI_VERSION=$(get_zui_version_fast)
LATEST_ZUI_VERSION=$(get_latest_zui_version)
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
    mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"status\":\"disabled\",\"run\":\"disabled\",\"config\":$CONFIG_INFO,\"install\":\"$INSTALL_STATUS\",\"backup\":\"$BACKUP_STATUS\",\"restore\":\"$RESTORE_STATUS\",\"update\":\"$UPDATE_STATUS\",\"current_version\":\"$ZUI_VERSION\",\"latest_version\":\"$LATEST_ZUI_VERSION\",\"update_info\":\"$UPDATE_INFO\",\"message\":\"service is disabled\",\"timestamp\":$NOW}"
    RESULT_STATUS="disabled"
    exit 0
fi

# -----------------------------------------------------------------------------
# 检查服务状态并尝试恢复
# -----------------------------------------------------------------------------
if [[ "$RUN_STATUS" = "stopped" ]]; then
    log "Z-Wave JS UI not running, attempting to start"
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
ZUI_PID=$(get_zui_pid || echo "")
if [[ -n "$ZUI_PID" ]]; then
    ZUI_UPTIME=$(ps -o etimes= -p "$ZUI_PID" 2>/dev/null | head -n1 | awk '{print $1}' || echo 0)
    # 确保是数字，移除任何非数字字符
    ZUI_UPTIME=$(echo "$ZUI_UPTIME" | tr -d '\n\r\t ' | grep -o '^[0-9]*' || echo 0)
    ZUI_UPTIME=${ZUI_UPTIME:-0}
else
    ZUI_UPTIME=0
fi

LAST_CHECK=$(cat "$LAST_CHECK_FILE" 2>/dev/null | head -n1 | tr -d '\n\r\t ' || echo 0)
# 确保LAST_CHECK是数字
LAST_CHECK=${LAST_CHECK:-0}

if [[ "$LAST_CHECK" -gt 0 && "$ZUI_UPTIME" -lt $((NOW - LAST_CHECK)) ]]; then
    RESULT_STATUS="problem"
fi
echo "$NOW" > "$LAST_CHECK_FILE"

# -----------------------------------------------------------------------------
# 性能监控 - 优化版本：减少系统调用
# -----------------------------------------------------------------------------
if [[ -n "$ZUI_PID" ]]; then
    # 使用单次 ps 调用获取 CPU 和内存信息
    PS_OUTPUT=$(ps -o pid,pcpu,pmem -p "$ZUI_PID" 2>/dev/null | tail -n1)
    if [[ -n "$PS_OUTPUT" ]]; then
        CPU=$(echo "$PS_OUTPUT" | awk '{print $2}' | head -n1)
        MEM=$(echo "$PS_OUTPUT" | awk '{print $3}' | head -n1)
    else
        # 备用方法：使用 top（较慢）
        CPU=$(top -b -n 1 -p "$ZUI_PID" 2>/dev/null | awk '/'"$ZUI_PID"'/ {print $9}' | head -n1)
        MEM=$(top -b -n 1 -p "$ZUI_PID" 2>/dev/null | awk '/'"$ZUI_PID"'/ {print $10}' | head -n1)
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
log "zui_version: $ZUI_VERSION"
log "latest_zui_version: $LATEST_ZUI_VERSION"
log "upgrade_dependencies: $UPGRADE_DEPS"
log "install_status: $INSTALL_STATUS"
log "run_status: $RUN_STATUS"
log "update_info: $UPDATE_INFO"

mqtt_report "isg/autocheck/$SERVICE_ID/version" "{\"script_version\":\"$SCRIPT_VERSION\",\"latest_script_version\":\"$LATEST_SCRIPT_VERSION\",\"zui_version\":\"$ZUI_VERSION\",\"latest_zui_version\":\"$LATEST_ZUI_VERSION\",\"upgrade_dependencies\":$UPGRADE_DEPS}"

# -----------------------------------------------------------------------------
# 检查 HTTP 端口状态 - 优化版本：快速检查
# -----------------------------------------------------------------------------
HTTP_AVAILABLE="false"
ZWAVE_STATUS="offline"
if [[ -n "$ZUI_PID" ]]; then
    # 快速检查：直接使用 nc 检查端口
    if nc -z 127.0.0.1 "$ZUI_PORT" >/dev/null 2>&1; then
        HTTP_AVAILABLE="true"
        
        # 尝试检查 Z-Wave 控制器状态（如果有健康检查端点）
        if timeout 5 curl -s "http://127.0.0.1:$ZUI_PORT/health" >/dev/null 2>&1; then
            ZWAVE_STATUS="online"
        elif timeout 5 curl -s "http://127.0.0.1:$ZUI_PORT/" >/dev/null 2>&1; then
            ZWAVE_STATUS="online"
        else
            ZWAVE_STATUS="starting"
        fi
    else
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
FINAL_MESSAGE="$FINAL_MESSAGE\"current_version\":\"$ZUI_VERSION\","
FINAL_MESSAGE="$FINAL_MESSAGE\"latest_version\":\"$LATEST_ZUI_VERSION\","
FINAL_MESSAGE="$FINAL_MESSAGE\"update_info\":\"$UPDATE_INFO\","
FINAL_MESSAGE="$FINAL_MESSAGE\"message\":\"$STATUS_MESSAGE\","
FINAL_MESSAGE="$FINAL_MESSAGE\"http_available\":\"$HTTP_AVAILABLE\","
FINAL_MESSAGE="$FINAL_MESSAGE\"zwave_status\":\"$ZWAVE_STATUS\","
FINAL_MESSAGE="$FINAL_MESSAGE\"zui_port\":\"$ZUI_PORT\","
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

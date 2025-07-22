#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Home Assistant 自检脚本 - 修复版本
# 版本: v1.4.1 
# 问题修复: run 字段只返回 starting/running/stopped，而不是完整的 status.sh 输出
# =============================================================================

set -euo pipefail

# 加载统一路径定义
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common_paths.sh" || {
    echo "Error: Cannot load common paths"
    exit 1
}

# 设置脚本特定的日志文件
LOG_FILE="$LOG_FILE_AUTOCHECK"

# 确保必要目录存在
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
    if [ ! -f "$SERVICE_DIR/$script" ]; then
        RESULT_STATUS="problem"
        mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"status\":\"problem\",\"message\":\"missing $script\"}"
        exit 1
    fi
done

# -----------------------------------------------------------------------------
# 获取版本信息 - 优化版本：使用直接文件访问
# -----------------------------------------------------------------------------
# 从 common_paths.sh 获取路径定义，但优化版本信息获取
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
PROOT_ROOTFS="/data/data/com.termux/files/usr/var/lib/proot-distro/installed-rootfs/$PROOT_DISTRO"
FAST_HA_BINARY="$PROOT_ROOTFS/root/homeassistant/bin/hass"
FAST_HA_CONFIG="$PROOT_ROOTFS/root/.homeassistant"

# 快速获取 HA 版本
get_ha_version_fast() {
    if [[ -f "$FAST_HA_BINARY" ]]; then
        # 尝试从 VERSION 文件读取（如果存在）
        local version_file="$SERVICE_DIR/VERSION.yaml"
        if [[ -f "$version_file" ]]; then
            local cached_version=$(grep -Po 'version: \K.*' "$version_file" 2>/dev/null | head -n1)
            if [[ -n "$cached_version" && "$cached_version" != "unknown" ]]; then
                echo "$cached_version"
                return
            fi
        fi
        
        # 尝试快速解析 Python 包版本
        if command -v python3 >/dev/null 2>&1; then
            local version_output=$(python3 -c "
import sys, os
sys.path.insert(0, '$PROOT_ROOTFS/root/homeassistant/lib/python3.11/site-packages')
try:
    import homeassistant
    print(homeassistant.__version__)
except:
    print('unknown')
" 2>/dev/null || echo "unknown")
            if [[ "$version_output" != "unknown" ]]; then
                echo "$version_output"
                return
            fi
        fi
        
        # 备用：通过 proot 调用（较慢）
        proot-distro login "$PROOT_DISTRO" -- bash -c "source $HA_VENV_DIR/bin/activate && hass --version" 2>/dev/null | head -n1 || echo "unknown"
    else
        echo "unknown"
    fi
}

# 快速检查安装状态
check_install_fast() {
    if [[ -f "$FAST_HA_BINARY" && -d "$FAST_HA_CONFIG" ]]; then
        echo "success"
    else
        echo "failed"
    fi
}

HA_VERSION=$(get_ha_version_fast)
LATEST_HA_VERSION=$(get_latest_ha_version)
SCRIPT_VERSION=$(get_script_version)
LATEST_SCRIPT_VERSION=$(get_latest_script_version)
UPGRADE_DEPS=$(get_upgrade_dependencies)

# -----------------------------------------------------------------------------
# 获取各脚本状态 - 优化版本：减少不必要的检查
# -----------------------------------------------------------------------------
# 优化：使用快速检查方法
RUN_STATUS=$(get_improved_run_status)

# 只有当服务不在运行时才详细检查安装状态
if [[ "$RUN_STATUS" == "running" ]]; then
    INSTALL_STATUS="success"  # 如果在运行，肯定已安装
else
    INSTALL_STATUS=$(check_install_fast)
fi

# 其他状态检查保持原有逻辑，但可以优化
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
if [ -f "$DISABLED_FLAG" ]; then
    CONFIG_INFO=$(get_config_info)
    mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"status\":\"disabled\",\"run\":\"disabled\",\"config\":$CONFIG_INFO,\"install\":\"$INSTALL_STATUS\",\"backup\":\"$BACKUP_STATUS\",\"restore\":\"$RESTORE_STATUS\",\"update\":\"$UPDATE_STATUS\",\"current_version\":\"$HA_VERSION\",\"latest_version\":\"$LATEST_HA_VERSION\",\"update_info\":\"$UPDATE_INFO\",\"message\":\"service is disabled\",\"timestamp\":$NOW}"
    RESULT_STATUS="disabled"
    exit 0
fi

# -----------------------------------------------------------------------------
# 检查服务状态并尝试恢复
# -----------------------------------------------------------------------------
if [ "$RUN_STATUS" = "stopped" ]; then
    log "Home Assistant not running, attempting to start"
    for i in $(seq 1 $MAX_TRIES); do
        bash "$SERVICE_DIR/start.sh"
        sleep $RETRY_INTERVAL
        NEW_RUN_STATUS=$(get_improved_run_status)
        if [ "$NEW_RUN_STATUS" = "running" ]; then
            log "service recovered on attempt $i"
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
HA_PID=$(get_ha_pid || echo "")
if [ -n "$HA_PID" ]; then
    HA_UPTIME=$(ps -o etimes= -p "$HA_PID" 2>/dev/null | head -n1 | awk '{print $1}' || echo 0)
    # 确保是数字，移除任何非数字字符
    HA_UPTIME=$(echo "$HA_UPTIME" | tr -d '\n\r\t ' | grep -o '^[0-9]*' || echo 0)
    HA_UPTIME=${HA_UPTIME:-0}
else
    HA_UPTIME=0
fi

LAST_CHECK=$(cat "$LAST_CHECK_FILE" 2>/dev/null | head -n1 | tr -d '\n\r\t ' || echo 0)
# 确保LAST_CHECK是数字
LAST_CHECK=${LAST_CHECK:-0}

if [ "$LAST_CHECK" -gt 0 ] && [ "$HA_UPTIME" -lt $((NOW - LAST_CHECK)) ]; then
    RESULT_STATUS="problem"
fi
echo "$NOW" > "$LAST_CHECK_FILE"

# -----------------------------------------------------------------------------
# 性能监控 - 优化版本：减少系统调用
# -----------------------------------------------------------------------------
if [ -n "$HA_PID" ]; then
    # 使用单次 ps 调用获取 CPU 和内存信息
    PS_OUTPUT=$(ps -o pid,pcpu,pmem -p "$HA_PID" 2>/dev/null | tail -n1)
    if [[ -n "$PS_OUTPUT" ]]; then
        CPU=$(echo "$PS_OUTPUT" | awk '{print $2}' | head -n1)
        MEM=$(echo "$PS_OUTPUT" | awk '{print $3}' | head -n1)
    else
        # 备用方法：使用 top（较慢）
        CPU=$(top -b -n 1 -p "$HA_PID" 2>/dev/null | awk '/'"$HA_PID"'/ {print $9}' | head -n1)
        MEM=$(top -b -n 1 -p "$HA_PID" 2>/dev/null | awk '/'"$HA_PID"'/ {print $10}' | head -n1)
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
log "ha_version: $HA_VERSION"
log "latest_ha_version: $LATEST_HA_VERSION"
log "upgrade_dependencies: $UPGRADE_DEPS"
log "install_status: $INSTALL_STATUS"
log "run_status: $RUN_STATUS"
log "update_info: $UPDATE_INFO"

mqtt_report "isg/autocheck/$SERVICE_ID/version" "{\"script_version\":\"$SCRIPT_VERSION\",\"latest_script_version\":\"$LATEST_SCRIPT_VERSION\",\"ha_version\":\"$HA_VERSION\",\"latest_ha_version\":\"$LATEST_HA_VERSION\",\"upgrade_dependencies\":$UPGRADE_DEPS}"

# -----------------------------------------------------------------------------
# 检查 HTTP 端口状态 - 优化版本：快速检查
# -----------------------------------------------------------------------------
HTTP_AVAILABLE="false"
if [ -n "$HA_PID" ]; then
    # 快速检查：直接使用 nc 检查端口，避免调用 check_ha_port 函数
    if nc -z 127.0.0.1 "$HA_PORT" >/dev/null 2>&1; then
        HTTP_AVAILABLE="true"
    else
        RESULT_STATUS="problem"
    fi
fi

# -----------------------------------------------------------------------------
# 获取配置信息和状态消息 - 优化版本：缓存和快速读取
# -----------------------------------------------------------------------------
# 快速获取配置信息：直接读取文件而不是通过 proot
get_config_info_fast() {
    local config_file="$FAST_HA_CONFIG/configuration.yaml"
    if [[ ! -f "$config_file" ]]; then
        echo '{"error": "Config file not found"}'
        return
    fi
    
    # 使用简化解析，避免复杂的 proot 调用
    local http_port=8123
    local log_level="info"
    local timezone="Asia/Shanghai"
    local name="Home"
    local frontend_enabled=true
    
    # 快速解析主要配置项
    if grep -q "server_port:" "$config_file" 2>/dev/null; then
        http_port=$(grep "server_port:" "$config_file" | head -n1 | sed 's/.*:[[:space:]]*//' | tr -d '[:space:]')
    fi
    
    if grep -q "time_zone:" "$config_file" 2>/dev/null; then
        timezone=$(grep "time_zone:" "$config_file" | head -n1 | sed 's/.*:[[:space:]]*//' | tr -d '"' | tr -d "'")
    fi
    
    if grep -q "^[[:space:]]*name:" "$config_file" 2>/dev/null; then
        name=$(grep "^[[:space:]]*name:" "$config_file" | head -n1 | sed 's/.*:[[:space:]]*//' | tr -d '"' | tr -d "'")
    fi
    
    # 输出 JSON
    cat << EOF
{
  "http_port": $http_port,
  "db_url": "default",
  "log_level": "$log_level",
  "timezone": "$timezone",
  "name": "$name",
  "frontend_enabled": $frontend_enabled
}
EOF
}

CONFIG_INFO=$(get_config_info_fast 2>/dev/null)
STATUS_MESSAGE=$(generate_status_message "$RUN_STATUS")

# -----------------------------------------------------------------------------
# 生成最终的综合状态消息
# -----------------------------------------------------------------------------
log "autocheck complete"

# 构建最终状态消息
FINAL_MESSAGE="{"
FINAL_MESSAGE="$FINAL_MESSAGE\"status\":\"$RESULT_STATUS\","
FINAL_MESSAGE="$FINAL_MESSAGE\"run\":\"$RUN_STATUS\","  # 修复：只返回简单状态值
FINAL_MESSAGE="$FINAL_MESSAGE\"config\":$CONFIG_INFO,"
FINAL_MESSAGE="$FINAL_MESSAGE\"install\":\"$INSTALL_STATUS\","
FINAL_MESSAGE="$FINAL_MESSAGE\"backup\":\"$BACKUP_STATUS\","
FINAL_MESSAGE="$FINAL_MESSAGE\"restore\":\"$RESTORE_STATUS\","
FINAL_MESSAGE="$FINAL_MESSAGE\"update\":\"$UPDATE_STATUS\","
FINAL_MESSAGE="$FINAL_MESSAGE\"current_version\":\"$HA_VERSION\","
FINAL_MESSAGE="$FINAL_MESSAGE\"latest_version\":\"$LATEST_HA_VERSION\","
FINAL_MESSAGE="$FINAL_MESSAGE\"update_info\":\"$UPDATE_INFO\","
FINAL_MESSAGE="$FINAL_MESSAGE\"message\":\"$STATUS_MESSAGE\","
FINAL_MESSAGE="$FINAL_MESSAGE\"http_available\":\"$HTTP_AVAILABLE\","
FINAL_MESSAGE="$FINAL_MESSAGE\"timestamp\":$NOW"
FINAL_MESSAGE="$FINAL_MESSAGE}"

mqtt_report "isg/autocheck/$SERVICE_ID/status" "$FINAL_MESSAGE"

# -----------------------------------------------------------------------------
# 清理日志文件
# -----------------------------------------------------------------------------
trim_log "$LOG_FILE"

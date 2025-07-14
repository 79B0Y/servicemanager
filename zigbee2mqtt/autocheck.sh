#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Zigbee2MQTT 自检脚本
# 版本: v1.1.0
# 功能: 单服务自检、性能监控和健康检查，汇总所有脚本状态
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
# 获取版本信息
# -----------------------------------------------------------------------------
Z2M_VERSION=$(get_current_version)
LATEST_Z2M_VERSION=$(get_latest_version)
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
    mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"status\":\"disabled\",\"run\":\"disabled\",\"config\":$CONFIG_INFO,\"install\":\"$INSTALL_STATUS\",\"backup\":\"$BACKUP_STATUS\",\"restore\":\"$RESTORE_STATUS\",\"update\":\"$UPDATE_STATUS\",\"current_version\":\"$Z2M_VERSION\",\"latest_version\":\"$LATEST_Z2M_VERSION\",\"update_info\":\"$UPDATE_INFO\",\"message\":\"service is disabled\",\"timestamp\":$NOW}"
    RESULT_STATUS="disabled"
    exit 0
fi

# -----------------------------------------------------------------------------
# 检查服务状态并尝试恢复
# -----------------------------------------------------------------------------
if [ "$RUN_STATUS" = "stopped" ]; then
    log "zigbee2mqtt not running, attempting to start"
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
Z2M_PID=$(get_z2m_pid || echo "")
if [ -n "$Z2M_PID" ]; then
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

if [ "$LAST_CHECK" -gt 0 ] && [ "$Z2M_UPTIME" -lt $((NOW - LAST_CHECK)) ]; then
    RESULT_STATUS="problem"
fi
echo "$NOW" > "$LAST_CHECK_FILE"

# -----------------------------------------------------------------------------
# 性能监控
# -----------------------------------------------------------------------------
if [ -n "$Z2M_PID" ]; then
    CPU=$(top -b -n 1 -p "$Z2M_PID" 2>/dev/null | awk '/'"$Z2M_PID"'/ {print $9}' | head -n1)
    MEM=$(top -b -n 1 -p "$Z2M_PID" 2>/dev/null | awk '/'"$Z2M_PID"'/ {print $10}' | head -n1)
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
# 检查 MQTT 桥接状态
# -----------------------------------------------------------------------------
load_mqtt_conf
BRIDGE_STATE=$(timeout 10 mosquitto_sub -h "$MQTT_HOST" -p "$MQTT_PORT" \
    -u "$MQTT_USER" -P "$MQTT_PASS" \
    -t "zigbee2mqtt/bridge/state" -C 1 2>/dev/null || echo "unknown")

# 解析桥接状态
if command -v jq >/dev/null 2>&1; then
    BRIDGE_STATE=$(echo "$BRIDGE_STATE" | jq -r '.state // empty' 2>/dev/null || echo "$BRIDGE_STATE")
fi
[ -z "$BRIDGE_STATE" ] && BRIDGE_STATE="offline"

if [ "$BRIDGE_STATE" != "online" ] && [ -n "$Z2M_PID" ]; then
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

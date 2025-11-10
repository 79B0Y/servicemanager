#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# isg-adb-server 自检与性能监控脚本
# 版本: v1.0.0
# 功能: 单服务自检、性能监控、异常检测和自动恢复
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# 路径和变量定义
# -----------------------------------------------------------------------------
SERVICE_ID="isg-adb-server"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"

CONFIG_FILE="$BASE_DIR/configuration.yaml"
LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/autocheck.log"
LOCK_FILE="$SERVICE_DIR/.lock_autocheck"
LAST_CHECK_FILE="$SERVICE_DIR/.lastcheck"

ADB_PORT="5555"
ADB_HOST="127.0.0.1"
ADB_DEVICE="${ADB_HOST}:${ADB_PORT}"

# 监控阈值
MAX_RESTART_COUNT=3
RESTART_INTERVAL=300  # 5分钟内最多重启3次
CHECK_INTERVAL=60     # 检查间隔（秒）

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

mqtt_report() {
    local topic="$1"
    local payload="$2"
    
    if ! nc -z 127.0.0.1 1883 2>/dev/null; then
        echo "[$(date '+%F %T')] [MQTT-OFFLINE] $topic -> $payload" >> "$LOG_FILE"
        return 0
    fi
    
    load_mqtt_conf
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT_CONFIG" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload" 2>/dev/null || true
}

check_adb_connected() {
    adb devices 2>/dev/null | grep -q "$ADB_DEVICE" && return 0 || return 1
}

get_service_info() {
    local version=$(pkg show android-tools 2>/dev/null | grep -oP '(?<=Version: )[0-9.r\-]+' | head -n1 || echo "unknown")
    local devices=$(adb devices 2>/dev/null | tail -n +2 | grep -v "^$" | wc -l || echo "0")
    
    echo "android-tools version: $version"
    echo "connected devices: $devices"
    if check_adb_connected; then
        echo "target device: $ADB_DEVICE (connected)"
    else
        echo "target device: $ADB_DEVICE (not connected)"
    fi
}

check_service_health() {
    if ! command -v adb >/dev/null 2>&1; then
        echo "not_installed"
        return 3
    fi
    
    if check_adb_connected; then
        echo "healthy"
        return 0
    else
        echo "disconnected"
        return 1
    fi
}

get_adb_metrics() {
    if ! check_adb_connected; then
        echo "{}"
        return
    fi
    
    local devices=$(adb devices 2>/dev/null | tail -n +2 | grep -v "^$" | wc -l || echo "0")
    local device_list=$(adb devices 2>/dev/null | tail -n +2 | grep -v "^$" | awk '{print $1}' | tr '\n' ',' | sed 's/,$//' || echo "")
    
    jq -n \
        --arg device "$ADB_DEVICE" \
        --arg port "$ADB_PORT" \
        --argjson device_count "$devices" \
        --arg device_list "$device_list" \
        '{device: $device, port: ($port|tonumber), device_count: $device_count, devices: $device_list}' 2>/dev/null || echo "{}"
}

record_restart() {
    local timestamp=$(date +%s)
    echo "$timestamp" >> "$SERVICE_DIR/.restart_history"
    
    # 清理超过时间窗口的记录
    if [ -f "$SERVICE_DIR/.restart_history" ]; then
        local cutoff=$((timestamp - RESTART_INTERVAL))
        grep -E "^[0-9]+$" "$SERVICE_DIR/.restart_history" | awk -v c="$cutoff" '$1 > c' > "$SERVICE_DIR/.restart_history.tmp" || true
        mv "$SERVICE_DIR/.restart_history.tmp" "$SERVICE_DIR/.restart_history" 2>/dev/null || true
    fi
}

get_restart_count() {
    if [ ! -f "$SERVICE_DIR/.restart_history" ]; then
        echo 0
        return
    fi
    
    local count=$(wc -l < "$SERVICE_DIR/.restart_history" 2>/dev/null || echo 0)
    echo "$count"
}

try_restart_service() {
    local restart_count=$(get_restart_count)
    
    if [ "$restart_count" -ge "$MAX_RESTART_COUNT" ]; then
        log "重启次数已达上限 ($restart_count/$MAX_RESTART_COUNT)，停止自动重启"
        mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"restart_limit_reached\",\"restart_count\":$restart_count,\"max_restarts\":$MAX_RESTART_COUNT,\"message\":\"restart limit reached, manual intervention required\",\"timestamp\":$(date +%s)}"
        return 1
    fi
    
    log "尝试重新连接 ADB（第 $((restart_count + 1)) 次）"
    mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"restarting\",\"restart_count\":$((restart_count + 1)),\"message\":\"attempting ADB reconnection\",\"timestamp\":$(date +%s)}"
    
    # 先断开连接
    adb disconnect "$ADB_DEVICE" 2>/dev/null || true
    sleep 2
    
    # 再重新连接
    if adb connect "$ADB_DEVICE" 2>/dev/null; then
        record_restart
        log "ADB 重新连接成功"
        mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"restart_success\",\"restart_count\":$((restart_count + 1)),\"message\":\"ADB reconnected successfully\",\"timestamp\":$(date +%s)}"
        return 0
    else
        log "ADB 重新连接失败"
        mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"restart_failed\",\"restart_count\":$((restart_count + 1)),\"message\":\"ADB reconnection failed\",\"timestamp\":$(date +%s)}"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# 主检查流程
# -----------------------------------------------------------------------------
ensure_directories

# 检查服务是否被禁用
DISABLED_FLAG="$SERVICE_DIR/.disabled"
if [ -f "$DISABLED_FLAG" ]; then
    log "服务已被禁用 (.disabled 标志存在)，跳过检查"
    mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"disabled\",\"message\":\"service disabled, skipping check\",\"timestamp\":$(date +%s)}"
    exit 0
fi

# 检查是否有其他检查进程在运行
if [ -f "$LOCK_FILE" ]; then
    LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
        log "另一个检查进程正在运行 (PID: $LOCK_PID)，退出"
        exit 0
    fi
fi

# 创建锁文件
echo $$ > "$LOCK_FILE"
trap "rm -f '$LOCK_FILE'" EXIT

log "=========================================="
log "开始自动检查流程"

# -----------------------------------------------------------------------------
# 收集服务信息
# -----------------------------------------------------------------------------
log "收集服务信息"
SERVICE_INFO=$(get_service_info)
log "服务信息:"
echo "$SERVICE_INFO" | while IFS= read -r line; do
    log "  $line"
done

# -----------------------------------------------------------------------------
# 健康检查
# -----------------------------------------------------------------------------
log "执行健康检查"
HEALTH_STATUS=$(check_service_health)
HEALTH_CODE=$?

log "健康状态: $HEALTH_STATUS (code: $HEALTH_CODE)"

# -----------------------------------------------------------------------------
# 性能指标收集
# -----------------------------------------------------------------------------
METRICS=$(get_adb_metrics)
log "性能指标: $METRICS"

# -----------------------------------------------------------------------------
# 上报状态
# -----------------------------------------------------------------------------
REPORT_JSON=$(jq -n \
    --arg service "$SERVICE_ID" \
    --arg health "$HEALTH_STATUS" \
    --argjson health_code "$HEALTH_CODE" \
    --argjson metrics "$METRICS" \
    --argjson timestamp "$(date +%s)" \
    '{service: $service, health: $health, health_code: $health_code, metrics: $metrics, timestamp: $timestamp}' 2>/dev/null || echo "{}"
)

mqtt_report "isg/autocheck/$SERVICE_ID/status" "$REPORT_JSON"

# -----------------------------------------------------------------------------
# 异常处理
# -----------------------------------------------------------------------------
case $HEALTH_CODE in
    0)
        log "服务运行正常"
        # 清理重启历史
        rm -f "$SERVICE_DIR/.restart_history"
        ;;
    1)
        log "ADB 未连接，尝试重新连接"
        mqtt_report "isg/autocheck/$SERVICE_ID/alert" "{\"service\":\"$SERVICE_ID\",\"level\":\"warning\",\"message\":\"ADB disconnected, attempting reconnection\",\"timestamp\":$(date +%s)}"
        try_restart_service
        ;;
    3)
        log "android-tools 未安装"
        mqtt_report "isg/autocheck/$SERVICE_ID/alert" "{\"service\":\"$SERVICE_ID\",\"level\":\"critical\",\"message\":\"android-tools not installed\",\"timestamp\":$(date +%s)}"
        ;;
    *)
        log "未知健康状态: $HEALTH_CODE"
        ;;
esac

# -----------------------------------------------------------------------------
# 记录检查时间
# -----------------------------------------------------------------------------
date +%s > "$LAST_CHECK_FILE"

log "自动检查完成"
log "=========================================="

exit 0

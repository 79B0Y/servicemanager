#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# isg-credential-services 自检与性能监控脚本
# 版本: v1.0.0
# 功能: 单服务自检、性能监控、异常检测和自动恢复
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# 路径和变量定义
# -----------------------------------------------------------------------------
SERVICE_ID="isg-credential-services"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"

CONFIG_FILE="$BASE_DIR/configuration.yaml"
LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/autocheck.log"
LOCK_FILE="$SERVICE_DIR/.lock_autocheck"
LAST_CHECK_FILE="$SERVICE_DIR/.lastcheck"

PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
ISG_INSTALL_DIR="/root/isg-credential-services"
ISG_PORT="3000"

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

get_isg_pid() {
    local port_pid=$(netstat -tnlp 2>/dev/null | grep ":$ISG_PORT " | awk '{print $7}' | cut -d'/' -f1 | head -n1)
    
    if [ -n "$port_pid" ] && [ "$port_pid" != "-" ]; then
        local cmdline=$(cat /proc/$port_pid/cmdline 2>/dev/null | grep -o 'node\|npm\|credential' || true)
        if [ -n "$cmdline" ]; then
            echo "$port_pid"
            return 0
        fi
    fi
    return 1
}

get_service_info() {
    proot-distro login "$PROOT_DISTRO" -- bash -c "
        if [ -d '$ISG_INSTALL_DIR' ] && [ -f '$ISG_INSTALL_DIR/manage-service.sh' ]; then
            cd '$ISG_INSTALL_DIR'
            bash manage-service.sh version 2>/dev/null
        fi
    " 2>/dev/null || echo "Service information unavailable"
}

check_service_health() {
    local pid=$(get_isg_pid 2>/dev/null || echo "")
    
    if [ -z "$pid" ]; then
        echo "stopped"
        return 1
    fi
    
    # 检查端口是否可访问
    if ! nc -z 127.0.0.1 "$ISG_PORT" 2>/dev/null; then
        echo "unhealthy"
        return 2
    fi
    
    # 检查进程状态
    if ! ps -p "$pid" > /dev/null 2>&1; then
        echo "crashed"
        return 3
    fi
    
    echo "healthy"
    return 0
}

get_process_metrics() {
    local pid=$(get_isg_pid 2>/dev/null || echo "")
    
    if [ -z "$pid" ]; then
        echo "{}"
        return
    fi
    
    local cpu=$(ps -p "$pid" -o %cpu= 2>/dev/null | xargs || echo "0")
    local mem=$(ps -p "$pid" -o %mem= 2>/dev/null | xargs || echo "0")
    local vsz=$(ps -p "$pid" -o vsz= 2>/dev/null | xargs || echo "0")
    local rss=$(ps -p "$pid" -o rss= 2>/dev/null | xargs || echo "0")
    local etime=$(ps -p "$pid" -o etime= 2>/dev/null | xargs || echo "0")
    
    jq -n \
        --arg pid "$pid" \
        --arg cpu "$cpu" \
        --arg mem "$mem" \
        --arg vsz "$vsz" \
        --arg rss "$rss" \
        --arg uptime "$etime" \
        '{pid: $pid, cpu_percent: $cpu, mem_percent: $mem, vsz_kb: $vsz, rss_kb: $rss, uptime: $uptime}' 2>/dev/null || echo "{}"
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
    
    log "尝试重启服务（第 $((restart_count + 1)) 次）"
    mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"restarting\",\"restart_count\":$((restart_count + 1)),\"message\":\"attempting service restart\",\"timestamp\":$(date +%s)}"
    
    # 先停止服务
    bash "$SERVICE_DIR/stop.sh" 2>/dev/null || true
    sleep 3
    
    # 再启动服务
    if bash "$SERVICE_DIR/start.sh"; then
        record_restart
        log "服务重启成功"
        mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"restart_success\",\"restart_count\":$((restart_count + 1)),\"message\":\"service restarted successfully\",\"timestamp\":$(date +%s)}"
        return 0
    else
        log "服务重启失败"
        mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"restart_failed\",\"restart_count\":$((restart_count + 1)),\"message\":\"service restart failed\",\"timestamp\":$(date +%s)}"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# 主检查流程
# -----------------------------------------------------------------------------
ensure_directories

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
METRICS=$(get_process_metrics)
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
        log "服务已停止，尝试启动"
        mqtt_report "isg/autocheck/$SERVICE_ID/alert" "{\"service\":\"$SERVICE_ID\",\"level\":\"warning\",\"message\":\"service stopped, attempting restart\",\"timestamp\":$(date +%s)}"
        try_restart_service
        ;;
    2)
        log "服务不健康（端口无响应），尝试重启"
        mqtt_report "isg/autocheck/$SERVICE_ID/alert" "{\"service\":\"$SERVICE_ID\",\"level\":\"warning\",\"message\":\"service unhealthy, attempting restart\",\"timestamp\":$(date +%s)}"
        try_restart_service
        ;;
    3)
        log "服务进程崩溃，尝试重启"
        mqtt_report "isg/autocheck/$SERVICE_ID/alert" "{\"service\":\"$SERVICE_ID\",\"level\":\"critical\",\"message\":\"service crashed, attempting restart\",\"timestamp\":$(date +%s)}"
        try_restart_service
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

#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# isgdatamanager 停止脚本
# 版本: v1.0.0
# 功能: 通过 isgservicemonitor 停止 isgdatamanager 服务
# =============================================================================

set -euo pipefail
trap 'echo "[ERROR] line $LINENO: command failed." | tee -a "$LOG_FILE"' ERR

# -----------------------------------------------------------------------------
# 路径和变量定义
# -----------------------------------------------------------------------------
SERVICE_ID="isgdatamanager"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"
TERMUX_VAR_DIR="/data/data/com.termux/files/usr/var"

CONFIG_FILE="$BASE_DIR/configuration.yaml"
SERVICE_CONTROL_DIR="$TERMUX_VAR_DIR/service/$SERVICE_ID"
CONTROL_FILE="$SERVICE_CONTROL_DIR/supervise/control"
DOWN_FILE="$SERVICE_CONTROL_DIR/down"

LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/stop.log"
DISABLED_FLAG="$SERVICE_DIR/.disabled"

isgdatamanager_PORT="22103"
MAX_TRIES=30

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

get_isgdatamanager_pid() {
    local port_pid=$(netstat -tnlp 2>/dev/null | grep ":$isgdatamanager_PORT " | awk '{print $7}' | cut -d'/' -f1 | head -n1)
    
    if [ -n "$port_pid" ] && [ "$port_pid" != "-" ]; then
        local process_name=$(ps -p "$port_pid" -o comm= 2>/dev/null)
        if [ -n "$process_name" ] && echo "$process_name" | grep -q "isgdatamanager"; then
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
    if ! pgrep mosquitto > /dev/null 2>&1; then
        echo "[$(date '+%F %T')] [MQTT-OFFLINE] $topic -> $payload" >> "$LOG_FILE"
        return 0
    fi
    
    load_mqtt_conf
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT_CONFIG" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload" 2>/dev/null || true
    echo "[$(date '+%F %T')] [MQTT] $topic -> $payload" >> "$LOG_FILE"
}

# -----------------------------------------------------------------------------
# 主停止流程
# -----------------------------------------------------------------------------
ensure_directories

log "停止 isgdatamanager 服务"
mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"stopping\",\"message\":\"stopping service\",\"timestamp\":$(date +%s)}"

# -----------------------------------------------------------------------------
# 检查服务是否已经停止
# -----------------------------------------------------------------------------
if ! get_isgdatamanager_pid > /dev/null 2>&1; then
    log "isgdatamanager 已经停止"
    # 确保创建禁用文件
    touch "$DISABLED_FLAG"
    touch "$DOWN_FILE"
    mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"success\",\"message\":\"service already stopped\",\"timestamp\":$(date +%s)}"
    exit 0
fi

# -----------------------------------------------------------------------------
# 发送停止信号
# -----------------------------------------------------------------------------
if [ -e "$CONTROL_FILE" ]; then
    echo d > "$CONTROL_FILE"
    log "已发送 'd' 命令到 $CONTROL_FILE"
    
    # 创建 down 文件禁用自启动
    touch "$DOWN_FILE"
    log "已创建 down 文件以禁用自启动"
    mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"stopping\",\"message\":\"created down file to disable auto-start\",\"timestamp\":$(date +%s)}"
else
    log "控制文件不存在，尝试直接终止进程"
    isgdatamanager_PID=$(get_isgdatamanager_pid || true)
    if [ -n "$isgdatamanager_PID" ]; then
        kill "$isgdatamanager_PID" 2>/dev/null || true
        log "已发送 TERM 信号到 PID $isgdatamanager_PID"
    else
        log "未找到 isgdatamanager 进程"
    fi
fi

# -----------------------------------------------------------------------------
# 等待服务停止
# -----------------------------------------------------------------------------
log "等待服务停止"
mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"stopping\",\"message\":\"waiting for service to stop\",\"timestamp\":$(date +%s)}"

TRIES=0
while (( TRIES < MAX_TRIES )); do
    if ! get_isgdatamanager_pid > /dev/null 2>&1; then
        log "isgdatamanager 已成功停止"
        break
    fi
    
    # 如果超过一半时间还没停止，尝试强制杀死
    if [ $TRIES -gt $((MAX_TRIES / 2)) ]; then
        isgdatamanager_PID=$(get_isgdatamanager_pid || true)
        if [ -n "$isgdatamanager_PID" ]; then
            log "发送 KILL 信号强制停止 PID $isgdatamanager_PID"
            kill -9 "$isgdatamanager_PID" 2>/dev/null || true
        fi
    fi
    
    sleep 5
    TRIES=$((TRIES+1))
done

# -----------------------------------------------------------------------------
# 检查停止结果
# -----------------------------------------------------------------------------
if get_isgdatamanager_pid > /dev/null 2>&1; then
    log "服务在 $((MAX_TRIES*5)) 秒后仍在运行"
    mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"failed\",\"message\":\"service still running after stop timeout\",\"timeout\":$((MAX_TRIES*5)),\"timestamp\":$(date +%s)}"
    exit 1
fi

# -----------------------------------------------------------------------------
# 创建禁用标志
# -----------------------------------------------------------------------------
touch "$DISABLED_FLAG"
log "服务已停止，已创建 .disabled 标志"
mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"success\",\"message\":\"service stopped and disabled\",\"timestamp\":$(date +%s)}"

log "isgdatamanager 服务停止完成"
exit 0
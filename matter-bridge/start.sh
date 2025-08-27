#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Matter Bridge 启动脚本
# 版本: v1.0.0
# 功能: 通过 isgservicemonitor 启动 Matter Bridge 服务
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# 路径和变量定义
# -----------------------------------------------------------------------------
SERVICE_ID="matter-bridge"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"
TERMUX_VAR_DIR="/data/data/com.termux/files/usr/var"

CONFIG_FILE="$BASE_DIR/configuration.yaml"
SERVICE_CONTROL_DIR="$TERMUX_VAR_DIR/service/$SERVICE_ID"
CONTROL_FILE="$SERVICE_CONTROL_DIR/supervise/control"
DOWN_FILE="$SERVICE_CONTROL_DIR/down"

LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/start.log"
DISABLED_FLAG="$SERVICE_DIR/.disabled"

MATTER_BRIDGE_PORT="8482"
MAX_TRIES="${MAX_TRIES:-30}"

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

get_matter_bridge_pid() {
    local port_pid=$(netstat -tnlp 2>/dev/null | grep ":$MATTER_BRIDGE_PORT " | awk '{print $7}' | cut -d'/' -f1 | head -n1)
    
    if [ -n "$port_pid" ] && [ "$port_pid" != "-" ]; then
        # 验证是否为 matter-bridge 相关进程（检查命令行、工作目录或可执行文件）
        local cmdline=$(cat /proc/$port_pid/cmdline 2>/dev/null | tr '\0' ' ' | grep -i 'matter\|home-assistant-matter-hub' || true)
        local cwd=$(ls -l /proc/$port_pid/cwd 2>/dev/null | grep -o 'matter\|pnpm' || true)
        local exe=$(ls -l /proc/$port_pid/exe 2>/dev/null | grep -o 'node\|matter' || true)
        
        # 如果找到任何一个匹配条件就认为是 matter-bridge 进程
        if [ -n "$cmdline" ] || [ -n "$cwd" ] || [ -n "$exe" ]; then
            echo "$port_pid"
            return 0
        fi
        
        # 如果上述检查都失败，但端口确实被占用，可能是通过不同方式启动的
        if netstat -tnlp 2>/dev/null | grep ":$MATTER_BRIDGE_PORT " | grep -q "$port_pid"; then
            echo "$port_pid"
            return 0
        fi
    fi
    return 1
}

mqtt_report() {
    local topic="$1"
    local payload="$2"
    
    # 如果还没有 MQTT broker，只记录到日志
    if ! nc -z 127.0.0.1 1883 2>/dev/null; then
        echo "[$(date '+%F %T')] [MQTT-PENDING] $topic -> $payload" >> "$LOG_FILE"
        return 0
    fi
    
    load_mqtt_conf
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT_CONFIG" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload" 2>/dev/null || true
    echo "[$(date '+%F %T')] [MQTT] $topic -> $payload" >> "$LOG_FILE"
}

# -----------------------------------------------------------------------------
# 主启动流程
# -----------------------------------------------------------------------------
ensure_directories

log "启动 Matter Bridge 服务"
mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"starting\",\"message\":\"starting service\",\"timestamp\":$(date +%s)}"

# -----------------------------------------------------------------------------
# 移除禁用标志和 down 文件
# -----------------------------------------------------------------------------
if [ -f "$DISABLED_FLAG" ]; then
    rm -f "$DISABLED_FLAG"
    log "已移除 .disabled 标志"
fi

if [ -f "$DOWN_FILE" ]; then
    rm -f "$DOWN_FILE"
    log "已移除 down 文件以启用自启动"
    mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"failed\",\"message\":\"supervise control file not found\",\"timestamp\":$(date +%s)}"
    exit 1
fi

# -----------------------------------------------------------------------------
# 等待服务进入运行状态
# -----------------------------------------------------------------------------
log "等待服务启动"
mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"starting\",\"message\":\"waiting for service ready\",\"timestamp\":$(date +%s)}"

TRIES=0
while [[ $TRIES -lt $MAX_TRIES ]]; do
    log "检查尝试 $((TRIES+1))/$MAX_TRIES"
    
    if get_matter_bridge_pid > /dev/null 2>&1; then
        log "检测到 Matter Bridge 进程"
        
        # 检查端口是否在监听
        if nc -z 127.0.0.1 "$MATTER_BRIDGE_PORT" 2>/dev/null; then
            log "Matter Bridge 服务启动成功，端口 $MATTER_BRIDGE_PORT 可用"
            mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"success\",\"message\":\"service started successfully\",\"timestamp\":$(date +%s)}"
            exit 0
        else
            log "进程存在但端口 $MATTER_BRIDGE_PORT 尚未就绪，继续等待..."
        fi
    else
        log "未检测到 Matter Bridge 进程，继续等待..."
    fi
    
    sleep 5
    TRIES=$((TRIES+1))
done

# -----------------------------------------------------------------------------
# 启动失败：恢复禁用状态
# -----------------------------------------------------------------------------
log "服务在 $((MAX_TRIES*5)) 秒内未能启动，恢复禁用状态"
touch "$DISABLED_FLAG"
touch "$DOWN_FILE"
mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"failed\",\"message\":\"service failed to reach running state\",\"timeout\":$((MAX_TRIES*5)),\"timestamp\":$(date +%s)}"
exit 1\"service\":\"$SERVICE_ID\",\"status\":\"starting\",\"message\":\"removed down file to enable auto-start\",\"timestamp\":$(date +%s)}"
fi

# -----------------------------------------------------------------------------
# 检查服务是否已经在运行
# -----------------------------------------------------------------------------
if get_matter_bridge_pid > /dev/null 2>&1; then
    log "Matter Bridge 已经在运行"
    mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"success\",\"message\":\"service already running\",\"timestamp\":$(date +%s)}"
    exit 0
fi

# -----------------------------------------------------------------------------
# 启动服务
# -----------------------------------------------------------------------------
if [ -e "$CONTROL_FILE" ]; then
    echo u > "$CONTROL_FILE"
    log "已发送 'u' 命令到 $CONTROL_FILE"
else
    log "控制文件不存在，无法启动服务"
    mqtt_report "isg/run/$SERVICE_ID/status" "{

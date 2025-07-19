#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Mosquitto 卸载脚本
# 版本: v1.0.0
# 功能: 完全卸载 Mosquitto 环境和配置
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# 路径和变量定义
# -----------------------------------------------------------------------------
SERVICE_ID="mosquitto"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"
TERMUX_VAR_DIR="/data/data/com.termux/files/usr/var"
TERMUX_ETC_DIR="/data/data/com.termux/files/usr/etc"

CONFIG_FILE="$BASE_DIR/configuration.yaml"
MOSQUITTO_CONFIG_DIR="$TERMUX_ETC_DIR/mosquitto"
SERVICE_CONTROL_DIR="$TERMUX_VAR_DIR/service/$SERVICE_ID"

LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/uninstall.log"
BACKUP_DIR="/sdcard/isgbackup/$SERVICE_ID"
INSTALL_HISTORY_FILE="$BACKUP_DIR/.install_history"
DISABLED_FLAG="$SERVICE_DIR/.disabled"

MOSQUITTO_PORT="1883"

# -----------------------------------------------------------------------------
# 辅助函数
# -----------------------------------------------------------------------------
ensure_directories() {
    mkdir -p "$LOG_DIR"
    mkdir -p "$BACKUP_DIR"
    touch "$INSTALL_HISTORY_FILE" 2>/dev/null || true
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

get_mosquitto_pid() {
    local port_pid=$(netstat -tnlp 2>/dev/null | grep ":$MOSQUITTO_PORT " | awk '{print $7}' | cut -d'/' -f1 | head -n1)
    
    if [ -n "$port_pid" ] && [ "$port_pid" != "-" ]; then
        local process_name=$(ps -p "$port_pid" -o comm= 2>/dev/null)
        if [ "$process_name" = "mosquitto" ]; then
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
    if ! get_mosquitto_pid > /dev/null 2>&1; then
        echo "[$(date '+%F %T')] [MQTT-OFFLINE] $topic -> $payload" >> "$LOG_FILE"
        return 0
    fi
    
    load_mqtt_conf
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT_CONFIG" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload" 2>/dev/null || true
    echo "[$(date '+%F %T')] [MQTT] $topic -> $payload" >> "$LOG_FILE"
}

record_uninstall_history() {
    local status="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$timestamp UNINSTALL $status" >> "$INSTALL_HISTORY_FILE"
}

# -----------------------------------------------------------------------------
# 主卸载流程
# -----------------------------------------------------------------------------
ensure_directories

log "开始卸载 mosquitto"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"uninstalling\",\"message\":\"starting uninstall process\",\"timestamp\":$(date +%s)}"

# -----------------------------------------------------------------------------
# 停止服务
# -----------------------------------------------------------------------------
log "停止服务"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"uninstalling\",\"message\":\"stopping service\",\"timestamp\":$(date +%s)}"

if [ -f "$SERVICE_DIR/stop.sh" ]; then
    bash "$SERVICE_DIR/stop.sh" || true
else
    # 手动停止服务
    log "stop.sh 不存在，手动停止服务"
    
    # 通过 isgservicemonitor 停止
    if [ -e "$SERVICE_CONTROL_DIR/supervise/control" ]; then
        echo d > "$SERVICE_CONTROL_DIR/supervise/control" || true
        touch "$SERVICE_CONTROL_DIR/down" || true
    fi
    
    # 直接杀死进程
    MOSQUITTO_PID=$(get_mosquitto_pid || echo "")
    if [ -n "$MOSQUITTO_PID" ]; then
        log "杀死 mosquitto 进程 $MOSQUITTO_PID"
        kill "$MOSQUITTO_PID" 2>/dev/null || true
        sleep 2
        
        # 如果还在运行，强制杀死
        if get_mosquitto_pid > /dev/null 2>&1; then
            kill -9 "$MOSQUITTO_PID" 2>/dev/null || true
        fi
    fi
fi

sleep 5

# 确认服务已停止
if get_mosquitto_pid > /dev/null 2>&1; then
    log "警告: mosquitto 进程仍在运行，尝试强制停止"
    MOSQUITTO_PID=$(get_mosquitto_pid || echo "")
    if [ -n "$MOSQUITTO_PID" ]; then
        kill -9 "$MOSQUITTO_PID" 2>/dev/null || true
    fi
fi

# -----------------------------------------------------------------------------
# 卸载 mosquitto 包
# -----------------------------------------------------------------------------
log "卸载 mosquitto 包"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"uninstalling\",\"message\":\"removing mosquitto package\",\"timestamp\":$(date +%s)}"

if command -v mosquitto >/dev/null 2>&1; then
    if ! pkg uninstall -y mosquitto; then
        log "警告: mosquitto 包卸载失败，但继续清理过程"
    else
        log "mosquitto 包卸载成功"
    fi
else
    log "mosquitto 包未安装或已被卸载"
fi

# -----------------------------------------------------------------------------
# 删除配置文件和数据
# -----------------------------------------------------------------------------
log "删除配置文件和数据"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"uninstalling\",\"message\":\"removing configuration and data\",\"timestamp\":$(date +%s)}"

# 删除配置目录
if [ -d "$MOSQUITTO_CONFIG_DIR" ]; then
    log "删除配置目录: $MOSQUITTO_CONFIG_DIR"
    rm -rf "$MOSQUITTO_CONFIG_DIR"
fi

# 删除数据目录
MOSQUITTO_DATA_DIR="/data/data/com.termux/files/usr/var/lib/mosquitto"
if [ -d "$MOSQUITTO_DATA_DIR" ]; then
    log "删除数据目录: $MOSQUITTO_DATA_DIR"
    rm -rf "$MOSQUITTO_DATA_DIR"
fi

# 删除日志文件
MOSQUITTO_LOG_FILE="/data/data/com.termux/files/usr/var/log/mosquitto.log"
if [ -f "$MOSQUITTO_LOG_FILE" ]; then
    log "删除日志文件: $MOSQUITTO_LOG_FILE"
    rm -f "$MOSQUITTO_LOG_FILE"
fi

# -----------------------------------------------------------------------------
# 删除服务监控配置
# -----------------------------------------------------------------------------
log "删除服务监控配置"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"uninstalling\",\"message\":\"removing service monitor configuration\",\"timestamp\":$(date +%s)}"

if [ -d "$SERVICE_CONTROL_DIR" ]; then
    log "删除服务控制目录: $SERVICE_CONTROL_DIR"
    rm -rf "$SERVICE_CONTROL_DIR"
fi

# -----------------------------------------------------------------------------
# 创建禁用标志
# -----------------------------------------------------------------------------
log "创建禁用标志"
touch "$DISABLED_FLAG"

# -----------------------------------------------------------------------------
# 记录卸载历史
# -----------------------------------------------------------------------------
record_uninstall_history "SUCCESS"

# -----------------------------------------------------------------------------
# 验证卸载完成
# -----------------------------------------------------------------------------
log "验证卸载状态"

# 检查命令是否还存在
if command -v mosquitto >/dev/null 2>&1; then
    log "警告: mosquitto 命令仍然可用"
    UNINSTALL_STATUS="partial"
else
    log "✅ mosquitto 命令已不可用"
    UNINSTALL_STATUS="complete"
fi

# 检查进程是否还在运行
if get_mosquitto_pid > /dev/null 2>&1; then
    log "警告: mosquitto 进程仍在运行"
    UNINSTALL_STATUS="partial"
else
    log "✅ mosquitto 进程已停止"
fi

# 检查端口是否还在监听
if netstat -tulnp 2>/dev/null | grep ":$MOSQUITTO_PORT " > /dev/null; then
    log "警告: 端口 $MOSQUITTO_PORT 仍被占用"
    UNINSTALL_STATUS="partial"
else
    log "✅ 端口 $MOSQUITTO_PORT 已释放"
fi

# -----------------------------------------------------------------------------
# 上报卸载完成
# -----------------------------------------------------------------------------
if [ "$UNINSTALL_STATUS" = "complete" ]; then
    log "mosquitto 完全卸载成功"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"uninstalled\",\"message\":\"mosquitto completely removed\",\"timestamp\":$(date +%s)}"
else
    log "mosquitto 部分卸载，可能需要手动清理"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"uninstalled\",\"message\":\"mosquitto partially removed, manual cleanup may be required\",\"timestamp\":$(date +%s)}"
fi

log "卸载摘要:"
log "  - 状态: $UNINSTALL_STATUS"
log "  - 包卸载: $(command -v mosquitto >/dev/null 2>&1 && echo "未完成" || echo "已完成")"
log "  - 进程停止: $(get_mosquitto_pid >/dev/null 2>&1 && echo "未完成" || echo "已完成")"
log "  - 端口释放: $(netstat -tulnp 2>/dev/null | grep ":$MOSQUITTO_PORT " >/dev/null && echo "未完成" || echo "已完成")"
log "  - 配置清理: 已完成"
log "  - 服务监控: 已清理"

exit 0

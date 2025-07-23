#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Matter Server 卸载脚本
# 版本: v1.0.0
# 功能: 完全卸载 Matter Server 环境和配置
# =============================================================================

set -euo pipefail

# =============================================================================
# 路径和配置定义
# =============================================================================
SERVICE_ID="matter-server"
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"

# 基础目录
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"
CONFIG_FILE="$BASE_DIR/configuration.yaml"

# 日志和状态文件
LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/uninstall.log"
DISABLED_FLAG="$SERVICE_DIR/.disabled"
INSTALL_HISTORY_FILE="$SERVICE_DIR/.install_history"

# 服务监控相关路径
SERVICE_CONTROL_DIR="/data/data/com.termux/files/usr/var/service/$SERVICE_ID"

# 网络端口
MATTER_PORT="8443"
WS_PORT="5540"

# =============================================================================
# 工具函数
# =============================================================================
ensure_directories() {
    mkdir -p "$LOG_DIR"
}

log() {
    echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"
}

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

mqtt_report() {
    local topic="$1"
    local payload="$2"
    load_mqtt_conf
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload" || true
    log "[MQTT] $topic -> $payload"
}

record_uninstall_history() {
    local status="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$timestamp UNINSTALL $status" >> "$INSTALL_HISTORY_FILE"
}

# =============================================================================
# 主程序开始
# =============================================================================
ensure_directories

log "starting matter-server uninstallation"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"uninstalling\",\"message\":\"starting uninstall process\",\"timestamp\":$(date +%s)}"

# -----------------------------------------------------------------------------
# 停止服务
# -----------------------------------------------------------------------------
log "stopping service"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"uninstalling\",\"message\":\"stopping service\",\"timestamp\":$(date +%s)}"

bash "$SERVICE_DIR/stop.sh" || true
sleep 5

# -----------------------------------------------------------------------------
# 在容器内执行卸载
# -----------------------------------------------------------------------------
log "removing matter-server installation"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"uninstalling\",\"message\":\"removing installation directory\",\"timestamp\":$(date +%s)}"

proot-distro login "$PROOT_DISTRO" << 'EOF'
log_step() {
    echo -e "\n[STEP] $1"
}

log_step "killing matter-server if running"
# 通过8443端口找到matter-server进程
MATTER_PORT_PID=$(netstat -tnlp 2>/dev/null | grep ':8443 ' | awk '{print $7}' | cut -d'/' -f1 | head -n1)
if [ -n "$MATTER_PORT_PID" ] && [ "$MATTER_PORT_PID" != "-" ]; then
    # 检查进程命令行确认是matter-server
    MATTER_CMDLINE=$(cat /proc/$MATTER_PORT_PID/cmdline 2>/dev/null | tr '\0' ' ' || echo "")
    if [[ "$MATTER_CMDLINE" =~ "matter_server" ]]; then
        kill "$MATTER_PORT_PID" && echo "[INFO] killed matter-server process $MATTER_PORT_PID" || echo "[INFO] failed to kill process"
    else
        echo "[INFO] process on port 8443 is not matter-server"
    fi
else
    echo "[INFO] no process found on port 8443"
fi

# 同样检查5540端口（WebSocket）
WS_PORT_PID=$(netstat -tnlp 2>/dev/null | grep ':5540 ' | awk '{print $7}' | cut -d'/' -f1 | head -n1)
if [ -n "$WS_PORT_PID" ] && [ "$WS_PORT_PID" != "-" ]; then
    WS_CMDLINE=$(cat /proc/$WS_PORT_PID/cmdline 2>/dev/null | tr '\0' ' ' || echo "")
    if [[ "$WS_CMDLINE" =~ "matter_server" ]]; then
        kill "$WS_PORT_PID" && echo "[INFO] killed matter-server WebSocket process $WS_PORT_PID" || echo "[INFO] failed to kill WebSocket process"
    fi
fi

log_step "removing matter-server installation"
rm -rf /opt/matter-server

log_step "uninstall complete"
EOF

# -----------------------------------------------------------------------------
# 移除服务监控配置
# -----------------------------------------------------------------------------
log "removing servicemonitor configuration"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"uninstalling\",\"message\":\"removing servicemonitor configuration\",\"timestamp\":$(date +%s)}"

if [ -d "$SERVICE_CONTROL_DIR" ]; then
    rm -rf "$SERVICE_CONTROL_DIR"
    log "removed servicemonitor directory: $SERVICE_CONTROL_DIR"
fi

# -----------------------------------------------------------------------------
# 创建 .disabled 标志
# -----------------------------------------------------------------------------
log "creating .disabled flag"
touch "$DISABLED_FLAG"

# -----------------------------------------------------------------------------
# 记录卸载历史
# -----------------------------------------------------------------------------
record_uninstall_history "SUCCESS"

# -----------------------------------------------------------------------------
# 上报卸载成功
# -----------------------------------------------------------------------------
log "reporting uninstall success"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"uninstalled\",\"message\":\"matter-server completely removed\",\"timestamp\":$(date +%s)}"

log "matter-server uninstallation completed"
exit 0
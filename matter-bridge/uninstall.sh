#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Matter Bridge 卸载脚本
# 版本: v1.0.0
# 功能: 完全卸载 Home Assistant Matter Bridge 环境和配置
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

LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/uninstall.log"
BACKUP_DIR="/sdcard/isgbackup/$SERVICE_ID"
INSTALL_HISTORY_FILE="$BACKUP_DIR/.install_history"
DISABLED_FLAG="$SERVICE_DIR/.disabled"

PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
MATTER_BRIDGE_INSTALL_DIR="/root/.pnpm-global/global/5/node_modules/home-assistant-matter-hub"
MATTER_BRIDGE_PORT="8482"

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

get_matter_bridge_pid() {
    local port_pid=$(netstat -tnlp 2>/dev/null | grep ":$MATTER_BRIDGE_PORT " | awk '{print $7}' | cut -d'/' -f1 | head -n1)
    
    if [ -n "$port_pid" ] && [ "$port_pid" != "-" ]; then
        local cmdline=$(cat /proc/$port_pid/cmdline 2>/dev/null | grep -o 'matter\|home-assistant-matter-hub' || true)
        if [ -n "$cmdline" ]; then
            echo "$port_pid"
            return 0
        fi
    fi
    return 1
}

mqtt_report() {
    local topic="$1"
    local payload="$2"
    
    # 检查 MQTT broker 是否可用
    if ! nc -z 127.0.0.1 1883 2>/dev/null; then
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

log "开始卸载 Home Assistant Matter Bridge"
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
    MATTER_BRIDGE_PID=$(get_matter_bridge_pid || echo "")
    if [ -n "$MATTER_BRIDGE_PID" ]; then
        log "杀死 Matter Bridge 进程 $MATTER_BRIDGE_PID"
        kill "$MATTER_BRIDGE_PID" 2>/dev/null || true
        sleep 2
        
        # 如果还在运行，强制杀死
        if get_matter_bridge_pid > /dev/null 2>&1; then
            kill -9 "$MATTER_BRIDGE_PID" 2>/dev/null || true
        fi
    fi
fi

sleep 5

# 确认服务已停止
if get_matter_bridge_pid > /dev/null 2>&1; then
    log "警告: Matter Bridge 进程仍在运行，尝试强制停止"
    MATTER_BRIDGE_PID=$(get_matter_bridge_pid || echo "")
    if [ -n "$MATTER_BRIDGE_PID" ]; then
        kill -9 "$MATTER_BRIDGE_PID" 2>/dev/null || true
    fi
fi

# -----------------------------------------------------------------------------
# 在容器内执行卸载
# -----------------------------------------------------------------------------
log "移除 Matter Bridge 安装"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"uninstalling\",\"message\":\"removing installation\",\"timestamp\":$(date +%s)}"

proot-distro login "$PROOT_DISTRO" << 'EOF'
log_step() {
    echo -e "\n[STEP] $1"
}

log_step "杀死可能运行的 matter-bridge 进程"
# 通过8482端口找到matter-bridge进程
MATTER_PORT_PID=$(netstat -tnlp 2>/dev/null | grep ':8482 ' | awk '{print $7}' | cut -d'/' -f1 | head -n1)
if [ -n "$MATTER_PORT_PID" ] && [ "$MATTER_PORT_PID" != "-" ]; then
    # 检查进程命令行确认是matter-bridge
    MATTER_CMD=$(cat /proc/$MATTER_PORT_PID/cmdline 2>/dev/null | grep -o 'matter\|home-assistant-matter-hub' || true)
    if [ -n "$MATTER_CMD" ]; then
        kill "$MATTER_PORT_PID" && echo "[INFO] 杀死 matter-bridge 进程 $MATTER_PORT_PID" || echo "[INFO] 杀死进程失败"
    else
        echo "[INFO] 端口 8482 上的进程不是 matter-bridge"
    fi
else
    echo "[INFO] 端口 8482 上未发现进程"
fi

log_step "卸载 home-assistant-matter-hub"
export PATH="$HOME/.pnpm-global/global/bin:$PATH"
if ! pnpm remove -g home-assistant-matter-hub; then
    echo "[WARN] pnpm remove 失败，尝试手动删除"
    rm -rf /root/.pnpm-global/global/5/node_modules/home-assistant-matter-hub
    rm -f /root/.pnpm-global/global/5/node_modules/.bin/home-assistant-matter-hub
fi

log_step "清理启动脚本"
rm -f /sdcard/isgbackup/matter-bridge/matter-bridge-start.sh

log_step "卸载完成"
EOF

# -----------------------------------------------------------------------------
# 移除服务控制目录
# -----------------------------------------------------------------------------
log "移除服务控制目录"
if [ -d "$SERVICE_CONTROL_DIR" ]; then
    rm -rf "$SERVICE_CONTROL_DIR"
    log "已移除服务控制目录: $SERVICE_CONTROL_DIR"
fi

# -----------------------------------------------------------------------------
# 创建 .disabled 标志
# -----------------------------------------------------------------------------
log "创建 .disabled 标志"
touch "$DISABLED_FLAG"

# -----------------------------------------------------------------------------
# 记录卸载历史
# -----------------------------------------------------------------------------
record_uninstall_history "SUCCESS"

# -----------------------------------------------------------------------------
# 验证卸载完成
# -----------------------------------------------------------------------------
log "验证卸载状态"

# 检查安装目录是否还存在
if proot-distro login "$PROOT_DISTRO" -- test -d "$MATTER_BRIDGE_INSTALL_DIR" 2>/dev/null; then
    log "警告: Matter Bridge 安装目录仍然存在"
    UNINSTALL_STATUS="partial"
else
    log "✅ Matter Bridge 安装目录已移除"
    UNINSTALL_STATUS="complete"
fi

# 检查进程是否还在运行
if get_matter_bridge_pid > /dev/null 2>&1; then
    log "警告: Matter Bridge 进程仍在运行"
    UNINSTALL_STATUS="partial"
else
    log "✅ Matter Bridge 进程已停止"
fi

# 检查端口是否还在监听
if netstat -tulnp 2>/dev/null | grep ":$MATTER_BRIDGE_PORT " > /dev/null; then
    log "警告: 端口 $MATTER_BRIDGE_PORT 仍被占用"
    UNINSTALL_STATUS="partial"
else
    log "✅ 端口 $MATTER_BRIDGE_PORT 已释放"
fi

# 检查启动脚本是否还存在
if proot-distro login "$PROOT_DISTRO" -- test -f "/sdcard/isgbackup/matter-bridge/matter-bridge-start.sh" 2>/dev/null; then
    log "警告: 启动脚本仍然存在"
    UNINSTALL_STATUS="partial"
else
    log "✅ 启动脚本已清理"
fi

# -----------------------------------------------------------------------------
# 上报卸载完成
# -----------------------------------------------------------------------------
if [ "$UNINSTALL_STATUS" = "complete" ]; then
    log "Home Assistant Matter Bridge 完全卸载成功"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"uninstalled\",\"message\":\"matter-bridge completely removed\",\"timestamp\":$(date +%s)}"
else
    log "Home Assistant Matter Bridge 部分卸载，可能需要手动清理"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"uninstalled\",\"message\":\"matter-bridge partially removed, manual cleanup may be required\",\"timestamp\":$(date +%s)}"
fi

log "卸载摘要:"
log "  - 状态: $UNINSTALL_STATUS"
log "  - 安装目录: $(proot-distro login "$PROOT_DISTRO" -- test -d "$MATTER_BRIDGE_INSTALL_DIR" && echo "未完成" || echo "已完成")"
log "  - 进程停止: $(get_matter_bridge_pid >/dev/null 2>&1 && echo "未完成" || echo "已完成")"
log "  - 端口释放: $(netstat -tulnp 2>/dev/null | grep ":$MATTER_BRIDGE_PORT " >/dev/null && echo "未完成" || echo "已完成")"
log "  - 启动脚本: $(proot-distro login "$PROOT_DISTRO" -- test -f "/sdcard/isgbackup/matter-bridge/matter-bridge-start.sh" && echo "未完成" || echo "已完成")"
log "  - 服务监控: 已清理"

exit 0

#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# isg-guardian 卸载脚本
# 版本: v1.0.0
# 功能: 完全卸载 isg-guardian 环境和配置
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# 路径和变量定义
# -----------------------------------------------------------------------------
SERVICE_ID="isg-guardian"
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
GUARDIAN_INSTALL_DIR="/root/isg-guardian"

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

get_guardian_pid() {
    # 在 proot 容器内查找 iSG App Guardian 进程
    local pid=$(proot-distro login "$PROOT_DISTRO" -- bash -c "pgrep -f 'iSG App Guardian' | head -n1" 2>/dev/null || echo "")
    
    if [ -n "$pid" ]; then
        # 验证是否为正确的 iSG App Guardian 进程
        local cmdline=$(proot-distro login "$PROOT_DISTRO" -- bash -c "cat /proc/$pid/cmdline 2>/dev/null | tr '\0' ' ' | grep -i 'iSG App Guardian'" 2>/dev/null || echo "")
        if [ -n "$cmdline" ]; then
            echo "$pid"
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

log "开始卸载 isg-guardian"
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
    GUARDIAN_PID=$(get_guardian_pid || echo "")
    if [ -n "$GUARDIAN_PID" ]; then
        log "杀死 isg-guardian 进程 $GUARDIAN_PID"
        proot-distro login "$PROOT_DISTRO" -- bash -c "kill $GUARDIAN_PID" 2>/dev/null || true
        sleep 2
        
        # 如果还在运行，强制杀死
        if get_guardian_pid > /dev/null 2>&1; then
            proot-distro login "$PROOT_DISTRO" -- bash -c "kill -9 $GUARDIAN_PID" 2>/dev/null || true
        fi
    fi
fi

sleep 5

# 确认服务已停止 - 添加超时和调试信息
log "检查服务是否已停止"
STOP_WAIT_COUNT=0
MAX_STOP_WAIT=10  # 最多等待10次，每次2秒

while [ $STOP_WAIT_COUNT -lt $MAX_STOP_WAIT ]; do
    if ! get_guardian_pid > /dev/null 2>&1; then
        log "✅ iSG App Guardian 进程已成功停止"
        break
    fi
    
    log "iSG App Guardian 进程仍在运行，等待停止... (${STOP_WAIT_COUNT}/${MAX_STOP_WAIT})"
    GUARDIAN_PID=$(get_guardian_pid || echo "")
    if [ -n "$GUARDIAN_PID" ]; then
        log "当前进程 PID: $GUARDIAN_PID"
        # 强制杀死进程
        proot-distro login "$PROOT_DISTRO" -- bash -c "kill -9 $GUARDIAN_PID" 2>/dev/null || true
    fi
    
    sleep 2
    STOP_WAIT_COUNT=$((STOP_WAIT_COUNT + 1))
done

if get_guardian_pid > /dev/null 2>&1; then
    log "警告: iSG App Guardian 进程在 $((MAX_STOP_WAIT * 2)) 秒后仍在运行，继续卸载"
    GUARDIAN_PID=$(get_guardian_pid || echo "")
    if [ -n "$GUARDIAN_PID" ]; then
        log "强制终止进程 PID: $GUARDIAN_PID"
        proot-distro login "$PROOT_DISTRO" -- bash -c "kill -9 $GUARDIAN_PID" 2>/dev/null || true
    fi
fi

# -----------------------------------------------------------------------------
# 在容器内执行卸载
# -----------------------------------------------------------------------------
log "移除 isg-guardian 安装"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"uninstalling\",\"message\":\"removing installation directory\",\"timestamp\":$(date +%s)}"

proot-distro login "$PROOT_DISTRO" << 'EOF'
log_step() {
    echo -e "\n[STEP] $1"
}

log_step "杀死可能运行的 iSG App Guardian 进程"
# 查找所有 iSG App Guardian 相关进程
GUARDIAN_PIDS=$(pgrep -f 'iSG App Guardian' || true)
if [ -n "$GUARDIAN_PIDS" ]; then
    for pid in $GUARDIAN_PIDS; do
        # 检查进程命令行确认是 iSG App Guardian
        GUARDIAN_CMD=$(cat /proc/$pid/cmdline 2>/dev/null | tr '\0' ' ' | grep -i 'iSG App Guardian' || true)
        if [ -n "$GUARDIAN_CMD" ]; then
            kill "$pid" && echo "[INFO] 杀死 iSG App Guardian 进程 $pid" || echo "[INFO] 杀死进程失败"
        fi
    done
else
    echo "[INFO] 未发现 iSG App Guardian 进程"
fi

log_step "移除 isg-guardian 安装目录"
rm -rf /root/isg-guardian

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
if proot-distro login "$PROOT_DISTRO" -- test -d "$GUARDIAN_INSTALL_DIR" 2>/dev/null; then
    log "警告: isg-guardian 安装目录仍然存在"
    UNINSTALL_STATUS="partial"
else
    log "✅ isg-guardian 安装目录已移除"
    UNINSTALL_STATUS="complete"
fi

# 检查进程是否还在运行
if get_guardian_pid > /dev/null 2>&1; then
    log "警告: isg-guardian 进程仍在运行"
    UNINSTALL_STATUS="partial"
else
    log "✅ isg-guardian 进程已停止"
fi

# -----------------------------------------------------------------------------
# 上报卸载完成
# -----------------------------------------------------------------------------
if [ "$UNINSTALL_STATUS" = "complete" ]; then
    log "isg-guardian 完全卸载成功"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"uninstalled\",\"message\":\"isg-guardian completely removed\",\"timestamp\":$(date +%s)}"
else
    log "isg-guardian 部分卸载，可能需要手动清理"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"uninstalled\",\"message\":\"isg-guardian partially removed, manual cleanup may be required\",\"timestamp\":$(date +%s)}"
fi

log "卸载摘要:"
log "  - 状态: $UNINSTALL_STATUS"
log "  - 安装目录: $(proot-distro login "$PROOT_DISTRO" -- test -d "$GUARDIAN_INSTALL_DIR" && echo "未完成" || echo "已完成")"
log "  - 进程停止: $(get_guardian_pid >/dev/null 2>&1 && echo "未完成" || echo "已完成")"
log "  - 服务监控: 已清理"

exit 0

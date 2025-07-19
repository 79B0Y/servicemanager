#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Z-Wave JS UI 卸载脚本
# 版本: v1.0.0
# 功能: 完全卸载 Z-Wave JS UI 环境和配置
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# 路径和变量定义
# -----------------------------------------------------------------------------
SERVICE_ID="zwave-js-ui"
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
PNPM_HOME="/root/.pnpm-global"
ZUI_INSTALL_PATH="/root/.pnpm-global/global/5/node_modules/zwave-js-ui"
ZUI_DATA_DIR="/usr/src/app/store"
ZUI_PORT="8091"

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

get_zui_pid() {
    local port_pid=$(netstat -tnlp 2>/dev/null | grep ":$ZUI_PORT " | awk '{print $7}' | cut -d'/' -f1 | head -n1)
    
    if [ -n "$port_pid" ] && [ "$port_pid" != "-" ]; then
        local cwd=$(ls -l /proc/$port_pid/cwd 2>/dev/null | grep -o 'zwave\|node' || true)
        if [ -n "$cwd" ]; then
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

log "开始卸载 Z-Wave JS UI"
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
    ZUI_PID=$(get_zui_pid || echo "")
    if [ -n "$ZUI_PID" ]; then
        log "杀死 Z-Wave JS UI 进程 $ZUI_PID"
        kill "$ZUI_PID" 2>/dev/null || true
        sleep 2
        
        # 如果还在运行，强制杀死
        if get_zui_pid > /dev/null 2>&1; then
            kill -9 "$ZUI_PID" 2>/dev/null || true
        fi
    fi
fi

sleep 5

# 确认服务已停止
if get_zui_pid > /dev/null 2>&1; then
    log "警告: Z-Wave JS UI 进程仍在运行，尝试强制停止"
    ZUI_PID=$(get_zui_pid || echo "")
    if [ -n "$ZUI_PID" ]; then
        kill -9 "$ZUI_PID" 2>/dev/null || true
    fi
fi

# -----------------------------------------------------------------------------
# 在容器内执行卸载
# -----------------------------------------------------------------------------
log "移除 Z-Wave JS UI 安装"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"uninstalling\",\"message\":\"removing installation directory\",\"timestamp\":$(date +%s)}"

proot-distro login "$PROOT_DISTRO" << 'EOF'
log_step() {
    echo -e "\n[STEP] $1"
}

log_step "杀死可能运行的 zwave-js-ui 进程"
# 通过8091端口找到zwave-js-ui进程
ZUI_PORT_PID=$(netstat -tnlp 2>/dev/null | grep ':8091 ' | awk '{print $7}' | cut -d'/' -f1 | head -n1)
if [ -n "$ZUI_PORT_PID" ] && [ "$ZUI_PORT_PID" != "-" ]; then
    # 检查进程工作目录确认是zwave-js-ui
    ZUI_CWD=$(ls -l /proc/$ZUI_PORT_PID/cwd 2>/dev/null | grep -o 'zwave\|node' || true)
    if [ -n "$ZUI_CWD" ]; then
        kill "$ZUI_PORT_PID" && echo "[INFO] 杀死 zwave-js-ui 进程 $ZUI_PORT_PID" || echo "[INFO] 杀死进程失败"
    else
        echo "[INFO] 端口 8091 上的进程不是 zwave-js-ui"
    fi
else
    echo "[INFO] 端口 8091 上未发现进程"
fi

log_step "移除 zwave-js-ui 全局包"
export PNPM_HOME=/root/.pnpm-global
export PATH=$PNPM_HOME:$PATH
export SHELL=/bin/bash
source ~/.bashrc 2>/dev/null || true

if command -v pnpm >/dev/null 2>&1; then
    echo "使用 pnpm 版本: $(pnpm --version)"
    pnpm remove -g zwave-js-ui || echo "[INFO] zwave-js-ui 可能已经被卸载"
else
    echo "[INFO] pnpm 不可用，跳过全局包移除"
fi

log_step "移除 zwave-js-ui 安装目录"
rm -rf /root/.pnpm-global/global/5/node_modules/zwave-js-ui

log_step "移除 zwave-js-ui 用户数据（可选）"
# 可选：也删除用户数据
# rm -rf /usr/src/app/store

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
if proot-distro login "$PROOT_DISTRO" -- test -d "$ZUI_INSTALL_PATH" 2>/dev/null; then
    log "警告: Z-Wave JS UI 安装目录仍然存在"
    UNINSTALL_STATUS="partial"
else
    log "✅ Z-Wave JS UI 安装目录已移除"
    UNINSTALL_STATUS="complete"
fi

# 检查进程是否还在运行
if get_zui_pid > /dev/null 2>&1; then
    log "警告: Z-Wave JS UI 进程仍在运行"
    UNINSTALL_STATUS="partial"
else
    log "✅ Z-Wave JS UI 进程已停止"
fi

# 检查端口是否还在监听
if netstat -tulnp 2>/dev/null | grep ":$ZUI_PORT " > /dev/null; then
    log "警告: 端口 $ZUI_PORT 仍被占用"
    UNINSTALL_STATUS="partial"
else
    log "✅ 端口 $ZUI_PORT 已释放"
fi

# 检查全局包是否还存在
GLOBAL_PACKAGE_EXISTS=$(proot-distro login "$PROOT_DISTRO" -- bash -c "
    export PNPM_HOME=$PNPM_HOME
    export PATH=\$PNPM_HOME:\$PATH
    export SHELL=/bin/bash
    source ~/.bashrc 2>/dev/null || true
    if command -v pnpm >/dev/null 2>&1; then
        pnpm list -g 2>/dev/null | grep zwave-js-ui || true
    fi
" 2>/dev/null || true)

if [ -n "$GLOBAL_PACKAGE_EXISTS" ]; then
    log "警告: Z-Wave JS UI 全局包可能仍然存在"
    UNINSTALL_STATUS="partial"
else
    log "✅ Z-Wave JS UI 全局包已移除"
fi

# -----------------------------------------------------------------------------
# 上报卸载完成
# -----------------------------------------------------------------------------
if [ "$UNINSTALL_STATUS" = "complete" ]; then
    log "Z-Wave JS UI 完全卸载成功"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"uninstalled\",\"message\":\"zwave-js-ui completely removed\",\"timestamp\":$(date +%s)}"
else
    log "Z-Wave JS UI 部分卸载，可能需要手动清理"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"uninstalled\",\"message\":\"zwave-js-ui partially removed, manual cleanup may be required\",\"timestamp\":$(date +%s)}"
fi

log "卸载摘要:"
log "  - 状态: $UNINSTALL_STATUS"
log "  - 安装目录: $(proot-distro login "$PROOT_DISTRO" -- test -d "$ZUI_INSTALL_PATH" && echo "未完成" || echo "已完成")"
log "  - 全局包: $([ -n "$GLOBAL_PACKAGE_EXISTS" ] && echo "未完成" || echo "已完成")"
log "  - 进程停止: $(get_zui_pid >/dev/null 2>&1 && echo "未完成" || echo "已完成")"
log "  - 端口释放: $(netstat -tulnp 2>/dev/null | grep ":$ZUI_PORT " >/dev/null && echo "未完成" || echo "已完成")"
log "  - 服务监控: 已清理"

exit 0
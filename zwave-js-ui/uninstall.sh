#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Z-Wave JS UI 卸载脚本
# 版本: v1.0.0
# 功能: 完全卸载 Z-Wave JS UI 环境和配置
# =============================================================================

set -euo pipefail

# 加载统一路径定义
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common_paths.sh" || {
    echo "Error: Cannot load common paths"
    exit 1
}

# 设置脚本特定的日志文件
LOG_FILE="$LOG_FILE_UNINSTALL"

# 确保必要目录存在
ensure_directories

log "starting zwave-js-ui uninstallation"
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
log "removing zwave-js-ui installation"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"uninstalling\",\"message\":\"removing installation directory\",\"timestamp\":$(date +%s)}"

proot-distro login "$PROOT_DISTRO" << 'EOF'
log_step() {
    echo -e "\n[STEP] $1"
}

log_step "killing zwave-js-ui if running"
# 通过8091端口找到zwave-js-ui进程
ZWAVE_PORT_PID=$(netstat -tnlp 2>/dev/null | grep ':8091 ' | awk '{print $7}' | cut -d'/' -f1 | head -n1)
if [ -n "$ZWAVE_PORT_PID" ] && [ "$ZWAVE_PORT_PID" != "-" ]; then
    # 检查进程工作目录确认是zwave-js-ui
    ZWAVE_CWD=$(ls -l /proc/$ZWAVE_PORT_PID/cwd 2>/dev/null | grep -o 'zwave-js-ui' || true)
    if [ -n "$ZWAVE_CWD" ]; then
        kill "$ZWAVE_PORT_PID" && echo "[INFO] killed zwave-js-ui process $ZWAVE_PORT_PID" || echo "[INFO] failed to kill process"
    else
        echo "[INFO] process on port 8091 is not zwave-js-ui"
    fi
else
    echo "[INFO] no process found on port 8091"
fi

log_step "removing zwave-js-ui global package"
export SHELL=/data/data/com.termux/files/usr/bin/bash
export PNPM_HOME="/root/.local/share/pnpm"
export PATH="$PNPM_HOME:$PATH"
source ~/.bashrc 2>/dev/null || true
pnpm remove -g zwave-js-ui || echo "[WARN] failed to remove global package"

log_step "removing zwave-js-ui installation directory"
rm -rf /root/.pnpm-global/global/5/node_modules/zwave-js-ui
rm -rf /root/.local/share/pnpm/global/5/node_modules/zwave-js-ui

log_step "uninstall complete"
EOF

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
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"uninstalled\",\"message\":\"zwave-js-ui completely removed\",\"timestamp\":$(date +%s)}"

log "zwave-js-ui uninstallation completed"
exit 0

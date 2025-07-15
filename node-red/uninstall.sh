#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Node-RED 卸载脚本
# 版本: v1.0.0
# 功能: 完全卸载 Node-RED 环境和配置
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

log "starting node-red uninstallation"
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
log "removing node-red installation"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"uninstalling\",\"message\":\"removing installation\",\"timestamp\":$(date +%s)}"

proot-distro login "$PROOT_DISTRO" << 'EOF'
log_step() {
    echo -e "\n[STEP] $1"
}

log_step "killing node-red if running"
# 通过1880端口找到node-red进程
NODE_RED_PORT_PID=$(netstat -tnlp 2>/dev/null | grep ':1880 ' | awk '{print $7}' | cut -d'/' -f1 | head -n1)
if [ -n "$NODE_RED_PORT_PID" ] && [ "$NODE_RED_PORT_PID" != "-" ]; then
    # 检查进程工作目录确认是node-red
    NODE_RED_CWD=$(ls -l /proc/$NODE_RED_PORT_PID/cwd 2>/dev/null | grep -o 'node-red\|\.node-red' || true)
    if [ -n "$NODE_RED_CWD" ]; then
        kill "$NODE_RED_PORT_PID" && echo "[INFO] killed node-red process $NODE_RED_PORT_PID" || echo "[INFO] failed to kill process"
    else
        echo "[INFO] process on port 1880 is not node-red"
    fi
else
    echo "[INFO] no process found on port 1880"
fi

log_step "removing node-red global installation"
pnpm remove -g node-red || npm uninstall -g node-red || echo "[WARN] node-red not found in global packages"

log_step "removing node-red data directory"
rm -rf /root/.node-red

log_step "cleaning up pnpm global cache"
pnpm store prune || echo "[WARN] pnpm store prune failed"

log_step "uninstall complete"
EOF

# -----------------------------------------------------------------------------
# 移除服务控制文件
# -----------------------------------------------------------------------------
log "removing service control files"
rm -f "$RUN_FILE"
rm -f "$DOWN_FILE"

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
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"uninstalled\",\"message\":\"node-red completely removed\",\"timestamp\":$(date +%s)}"

log "node-red uninstallation completed"
exit 0

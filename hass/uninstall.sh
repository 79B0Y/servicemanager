#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Home Assistant 卸载脚本
# 版本: v1.4.0
# 功能: 完全卸载 Home Assistant 环境和配置
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

log "starting Home Assistant uninstallation"
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
log "removing Home Assistant installation"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"uninstalling\",\"message\":\"removing installation directory\",\"timestamp\":$(date +%s)}"

proot-distro login "$PROOT_DISTRO" << 'EOF'
log_step() {
    echo -e "\n[STEP] $1"
}

log_step "killing Home Assistant if running"
# 查找并杀死 Home Assistant 进程
HASS_PID=$(pgrep -f '[h]omeassistant' | head -n1)
if [ -n "$HASS_PID" ]; then
    kill "$HASS_PID" && echo "[INFO] killed Home Assistant process $HASS_PID" || echo "[INFO] failed to kill process"
else
    echo "[INFO] no Home Assistant process found"
fi

log_step "removing virtual environment"
rm -rf /root/homeassistant

log_step "removing configuration directory"
rm -rf /root/.homeassistant

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
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"uninstalled\",\"message\":\"Home Assistant completely removed\",\"timestamp\":$(date +%s)}"

log "Home Assistant uninstallation completed"
exit 0

#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Zigbee2MQTT 卸载脚本
# 版本: v1.1.0
# 功能: 完全卸载 Zigbee2MQTT 环境和配置
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

log "starting zigbee2mqtt uninstallation"
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
log "removing zigbee2mqtt installation"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"uninstalling\",\"message\":\"removing installation directory\",\"timestamp\":$(date +%s)}"

proot-distro login "$PROOT_DISTRO" << 'EOF'
log_step() {
    echo -e "\n[STEP] $1"
}

log_step "killing zigbee2mqtt if running"
# 通过8080端口找到zigbee2mqtt进程
Z2M_PORT_PID=$(netstat -tnlp 2>/dev/null | grep ':8080 ' | awk '{print $7}' | cut -d'/' -f1 | head -n1)
if [ -n "$Z2M_PORT_PID" ] && [ "$Z2M_PORT_PID" != "-" ]; then
    # 检查进程工作目录确认是zigbee2mqtt
    Z2M_CWD=$(ls -l /proc/$Z2M_PORT_PID/cwd 2>/dev/null | grep -o 'zigbee2mqtt' || true)
    if [ -n "$Z2M_CWD" ]; then
        kill "$Z2M_PORT_PID" && echo "[INFO] killed z2m process $Z2M_PORT_PID" || echo "[INFO] failed to kill process"
    else
        echo "[INFO] process on port 8080 is not zigbee2mqtt"
    fi
else
    echo "[INFO] no process found on port 8080"
fi

log_step "removing zigbee2mqtt installation"
rm -rf /opt/zigbee2mqtt

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
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"uninstalled\",\"message\":\"zigbee2mqtt completely removed\",\"timestamp\":$(date +%s)}"

log "zigbee2mqtt uninstallation completed"
exit 0

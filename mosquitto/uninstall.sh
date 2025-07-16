#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Mosquitto 卸载脚本
# 版本: v1.0.0
# 功能: 完全卸载 Mosquitto 环境和配置
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

log "starting mosquitto uninstallation"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"uninstalling\",\"message\":\"starting uninstall process\",\"timestamp\":$(date +%s)}"

# -----------------------------------------------------------------------------
# 停止服务
# -----------------------------------------------------------------------------
log "stopping service"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"uninstalling\",\"message\":\"stopping service\",\"timestamp\":$(date +%s)}"

bash "$SERVICE_DIR/stop.sh" || true
sleep 5

# 强制杀死进程
MOSQUITTO_PID=$(get_mosquitto_pid || true)
if [ -n "$MOSQUITTO_PID" ]; then
    log "force killing mosquitto process $MOSQUITTO_PID"
    kill -9 "$MOSQUITTO_PID" 2>/dev/null || true
fi

# -----------------------------------------------------------------------------
# 备份配置（可选）
# -----------------------------------------------------------------------------
log "creating final backup before uninstall"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"uninstalling\",\"message\":\"creating final backup\",\"timestamp\":$(date +%s)}"

# 备份配置文件到备份目录
if [ -f "$MOSQUITTO_CONF_FILE" ]; then
    BACKUP_CONF="$BACKUP_DIR/mosquitto_final_backup_$(date +%Y%m%d-%H%M%S).conf"
    cp "$MOSQUITTO_CONF_FILE" "$BACKUP_CONF"
    log "configuration backed up to $BACKUP_CONF"
fi

# 备份密码文件
if [ -f "$MOSQUITTO_PASSWD_FILE" ]; then
    BACKUP_PASSWD="$BACKUP_DIR/mosquitto_passwd_backup_$(date +%Y%m%d-%H%M%S)"
    cp "$MOSQUITTO_PASSWD_FILE" "$BACKUP_PASSWD"
    log "password file backed up to $BACKUP_PASSWD"
fi

# -----------------------------------------------------------------------------
# 移除服务监控目录
# -----------------------------------------------------------------------------
log "removing service monitor directory"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"uninstalling\",\"message\":\"removing service monitor directory\",\"timestamp\":$(date +%s)}"

if [ -d "$SERVICE_CONTROL_DIR" ]; then
    rm -rf "$SERVICE_CONTROL_DIR"
    log "removed service control directory: $SERVICE_CONTROL_DIR"
fi

# -----------------------------------------------------------------------------
# 卸载 Mosquitto 包
# -----------------------------------------------------------------------------
log "uninstalling mosquitto package"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"uninstalling\",\"message\":\"uninstalling mosquitto package\",\"timestamp\":$(date +%s)}"

if command -v mosquitto >/dev/null 2>&1; then
    if ! pkg uninstall -y mosquitto; then
        log "warning: failed to uninstall mosquitto package cleanly"
    else
        log "mosquitto package uninstalled successfully"
    fi
else
    log "mosquitto package not found, skipping uninstall"
fi

# -----------------------------------------------------------------------------
# 清理配置文件
# -----------------------------------------------------------------------------
log "cleaning up configuration files"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"uninstalling\",\"message\":\"cleaning up configuration files\",\"timestamp\":$(date +%s)}"

# 移除配置目录
if [ -d "$MOSQUITTO_CONF_DIR" ]; then
    rm -rf "$MOSQUITTO_CONF_DIR"
    log "removed configuration directory: $MOSQUITTO_CONF_DIR"
fi

# 移除日志目录
if [ -d "$MOSQUITTO_LOG_DIR" ]; then
    rm -rf "$MOSQUITTO_LOG_DIR"
    log "removed log directory: $MOSQUITTO_LOG_DIR"
fi

# 移除持久化数据目录
PERSISTENCE_DIR="$TERMUX_VAR_DIR/lib/mosquitto"
if [ -d "$PERSISTENCE_DIR" ]; then
    rm -rf "$PERSISTENCE_DIR"
    log "removed persistence directory: $PERSISTENCE_DIR"
fi

# 移除PID文件
if [ -f "$MOSQUITTO_PID_FILE" ]; then
    rm -f "$MOSQUITTO_PID_FILE"
    log "removed PID file: $MOSQUITTO_PID_FILE"
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
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"uninstalled\",\"message\":\"mosquitto completely removed\",\"timestamp\":$(date +%s)}"

log "mosquitto uninstallation completed"
exit 0
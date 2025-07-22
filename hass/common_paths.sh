# =============================================================================
# 优化版本的 common_paths.sh 关键函数
# =============================================================================

# 全局路径变量（避免重复计算）
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
PROOT_ROOTFS="/data/data/com.termux/files/usr/var/lib/proot-distro/installed-rootfs/$PROOT_DISTRO"
FAST_HA_BINARY="$PROOT_ROOTFS/root/homeassistant/bin/hass"
FAST_HA_CONFIG="$PROOT_ROOTFS/root/.homeassistant"

# -----------------------------------------------------------------------------
# 优化版本的状态检查函数
# -----------------------------------------------------------------------------

# 改进的 RUN 状态检查 - 优化版本
get_improved_run_status() {
    # 检查是否有 start.sh 进程在运行
    if pgrep -f "$SERVICE_DIR/start.sh" > /dev/null 2>&1; then
        echo "starting"
        return
    fi
    
    # 检查是否有 stop.sh 进程在运行
    if pgrep -f "$SERVICE_DIR/stop.sh" > /dev/null 2>&1; then
        echo "stopping"
        return
    fi
    
    # 快速检查：直接调用优化后的 status.sh
    local status_output
    status_output=$(bash "$SERVICE_DIR/status.sh" 2>/dev/null)
    
    case "$status_output" in
        "running") echo "running" ;;
        "starting") echo "starting" ;;
        "stopped") echo "stopped" ;;
        *) echo "stopped" ;;
    esac
}

# 改进的 INSTALL 状态检查 - 优化版本
get_improved_install_status() {
    # 检查是否有 install.sh 进程在运行
    if pgrep -f "$SERVICE_DIR/install.sh" > /dev/null 2>&1; then
        echo "installing"
        return
    fi
    
    # 检查是否有 uninstall.sh 进程在运行
    if pgrep -f "$SERVICE_DIR/uninstall.sh" > /dev/null 2>&1; then
        echo "uninstalling"
        return
    fi
    
    # 快速检查安装状态：直接检查文件存在性
    if [[ -f "$FAST_HA_BINARY" && -d "$FAST_HA_CONFIG" ]]; then
        echo "success"
    else
        # 检查安装历史记录
        if [[ -f "$INSTALL_HISTORY_FILE" && -s "$INSTALL_HISTORY_FILE" ]]; then
            local last_install_line=$(tail -n1 "$INSTALL_HISTORY_FILE" 2>/dev/null)
            if [[ -n "$last_install_line" ]]; then
                if echo "$last_install_line" | grep -q "UNINSTALL SUCCESS"; then
                    echo "uninstalled"
                    return
                elif echo "$last_install_line" | grep -q "INSTALL FAILED"; then
                    echo "failed"
                    return
                fi
            fi
        fi
        echo "never"
    fi
}

# 改进的 BACKUP 状态检查 - 优化版本
get_improved_backup_status() {
    # 检查是否有 backup.sh 进程在运行
    if pgrep -f "$SERVICE_DIR/backup.sh" > /dev/null 2>&1; then
        echo "backuping"
        return
    fi
    
    # 快速检查：统计备份文件数量
    local backup_count=0
    if [[ -d "$BACKUP_DIR" ]]; then
        backup_count=$(ls -1 "$BACKUP_DIR"/homeassistant_backup_*.tar.gz 2>/dev/null | wc -l)
    fi
    
    if [[ "$backup_count" -gt 0 ]]; then
        echo "success"
    else
        echo "never"
    fi
}

# 改进的 UPDATE 状态检查 - 优化版本
get_improved_update_status() {
    # 检查是否有 update.sh 进程在运行
    if pgrep -f "$SERVICE_DIR/update.sh" > /dev/null 2>&1; then
        echo "updating"
        return
    fi
    
    # 快速检查更新历史记录
    if [[ -f "$UPDATE_HISTORY_FILE" && -s "$UPDATE_HISTORY_FILE" ]]; then
        local last_update_line=$(tail -n1 "$UPDATE_HISTORY_FILE" 2>/dev/null)
        if [[ -n "$last_update_line" ]]; then
            if echo "$last_update_line" | grep -q "SUCCESS"; then
                echo "success"
            elif echo "$last_update_line" | grep -q "FAILED"; then
                echo "failed"
            else
                echo "never"
            fi
        else
            echo "never"
        fi
    else
        echo "never"
    fi
}

# 改进的 RESTORE 状态检查 - 优化版本
get_improved_restore_status() {
    # 检查是否有 restore.sh 进程在运行
    if pgrep -f "$SERVICE_DIR/restore.sh" > /dev/null 2>&1; then
        echo "restoring"
        return
    fi
    
    # 快速检查：配置文件是否存在
    if [[ -f "$FAST_HA_CONFIG/configuration.yaml" ]]; then
        echo "success"
    else
        echo "never"
    fi
}

# -----------------------------------------------------------------------------
# 优化版本的辅助函数
# -----------------------------------------------------------------------------

# 获取 Home Assistant 进程 PID - 优化版本
get_ha_pid() {
    # 使用更高效的方法：结合 pgrep 和 netstat 检查
    local pids=$(pgrep -f '[h]omeassistant' 2>/dev/null)
    
    for pid in $pids; do
        if netstat -tnlp 2>/dev/null | grep -q ":$HA_PORT.*$pid/"; then
            echo "$pid"
            return 0
        fi
    done
    
    return 1
}

# 检查 Home Assistant 端口状态 - 优化版本
check_ha_port() {
    nc -z 127.0.0.1 "$HA_PORT" >/dev/null 2>&1
}

# 快速获取当前 HA 版本
get_current_ha_version() {
    # 优先从缓存文件读取
    if [[ -f "$VERSION_FILE" ]]; then
        local cached_version=$(grep -Po 'version: \K.*' "$VERSION_FILE" 2>/dev/null | head -n1)
        if [[ -n "$cached_version" && "$cached_version" != "unknown" ]]; then
            echo "$cached_version"
            return
        fi
    fi
    
    # 直接文件检查
    if [[ -f "$FAST_HA_BINARY" ]]; then
        # 尝试通过 Python 快速解析
        if command -v python3 >/dev/null 2>&1; then
            local version_output=$(python3 -c "
import sys
sys.path.insert(0, '$PROOT_ROOTFS/root/homeassistant/lib/python3.11/site-packages')
try:
    import homeassistant
    print(homeassistant.__version__)
except:
    print('unknown')
" 2>/dev/null || echo "unknown")
            echo "$version_output"
        else
            echo "unknown"
        fi
    else
        echo "unknown"
    fi
}

# 生成状态消息 - 优化版本
generate_status_message() {
    local run_status="$1"
    
    case "$run_status" in
        "running")
            local ha_pid=$(get_ha_pid 2>/dev/null || echo "")
            if [[ -n "$ha_pid" ]]; then
                local uptime_seconds=$(ps -o etimes= -p "$ha_pid" 2>/dev/null | xargs || echo 0)
                local uptime_minutes=$(( uptime_seconds / 60 ))
                
                if [[ $uptime_minutes -lt 5 ]]; then
                    echo "Home Assistant restarted $uptime_minutes minutes ago"
                elif [[ $uptime_minutes -lt 60 ]]; then
                    echo "Home Assistant running for $uptime_minutes minutes"
                else
                    local uptime_hours=$(( uptime_minutes / 60 ))
                    echo "Home Assistant running for $uptime_hours hours"
                fi
            else
                echo "Home Assistant is running"
            fi
            ;;
        "starting")
            echo "Home Assistant is starting up"
            ;;
        "stopping")
            echo "Home Assistant is stopping"
            ;;
        "stopped")
            echo "Home Assistant is not running"
            ;;
        "failed")
            echo "Home Assistant failed to start"
            ;;
        *)
            echo "Home Assistant status unknown"
            ;;
    esac
}

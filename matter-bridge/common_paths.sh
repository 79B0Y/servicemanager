#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Matter Bridge 统一路径定义
# 版本: v1.0.0
# 说明: 定义所有脚本使用的统一路径，避免路径不一致问题
# =============================================================================

# =============================================================================
# 基础服务信息
# =============================================================================
SERVICE_ID="matter-bridge"
SERVICE_NAME="Matter Bridge"

# =============================================================================
# 基础目录结构
# =============================================================================
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"
TERMUX_VAR_DIR="/data/data/com.termux/files/usr/var"
TERMUX_TMP_DIR="/data/data/com.termux/files/usr/tmp"

# =============================================================================
# 配置文件路径
# =============================================================================
CONFIG_FILE="$BASE_DIR/configuration.yaml"
SERVICEUPDATE_FILE="$BASE_DIR/serviceupdate.json"

# =============================================================================
# 日志和状态文件
# =============================================================================
LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/${SERVICE_ID}.log"
VERSION_FILE="$SERVICE_DIR/VERSION"
DISABLED_FLAG="$SERVICE_DIR/.disabled"
LOCK_FILE_AUTOCHECK="$SERVICE_DIR/.lock_autocheck"
LAST_CHECK_FILE="$SERVICE_DIR/.lastcheck"

# =============================================================================
# 备份相关路径
# =============================================================================
BACKUP_DIR="/sdcard/isgbackup/$SERVICE_ID"
INSTALL_HISTORY_FILE="$BACKUP_DIR/.install_history"
UPDATE_HISTORY_FILE="$BACKUP_DIR/.update_history"

# =============================================================================
# 服务控制相关路径
# =============================================================================
SERVICE_CONTROL_DIR="$TERMUX_VAR_DIR/service/$SERVICE_ID"
RUN_FILE="$SERVICE_CONTROL_DIR/run"
DOWN_FILE="$SERVICE_CONTROL_DIR/down"
CONTROL_FILE="$SERVICE_CONTROL_DIR/supervise/control"

# =============================================================================
# PRoot 环境配置
# =============================================================================
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
PROOT_ROOTFS="/data/data/com.termux/files/usr/var/lib/proot-distro/installed-rootfs/$PROOT_DISTRO"

# =============================================================================
# Matter Bridge 安装路径 (容器内)
# =============================================================================
BRIDGE_INSTALL_DIR="/usr/lib/node_modules/home-assistant-matter-hub"
BRIDGE_START_SCRIPT="$BRIDGE_INSTALL_DIR/matter-bridge-start.sh"
BRIDGE_DATA_DIR="/root/.matter_server"
BRIDGE_CONFIG_FILE="$BRIDGE_DATA_DIR/config.json"
HASS_TOKEN_FILE="/sdcard/isgbackup/hass/token.txt"

# =============================================================================
# 网络和端口配置
# =============================================================================
BRIDGE_PORT="8482"  # Home Assistant Matter Hub 默认端口
BRIDGE_LISTEN_IP="0.0.0.0"
HASS_URL="http://127.0.0.1:8123"

# =============================================================================
# 脚本运行参数
# =============================================================================
MAX_WAIT="${MAX_WAIT:-300}"        # 最大等待时间 (秒)
RETRY_INTERVAL="${RETRY_INTERVAL:-60}"  # 重试间隔 (秒)
MAX_TRIES="${MAX_TRIES:-3}"        # 最大重试次数
INTERVAL="${INTERVAL:-5}"          # 检查间隔 (秒)
KEEP_BACKUPS="${KEEP_BACKUPS:-3}"  # 保留备份数量

# =============================================================================
# 临时目录配置
# =============================================================================
TEMP_DIR="$TERMUX_TMP_DIR/${SERVICE_ID}_temp"
TEMP_BACKUP_DIR="$TERMUX_TMP_DIR/${SERVICE_ID}_backup_$$"
TEMP_RESTORE_DIR="$TERMUX_TMP_DIR/${SERVICE_ID}_restore_$$"

# =============================================================================
# 系统依赖包列表
# =============================================================================
SYSTEM_DEPENDENCIES=(
    "nodejs"
    "npm"
    "python3"
    "python3-pip"
    "curl"
    "wget"
    "unzip"
    "git"
)

# =============================================================================
# NPM 包信息
# =============================================================================
BRIDGE_PACKAGE_NAME="home-assistant-matter-hub"

# =============================================================================
# HTTP 超时配置
# =============================================================================
HTTP_TIMEOUT=5
STARTUP_TIMEOUT=120

# =============================================================================
# 函数：确保必要目录存在
# =============================================================================
ensure_directories() {
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    mkdir -p "$BACKUP_DIR" 2>/dev/null || true
    mkdir -p "$SERVICE_CONTROL_DIR" 2>/dev/null || true
    mkdir -p "$TEMP_DIR" 2>/dev/null || true
}

# =============================================================================
# 函数：清理临时目录
# =============================================================================
cleanup_temp() {
    rm -rf "$TEMP_DIR" 2>/dev/null || true
    rm -rf "$TEMP_BACKUP_DIR" 2>/dev/null || true
    rm -rf "$TEMP_RESTORE_DIR" 2>/dev/null || true
}

# =============================================================================
# 函数：获取当前时间戳
# =============================================================================
get_timestamp() {
    date +%s
}

# =============================================================================
# 函数：获取格式化时间
# =============================================================================
get_formatted_time() {
    date '+%Y-%m-%d %H:%M:%S'
}

# =============================================================================
# 版本信息
# =============================================================================
SCRIPT_VERSION="1.0.0"
SCRIPT_DATE="2025-08-03"

# =============================================================================
# 调试信息 (当被直接执行时)
# =============================================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Matter Bridge 统一路径配置"
    echo "=========================="
    echo "SERVICE_ID: $SERVICE_ID"
    echo "BASE_DIR: $BASE_DIR"
    echo "BRIDGE_PORT: $BRIDGE_PORT"
    echo "BRIDGE_DATA_DIR: $BRIDGE_DATA_DIR"
    echo "BACKUP_DIR: $BACKUP_DIR"
    echo "TEMP_DIR: $TEMP_DIR"
    echo ""
    echo "系统依赖数量: ${#SYSTEM_DEPENDENCIES[@]}"
fi
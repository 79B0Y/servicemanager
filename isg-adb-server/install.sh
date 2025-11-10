#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# isg-adb-server 安装脚本
# 版本: v1.0.0
# 功能: 安装 android-tools 并配置 ADB 服务
# =============================================================================

set -euo pipefail

# =============================================================================
# 路径和配置定义
# =============================================================================
SERVICE_ID="isg-adb-server"

# 基础目录
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"
CONFIG_FILE="$BASE_DIR/configuration.yaml"

# 日志和状态文件
LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/install.log"
VERSION_FILE="$SERVICE_DIR/VERSION"
INSTALL_HISTORY_FILE="$SERVICE_DIR/.install_history"

# 服务监控相关路径
TERMUX_VAR_DIR="/data/data/com.termux/files/usr/var"
SERVICE_CONTROL_DIR="$TERMUX_VAR_DIR/service/$SERVICE_ID"
RUN_FILE="$SERVICE_CONTROL_DIR/run"
DOWN_FILE="$SERVICE_CONTROL_DIR/down"

# ADB 配置
ADB_PORT="5555"
ADB_HOST="127.0.0.1"
ADB_DEVICE="${ADB_HOST}:${ADB_PORT}"

# 脚本参数
MAX_WAIT="${MAX_WAIT:-300}"
INTERVAL="${INTERVAL:-5}"

# =============================================================================
# 工具函数
# =============================================================================
ensure_directories() {
    mkdir -p "$LOG_DIR"
    mkdir -p "$SERVICE_CONTROL_DIR"
    touch "$INSTALL_HISTORY_FILE" 2>/dev/null || true
}

log() {
    echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"
}

load_mqtt_conf() {
    if [[ -f "$CONFIG_FILE" ]]; then
        MQTT_HOST=$(grep -Po '^[[:space:]]*host:[[:space:]]*\K.*' "$CONFIG_FILE" 2>/dev/null | head -n1 || echo "127.0.0.1")
        MQTT_PORT=$(grep -Po '^[[:space:]]*port:[[:space:]]*\K.*' "$CONFIG_FILE" 2>/dev/null | head -n1 || echo "1883")
        MQTT_USER=$(grep -Po '^[[:space:]]*username:[[:space:]]*\K.*' "$CONFIG_FILE" 2>/dev/null | head -n1 || echo "admin")
        MQTT_PASS=$(grep -Po '^[[:space:]]*password:[[:space:]]*\K.*' "$CONFIG_FILE" 2>/dev/null | head -n1 || echo "admin")
    else
        MQTT_HOST="127.0.0.1"
        MQTT_PORT="1883"
        MQTT_USER="admin"
        MQTT_PASS="admin"
    fi
}

mqtt_report() {
    local topic="$1"
    local payload="$2"
    load_mqtt_conf
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload" || true
    log "[MQTT] $topic -> $payload"
}

get_android_tools_version() {
    pkg show android-tools 2>/dev/null | grep -oP '(?<=Version: )[0-9.r\-]+' | head -n1 || echo "unknown"
}

record_install_history() {
    local status="$1"
    local version="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$timestamp INSTALL $status $version" >> "$INSTALL_HISTORY_FILE"
}

# =============================================================================
# 主程序开始
# =============================================================================
ensure_directories
START_TIME=$(date +%s)

log "starting isg-adb-server installation process"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"starting installation process\",\"timestamp\":$(date +%s)}"

# -----------------------------------------------------------------------------
# 检查是否已安装
# -----------------------------------------------------------------------------
if pkg list-installed 2>/dev/null | grep -q "^android-tools/"; then
    CURRENT_VERSION=$(get_android_tools_version)
    log "android-tools already installed, version: $CURRENT_VERSION"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"skipped\",\"message\":\"android-tools already installed\",\"version\":\"$CURRENT_VERSION\",\"timestamp\":$(date +%s)}"
    
    # 仍然需要配置 ADB 和注册服务
    log "configuring ADB and service monitor"
else
    # -----------------------------------------------------------------------------
    # 安装 android-tools
    # -----------------------------------------------------------------------------
    log "installing android-tools package"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"installing android-tools package\",\"timestamp\":$(date +%s)}"

    if ! pkg update && pkg install -y android-tools; then
        log "failed to install android-tools"
        mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"android-tools installation failed\",\"timestamp\":$(date +%s)}"
        record_install_history "FAILED" "unknown"
        exit 1
    fi

    INSTALLED_VERSION=$(get_android_tools_version)
    log "android-tools installed successfully, version: $INSTALLED_VERSION"
fi

# -----------------------------------------------------------------------------
# 配置 ADB TCP 端口 (需要 root 权限)
# -----------------------------------------------------------------------------
log "configuring ADB TCP port"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"configuring ADB TCP port\",\"timestamp\":$(date +%s)}"

# 尝试配置 ADB，如果失败不阻止安装
if command -v su >/dev/null 2>&1; then
    log "attempting to configure ADB with root privileges"
    if su -c "
        setprop service.adb.tcp.port $ADB_PORT
        stop adbd
        sleep 2
        start adbd
    " 2>/dev/null; then
        log "ADB TCP port configured successfully"
        sleep 3  # 等待 adbd 重启
    else
        log "warning: failed to configure ADB with root (su command failed or no root)"
        log "you may need to manually configure ADB: su -c 'setprop service.adb.tcp.port 5555 && stop adbd && start adbd'"
    fi
else
    log "warning: su command not available, skipping ADB configuration"
    log "you may need to manually configure ADB: su -c 'setprop service.adb.tcp.port 5555 && stop adbd && start adbd'"
fi

# -----------------------------------------------------------------------------
# 注册 servicemonitor 服务看护
# -----------------------------------------------------------------------------
log "registering servicemonitor service"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"registering servicemonitor service\",\"timestamp\":$(date +%s)}"

# 创建服务目录
mkdir -p "$SERVICE_CONTROL_DIR"

# 写入 run 启动脚本
cat << 'EOF' > "$RUN_FILE"
#!/data/data/com.termux/files/usr/bin/sh
# 启动 isg-adb-server (连接 ADB)
exec adb connect 127.0.0.1:5555 2>&1
EOF

# 赋予执行权限
chmod +x "$RUN_FILE"

# 创建 down 文件（初始状态不自启）
touch "$DOWN_FILE"

log "servicemonitor service registered successfully"

# -----------------------------------------------------------------------------
# 启动服务测试
# -----------------------------------------------------------------------------
log "starting service for testing"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"starting service for testing\",\"timestamp\":$(date +%s)}"

bash "$SERVICE_DIR/start.sh" || true

# -----------------------------------------------------------------------------
# 等待服务启动
# -----------------------------------------------------------------------------
log "waiting for service ready"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"waiting for service ready\",\"timestamp\":$(date +%s)}"

WAITED=0
while [ "$WAITED" -lt "$MAX_WAIT" ]; do
    if bash "$SERVICE_DIR/status.sh" --quiet; then
        log "service is running after ${WAITED}s"
        break
    fi
    sleep "$INTERVAL"
    WAITED=$((WAITED + INTERVAL))
done

if [ "$WAITED" -ge "$MAX_WAIT" ]; then
    log "warning: service not running after ${MAX_WAIT}s, but installation completed"
    log "you may need to manually connect ADB or configure root access"
fi

# -----------------------------------------------------------------------------
# 停止服务 (安装完成后暂停运行)
# -----------------------------------------------------------------------------
bash "$SERVICE_DIR/stop.sh" || true

# -----------------------------------------------------------------------------
# 记录安装历史
# -----------------------------------------------------------------------------
log "recording installation history"
VERSION_STR=$(get_android_tools_version)
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"recording installation history\",\"version\":\"$VERSION_STR\",\"timestamp\":$(date +%s)}"

echo "$VERSION_STR" > "$VERSION_FILE"
record_install_history "SUCCESS" "$VERSION_STR"

# -----------------------------------------------------------------------------
# 安装完成
# -----------------------------------------------------------------------------
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

log "isg-adb-server installation completed successfully in ${DURATION}s"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"installed\",\"version\":\"$VERSION_STR\",\"duration\":$DURATION,\"timestamp\":$END_TIME}"

log "================================================"
log "安装摘要:"
log "  - android-tools 版本: $VERSION_STR"
log "  - ADB 端口: $ADB_PORT"
log "  - ADB 设备: $ADB_DEVICE"
log "  - 服务状态: 已停止 (使用 start.sh 启动)"
log "================================================"
log "提示: 如果 ADB 连接失败，请手动执行:"
log "  su -c 'setprop service.adb.tcp.port 5555 && stop adbd && start adbd'"
log "  adb connect 127.0.0.1:5555"

exit 0

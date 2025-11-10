#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# isg-adb-server 安装脚本
# 版本: v1.1.0
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
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload" 2>/dev/null || true
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

check_adb_available() {
    # 刷新环境变量
    hash -r 2>/dev/null || true
    command -v adb >/dev/null 2>&1
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
ALREADY_INSTALLED=false

# 检查包是否真的已安装（不是仅存在于软件源）
if pkg list-installed 2>/dev/null | grep -q "^android-tools/"; then
    CURRENT_VERSION=$(get_android_tools_version)
    log "android-tools already installed, version: $CURRENT_VERSION"
    
    # 检查 adb 命令是否真的可用
    if check_adb_available; then
        log "adb command is available, skipping installation"
        ALREADY_INSTALLED=true
    else
        log "adb command not available, will reinstall"
    fi
elif dpkg -l android-tools 2>/dev/null | tail -n1 | awk '{print $1}' | grep -q "^ii$"; then
    CURRENT_VERSION=$(get_android_tools_version)
    log "android-tools installed (dpkg check), version: $CURRENT_VERSION"
    
    if check_adb_available; then
        log "adb command is available, skipping installation"
        ALREADY_INSTALLED=true
    else
        log "adb command not available, will reinstall"
    fi
else
    log "android-tools not installed"
fi

# -----------------------------------------------------------------------------
# 安装或重新安装 android-tools
# -----------------------------------------------------------------------------
if [ "$ALREADY_INSTALLED" = false ]; then
    log "installing android-tools package"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"installing android-tools package\",\"timestamp\":$(date +%s)}"

    # 先尝试卸载（如果有残留）
    if pkg list-installed 2>/dev/null | grep -q "^android-tools/"; then
        log "removing old android-tools installation"
        pkg uninstall -y android-tools 2>/dev/null || true
        sleep 2
    fi

    # 安装
    if ! pkg install -y android-tools; then
        log "failed to install android-tools"
        mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"android-tools installation failed\",\"timestamp\":$(date +%s)}"
        record_install_history "FAILED" "unknown"
        exit 1
    fi

    log "android-tools installation completed"
    
    # 刷新命令缓存
    hash -r 2>/dev/null || true
    
    # 验证安装
    sleep 2
    if ! check_adb_available; then
        log "warning: adb command still not available after installation"
        log "trying to locate adb manually..."
        
        # 尝试找到 adb
        ADB_PATH=$(find $PREFIX -name "adb" -type f 2>/dev/null | head -n1)
        if [ -n "$ADB_PATH" ]; then
            log "found adb at: $ADB_PATH"
            if [ ! -L "$PREFIX/bin/adb" ]; then
                ln -sf "$ADB_PATH" "$PREFIX/bin/adb" 2>/dev/null || true
                chmod +x "$PREFIX/bin/adb" 2>/dev/null || true
                hash -r 2>/dev/null || true
            fi
        fi
        
        # 再次检查
        if ! check_adb_available; then
            log "error: adb command still not available"
            log "please restart termux and run this script again"
            mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"adb command not available after installation\",\"timestamp\":$(date +%s)}"
            record_install_history "FAILED" "unknown"
            exit 1
        fi
    fi
    
    INSTALLED_VERSION=$(get_android_tools_version)
    log "android-tools installed successfully, version: $INSTALLED_VERSION"
else
    INSTALLED_VERSION=$(get_android_tools_version)
    log "using existing android-tools installation, version: $INSTALLED_VERSION"
fi

# -----------------------------------------------------------------------------
# 配置 ADB TCP 端口 (需要 root 权限)
# -----------------------------------------------------------------------------
log "configuring ADB TCP port"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"configuring ADB TCP port\",\"timestamp\":$(date +%s)}"

# 检查 su 是否可用
if command -v su >/dev/null 2>&1; then
    log "attempting to configure ADB with root privileges"
    
    # 尝试配置 ADB (交互式方式最可靠)
    CONFIG_SUCCESS=false
    
    # 方法 1: 交互式 su (最可靠)
    if ! $CONFIG_SUCCESS; then
        log "trying interactive su method..."
        if su <<EOF 2>/dev/null
setprop service.adb.tcp.port $ADB_PORT
stop adbd
sleep 2
start adbd
exit
EOF
        then
            log "ADB TCP port configured successfully (interactive su)"
            CONFIG_SUCCESS=true
        fi
    fi
    
    # 方法 2: su 0
    if ! $CONFIG_SUCCESS; then
        log "trying su 0 method..."
        if su 0 sh -c "setprop service.adb.tcp.port $ADB_PORT; stop adbd; sleep 2; start adbd" 2>/dev/null; then
            log "ADB TCP port configured successfully (su 0)"
            CONFIG_SUCCESS=true
        fi
    fi
    
    if $CONFIG_SUCCESS; then
        sleep 3  # 等待 adbd 重启
        log "waiting for adbd to restart..."
    else
        log "warning: automatic ADB configuration failed"
        log "please manually configure ADB using one of these methods:"
        log "  Method 1 (recommended):"
        log "    su"
        log "    setprop service.adb.tcp.port 5555"
        log "    stop adbd"
        log "    start adbd"
        log "    exit"
        log "  Method 2: Enable 'Wireless debugging' in Android Developer Options"
    fi
else
    log "warning: su command not available"
    log "alternative: Enable 'Wireless debugging' in Android Developer Options"
fi

# -----------------------------------------------------------------------------
# 连接 ADB
# -----------------------------------------------------------------------------
log "attempting to connect ADB"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"connecting ADB\",\"timestamp\":$(date +%s)}"

ADB_CONNECTED=false
if check_adb_available; then
    # 尝试连接
    if adb connect "$ADB_DEVICE" 2>/dev/null | grep -q "connected"; then
        log "ADB connected successfully to $ADB_DEVICE"
        ADB_CONNECTED=true
    else
        log "warning: ADB connection failed"
        log "this is normal if adbd is not configured yet"
    fi
else
    log "error: adb command not available for connection test"
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
# 测试服务脚本
# -----------------------------------------------------------------------------
if [ "$ADB_CONNECTED" = true ]; then
    log "testing service scripts"
    
    # 测试 status.sh
    if [ -f "$SERVICE_DIR/status.sh" ]; then
        log "testing status.sh..."
        if bash "$SERVICE_DIR/status.sh" --quiet; then
            log "status.sh test passed"
        else
            log "warning: status.sh test failed (this is ok if adbd not fully configured)"
        fi
    fi
else
    log "skipping service tests (ADB not connected)"
fi

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
log "  - ADB 命令: $(check_adb_available && echo "可用" || echo "不可用")"
log "  - ADB 端口: $ADB_PORT"
log "  - ADB 设备: $ADB_DEVICE"
if [ "$ADB_CONNECTED" = true ]; then
    log "  - 连接状态: 已连接 ✓"
else
    log "  - 连接状态: 未连接 (需要配置)"
fi
log "  - 服务状态: 已停止 (使用 start.sh 启动)"
log "================================================"

if [ "$ADB_CONNECTED" = false ]; then
    log ""
    log "⚠️  ADB 未连接，请手动配置:"
    log ""
    log "方法 1: 使用 Root 权限 (推荐)"
    log "  su"
    log "  setprop service.adb.tcp.port 5555"
    log "  stop adbd"
    log "  start adbd"
    log "  exit"
    log "  adb connect 127.0.0.1:5555"
    log ""
    log "方法 2: 使用配置助手"
    log "  bash setup-adb.sh"
    log ""
    log "配置完成后运行:"
    log "  bash start.sh    # 启动服务"
    log "  bash status.sh   # 检查状态"
else
    log ""
    log "✓ 安装完成！可以使用以下命令:"
    log "  bash start.sh    # 启动服务"
    log "  bash stop.sh     # 停止服务"
    log "  bash status.sh   # 检查状态"
fi

exit 0

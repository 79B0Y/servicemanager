#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# isgtrigger 安装脚本
# 版本: v1.0.0
# 功能: 安装 isgtrigger 服务并配置服务监控
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# 路径和变量定义
# -----------------------------------------------------------------------------
SERVICE_ID="isgtrigger"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"
TERMUX_VAR_DIR="/data/data/com.termux/files/usr/var"
TERMUX_TMP_DIR="/data/data/com.termux/files/usr/tmp"

CONFIG_FILE="$BASE_DIR/configuration.yaml"
SERVICEUPDATE_FILE="$BASE_DIR/serviceupdate.json"
VERSION_FILE="$SERVICE_DIR/VERSION"

ISGTRIGGER_INSTALL_DIR="$TERMUX_VAR_DIR/service/isgtrigger"
ISGTRIGGER_BINARY="$ISGTRIGGER_INSTALL_DIR/isgtrigger"

SERVICE_CONTROL_DIR="$TERMUX_VAR_DIR/service/$SERVICE_ID"
CONTROL_FILE="$SERVICE_CONTROL_DIR/supervise/control"
DOWN_FILE="$SERVICE_CONTROL_DIR/down"
RUN_FILE="$SERVICE_CONTROL_DIR/run"

LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/install.log"
BACKUP_DIR="/sdcard/isgbackup/$SERVICE_ID"
INSTALL_HISTORY_FILE="$BACKUP_DIR/.install_history"

ISGTRIGGER_PORT="61833"
ISGTRIGGER_DEB_URL="https://eucfg.linklinkiot.com/isg/isgtrigger-2.2.1-3-g88e159e-88e159e-termux-arm.deb"
ISGTRIGGER_DEB_FILE="isgtrigger.deb"

# -----------------------------------------------------------------------------
# 辅助函数
# -----------------------------------------------------------------------------
ensure_directories() {
    mkdir -p "$LOG_DIR"
    mkdir -p "$BACKUP_DIR"
    mkdir -p "$SERVICE_CONTROL_DIR"
    mkdir -p "$TERMUX_TMP_DIR"
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

mqtt_report_to_file() {
    local topic="$1"
    local payload="$2"
    echo "[$(date '+%F %T')] [MQTT-PENDING] $topic -> $payload" >> "$LOG_FILE"
}

get_isgtrigger_pid() {
    local port_pid=$(netstat -tnlp 2>/dev/null | grep ":$ISGTRIGGER_PORT " | awk '{print $7}' | cut -d'/' -f1 | head -n1)
    
    if [ -n "$port_pid" ] && [ "$port_pid" != "-" ]; then
        local process_name=$(ps -p "$port_pid" -o comm= 2>/dev/null)
        if [ "$process_name" = "isgtrigger" ]; then
            echo "$port_pid"
            return 0
        fi
    fi
    return 1
}

record_install_history() {
    local status="$1"
    local version="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$timestamp INSTALL $status $version" >> "$INSTALL_HISTORY_FILE"
}

START_TIME=$(date +%s)

# -----------------------------------------------------------------------------
# 主安装流程
# -----------------------------------------------------------------------------
ensure_directories

log "开始安装 isgtrigger 服务"
mqtt_report_to_file "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"starting installation process\",\"timestamp\":$(date +%s)}"

# -----------------------------------------------------------------------------
# 下载 isgtrigger deb 包
# -----------------------------------------------------------------------------
log "下载 isgtrigger deb 包"
mqtt_report_to_file "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"downloading isgtrigger package\",\"timestamp\":$(date +%s)}"

cd "$TERMUX_TMP_DIR"

# 清理旧的下载文件
rm -f "$ISGTRIGGER_DEB_FILE"

if ! wget "$ISGTRIGGER_DEB_URL" -O "$ISGTRIGGER_DEB_FILE"; then
    log "下载 isgtrigger deb 包失败"
    mqtt_report_to_file "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"download failed\",\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "download_failed"
    exit 1
fi

log "isgtrigger deb 包下载成功"

# -----------------------------------------------------------------------------
# 安装 isgtrigger 包
# -----------------------------------------------------------------------------
log "安装 isgtrigger 包"
mqtt_report_to_file "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"installing isgtrigger package\",\"timestamp\":$(date +%s)}"

if ! dpkg -i "$ISGTRIGGER_DEB_FILE"; then
    log "isgtrigger 包安装失败"
    mqtt_report_to_file "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"package installation failed\",\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "package_install_failed"
    rm -f "$ISGTRIGGER_DEB_FILE"
    exit 1
fi

# 清理下载文件
rm -f "$ISGTRIGGER_DEB_FILE"

# 验证安装
log "验证 isgtrigger 安装"
if [ ! -f "$ISGTRIGGER_BINARY" ]; then
    log "isgtrigger 二进制文件不存在，安装失败"
    mqtt_report_to_file "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"binary file not found after installation\",\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "binary_not_found"
    exit 1
fi

# 获取版本信息
VERSION_STR=$(dpkg -s isgtrigger 2>/dev/null | grep 'Version' | awk '{print $2}' || echo "unknown")
log "isgtrigger 包安装成功，版本: $VERSION_STR"

mqtt_report_to_file "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"isgtrigger installed successfully\",\"version\":\"$VERSION_STR\",\"timestamp\":$(date +%s)}"

# -----------------------------------------------------------------------------
# 注册服务监控
# -----------------------------------------------------------------------------
log "注册 isgservicemonitor 服务"
mqtt_report_to_file "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"registering service monitor\",\"timestamp\":$(date +%s)}"

# 创建 run 文件
cat > "$RUN_FILE" << 'EOF'
#!/data/data/com.termux/files/usr/bin/sh
# isgtrigger 服务启动脚本，由 isgservicemonitor 管理
exec /data/data/com.termux/files/usr/var/service/isgtrigger/isgtrigger 2>&1
EOF

chmod +x "$RUN_FILE"

# 创建 down 文件，禁用自动启动
touch "$DOWN_FILE"
log "已创建 run 和 down 文件"

# -----------------------------------------------------------------------------
# 启动服务进行测试
# -----------------------------------------------------------------------------
log "启动服务进行测试"
mqtt_report_to_file "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"starting service for testing\",\"timestamp\":$(date +%s)}"

# 启动服务
if [ -e "$SERVICE_CONTROL_DIR/supervise/control" ]; then
    echo u > "$SERVICE_CONTROL_DIR/supervise/control"
    rm -f "$DOWN_FILE"  # 移除 down 文件以启用服务
else
    log "控制文件不存在，直接启动 isgtrigger 进行测试"
    "$ISGTRIGGER_BINARY" &
    DIRECT_PID=$!
fi

# -----------------------------------------------------------------------------
# 等待服务启动并验证
# -----------------------------------------------------------------------------
log "等待服务启动"
mqtt_report_to_file "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"waiting for service ready\",\"timestamp\":$(date +%s)}"

MAX_WAIT=60
INTERVAL=2
WAITED=0

while [ "$WAITED" -lt "$MAX_WAIT" ]; do
    if get_isgtrigger_pid > /dev/null 2>&1; then
        log "isgtrigger 在 ${WAITED}s 后启动成功"
        break
    fi
    sleep "$INTERVAL"
    WAITED=$((WAITED + INTERVAL))
done

if [ "$WAITED" -ge "$MAX_WAIT" ]; then
    log "超时: isgtrigger 在 ${MAX_WAIT}s 后仍未启动"
    mqtt_report_to_file "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"service start timeout\",\"timeout\":$MAX_WAIT,\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "$VERSION_STR"
    exit 1
fi

# -----------------------------------------------------------------------------
# 验证端口监听
# -----------------------------------------------------------------------------
log "验证端口监听"
sleep 3

if ! netstat -tulnp 2>/dev/null | grep ":$ISGTRIGGER_PORT" > /dev/null; then
    log "警告: isgtrigger 未监听在端口 $ISGTRIGGER_PORT"
    # 不作为致命错误，继续安装流程
fi

# -----------------------------------------------------------------------------
# 停止测试服务 (安装完成后暂停运行)
# -----------------------------------------------------------------------------
log "停止测试服务"
if [ -e "$SERVICE_CONTROL_DIR/supervise/control" ]; then
    echo d > "$SERVICE_CONTROL_DIR/supervise/control"
    touch "$DOWN_FILE"  # 创建 down 文件禁用自启动
else
    # 杀死直接启动的进程
    if [ -n "${DIRECT_PID:-}" ]; then
        kill "$DIRECT_PID" 2>/dev/null || true
        log "已停止测试 isgtrigger 进程 $DIRECT_PID"
    fi
    ISGTRIGGER_PID=$(get_isgtrigger_pid || echo "")
    if [ -n "$ISGTRIGGER_PID" ]; then
        kill "$ISGTRIGGER_PID" 2>/dev/null || true
        log "已停止测试 isgtrigger 进程 $ISGTRIGGER_PID"
    fi
fi

sleep 2

# -----------------------------------------------------------------------------
# 记录安装历史和版本信息
# -----------------------------------------------------------------------------
log "记录安装历史"
mqtt_report_to_file "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"recording installation history\",\"version\":\"$VERSION_STR\",\"timestamp\":$(date +%s)}"

echo "$VERSION_STR" > "$VERSION_FILE"
record_install_history "SUCCESS" "$VERSION_STR"

# -----------------------------------------------------------------------------
# 安装完成
# -----------------------------------------------------------------------------
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

log "isgtrigger 安装完成，耗时 ${DURATION}s"

# 构建完整的安装报告
INSTALL_REPORT="{\"service\":\"$SERVICE_ID\",\"status\":\"installed\",\"version\":\"$VERSION_STR\",\"duration\":$DURATION,\"timestamp\":$END_TIME}"

mqtt_report_to_file "isg/install/$SERVICE_ID/status" "$INSTALL_REPORT"

log "安装摘要:"
log "  - 版本: $VERSION_STR"
log "  - 二进制文件: $ISGTRIGGER_BINARY"
log "  - 监听端口: $ISGTRIGGER_PORT"
log "  - 服务控制: $SERVICE_CONTROL_DIR"
log "  - 耗时: ${DURATION}s"

exit 0
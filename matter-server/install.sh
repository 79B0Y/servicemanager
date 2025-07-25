#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Matter Server 安装脚本
# 版本: v1.0.0
# 功能: 在 proot Ubuntu 环境中安装 python-matter-server
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# 路径和变量定义
# -----------------------------------------------------------------------------
SERVICE_ID="matter-server"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"
TERMUX_VAR_DIR="/data/data/com.termux/files/usr/var"
TERMUX_TMP_DIR="/data/data/com.termux/files/usr/tmp"

CONFIG_FILE="$BASE_DIR/configuration.yaml"
SERVICEUPDATE_FILE="$BASE_DIR/serviceupdate.json"
VERSION_FILE="$SERVICE_DIR/VERSION"

SERVICE_CONTROL_DIR="$TERMUX_VAR_DIR/service/$SERVICE_ID"
CONTROL_FILE="$SERVICE_CONTROL_DIR/supervise/control"
DOWN_FILE="$SERVICE_CONTROL_DIR/down"
RUN_FILE="$SERVICE_CONTROL_DIR/run"

LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/install.log"
BACKUP_DIR="/sdcard/isgbackup/$SERVICE_ID"
INSTALL_HISTORY_FILE="$BACKUP_DIR/.install_history"

PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
MATTER_INSTALL_DIR="/opt/matter-server"
MATTER_DATA_DIR="/opt/matter-server/data"
MATTER_VENV_DIR="/opt/matter-server/venv"
MATTER_PORT="5580"

MAX_WAIT=300
INTERVAL=5

# -----------------------------------------------------------------------------
# 辅助函数
# -----------------------------------------------------------------------------
ensure_directories() {
    mkdir -p "$LOG_DIR"
    mkdir -p "$BACKUP_DIR"
    mkdir -p "$SERVICE_CONTROL_DIR"
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

mqtt_report() {
    local topic="$1"
    local payload="$2"
    
    # 检查 MQTT broker 是否可用
    if ! nc -z 127.0.0.1 1883 2>/dev/null; then
        echo "[$(date '+%F %T')] [MQTT-OFFLINE] $topic -> $payload" >> "$LOG_FILE"
        return 0
    fi
    
    load_mqtt_conf
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT_CONFIG" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload" 2>/dev/null || true
    echo "[$(date '+%F %T')] [MQTT] $topic -> $payload" >> "$LOG_FILE"
}

get_matter_pid() {
    local port_pid=$(netstat -tnlp 2>/dev/null | grep ":$MATTER_PORT " | awk '{print $7}' | cut -d'/' -f1 | head -n1)
    
    if [ -n "$port_pid" ] && [ "$port_pid" != "-" ]; then
        local cmdline=$(cat /proc/$port_pid/cmdline 2>/dev/null | grep -o 'matter-server\|python.*matter' || true)
        if [ -n "$cmdline" ]; then
            echo "$port_pid"
            return 0
        fi
    fi
    return 1
}

get_current_version() {
    proot-distro login "$PROOT_DISTRO" -- bash -c "source $MATTER_VENV_DIR/bin/activate && pip show python-matter-server | grep ^Version: | awk '{print \$2}'" 2>/dev/null || echo "unknown"
}

get_latest_version() {
    jq -r ".services[] | select(.id==\"$SERVICE_ID\") | .latest_service_version" "$SERVICEUPDATE_FILE" 2>/dev/null || echo "unknown"
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

log "开始安装 Matter Server"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"starting installation process\",\"timestamp\":$(date +%s)}"

# -----------------------------------------------------------------------------
# 读取服务依赖配置
# -----------------------------------------------------------------------------
log "读取服务依赖配置"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"reading service dependencies from serviceupdate.json\",\"timestamp\":$(date +%s)}"

if [ ! -f "$SERVICEUPDATE_FILE" ]; then
    log "serviceupdate.json 不存在，使用默认依赖"
    DEPENDENCIES='["python3","python3-pip","python3-venv","build-essential","libssl-dev","libffi-dev","python3-dev","git","cmake","ninja-build"]'
else
    DEPENDENCIES=$(jq -c ".services[] | select(.id==\"$SERVICE_ID\") | .install_dependencies // [\"python3\",\"python3-pip\",\"python3-venv\",\"build-essential\",\"libssl-dev\",\"libffi-dev\",\"python3-dev\",\"git\",\"cmake\",\"ninja-build\"]" "$SERVICEUPDATE_FILE" 2>/dev/null || echo '["python3","python3-pip","python3-venv","build-essential","libssl-dev","libffi-dev","python3-dev","git","cmake","ninja-build"]')
fi

# 转换为 bash 数组
DEPS_ARRAY=($(echo "$DEPENDENCIES" | jq -r '.[]' 2>/dev/null || echo "python3 python3-pip python3-venv build-essential libssl-dev libffi-dev python3-dev git cmake ninja-build"))

log "安装系统依赖: ${DEPS_ARRAY[*]}"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"installing system dependencies\",\"dependencies\":$DEPENDENCIES,\"timestamp\":$(date +%s)}"

# -----------------------------------------------------------------------------
# 安装系统依赖（在 proot 容器内）
# -----------------------------------------------------------------------------
log "在 proot 容器内安装系统依赖"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"installing system dependencies in proot container\",\"timestamp\":$(date +%s)}"

if ! proot-distro login "$PROOT_DISTRO" -- bash -c "
    apt update && apt upgrade -y
    apt install -y ${DEPS_ARRAY[*]}
"; then
    log "系统依赖安装失败"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"dependency installation failed\",\"dependencies\":$DEPENDENCIES,\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

# -----------------------------------------------------------------------------
# 检查 Python 版本
# -----------------------------------------------------------------------------
log "检查 Python 和 pip 版本"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"checking python and pip versions\",\"timestamp\":$(date +%s)}"

PYTHON_VERSION=$(proot-distro login "$PROOT_DISTRO" -- python3 --version 2>/dev/null || echo "not installed")
PIP_VERSION=$(proot-distro login "$PROOT_DISTRO" -- pip3 --version 2>/dev/null || echo "not installed")

log "Python 版本: $PYTHON_VERSION"
log "pip 版本: $PIP_VERSION"

if [[ "$PYTHON_VERSION" == "not installed" ]] || [[ "$PIP_VERSION" == "not installed" ]]; then
    log "Python 或 pip 未正确安装"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"python or pip not properly installed\",\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

# -----------------------------------------------------------------------------
# 获取目标版本
# -----------------------------------------------------------------------------
TARGET_VERSION=$(get_latest_version)
if [ "$TARGET_VERSION" = "unknown" ]; then
    TARGET_VERSION="6.6.0"  # 默认版本
    log "使用默认 Matter Server 版本: $TARGET_VERSION"
else
    log "目标 Matter Server 版本: $TARGET_VERSION"
fi

# -----------------------------------------------------------------------------
# 创建安装目录和虚拟环境
# -----------------------------------------------------------------------------
log "创建安装目录和虚拟环境"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"creating virtual environment\",\"timestamp\":$(date +%s)}"

if ! proot-distro login "$PROOT_DISTRO" -- bash -c "
    mkdir -p $MATTER_INSTALL_DIR
    mkdir -p $MATTER_DATA_DIR
    cd $MATTER_INSTALL_DIR
    python3 -m venv venv
    source venv/bin/activate
    pip install --upgrade pip
"; then
    log "虚拟环境创建失败"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"virtual environment creation failed\",\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

# -----------------------------------------------------------------------------
# 安装 cryptography 和其他基础依赖
# -----------------------------------------------------------------------------
log "安装基础 Python 依赖"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"installing python dependencies\",\"timestamp\":$(date +%s)}"

if ! proot-distro login "$PROOT_DISTRO" -- bash -c "
    cd $MATTER_INSTALL_DIR
    source venv/bin/activate
    pip install cryptography wheel setuptools
"; then
    log "基础 Python 依赖安装失败"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"python dependencies installation failed\",\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

# -----------------------------------------------------------------------------
# 安装 python-matter-server
# -----------------------------------------------------------------------------
log "安装 python-matter-server"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"installing python-matter-server\",\"timestamp\":$(date +%s)}"

if ! proot-distro login "$PROOT_DISTRO" -- bash -c "
    cd $MATTER_INSTALL_DIR
    source venv/bin/activate
    pip install python-matter-server==$TARGET_VERSION
"; then
    log "python-matter-server 安装失败"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"python-matter-server installation failed\",\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

# 获取安装的版本
VERSION_STR=$(get_current_version)
log "Matter Server 版本: $VERSION_STR"

# -----------------------------------------------------------------------------
# 创建配置文件
# -----------------------------------------------------------------------------
log "创建默认配置文件"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"creating configuration files\",\"timestamp\":$(date +%s)}"

proot-distro login "$PROOT_DISTRO" -- bash -c "
cat > $MATTER_DATA_DIR/config.yaml << 'EOF'
# Matter Server Configuration
server:
  listen_host: '0.0.0.0'
  listen_port: 5580
  
# Storage settings
storage_path: '$MATTER_DATA_DIR/matter.json'

# Logging configuration
log_level: 'INFO'

# MQTT Bridge (optional)
# mqtt:
#   broker_url: 'mqtt://localhost:1883'
#   username: 'matter'
#   password: 'matter'
EOF
"

# -----------------------------------------------------------------------------
# 注册 servicemonitor 服务看护
# -----------------------------------------------------------------------------
log "注册 isgservicemonitor 服务"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"registering service monitor\",\"timestamp\":$(date +%s)}"

# 创建 run 文件
cat > "$RUN_FILE" << EOF
#!/data/data/com.termux/files/usr/bin/sh
exec proot-distro login $PROOT_DISTRO << 'PROOT_EOF'
cd $MATTER_INSTALL_DIR
source venv/bin/activate
matter-server --config-file $MATTER_DATA_DIR/config.yaml --storage-path $MATTER_DATA_DIR/matter.json
PROOT_EOF
2>&1
EOF

chmod +x "$RUN_FILE"

# 创建 down 文件，禁用自动启动
touch "$DOWN_FILE"
log "已创建 run 和 down 文件"

# -----------------------------------------------------------------------------
# 启动服务进行测试
# -----------------------------------------------------------------------------
log "启动服务进行测试"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"starting service for testing\",\"timestamp\":$(date +%s)}"

# 启动服务
if [ -e "$SERVICE_CONTROL_DIR/supervise/control" ]; then
    echo u > "$SERVICE_CONTROL_DIR/supervise/control"
    rm -f "$DOWN_FILE"  # 移除 down 文件以启用服务
else
    log "控制文件不存在，直接启动 Matter Server 进行测试"
    # 在后台启动 Matter Server 进行测试
    proot-distro login "$PROOT_DISTRO" -- bash -c "cd $MATTER_INSTALL_DIR && source venv/bin/activate && matter-server --config-file $MATTER_DATA_DIR/config.yaml --storage-path $MATTER_DATA_DIR/matter.json" &
fi

# -----------------------------------------------------------------------------
# 等待服务启动并验证
# -----------------------------------------------------------------------------
log "等待服务启动"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"waiting for service ready\",\"timestamp\":$(date +%s)}"

WAITED=0
while [ "$WAITED" -lt "$MAX_WAIT" ]; do
    if get_matter_pid > /dev/null 2>&1; then
        log "Matter Server 在 ${WAITED}s 后启动成功"
        break
    fi
    sleep "$INTERVAL"
    WAITED=$((WAITED + INTERVAL))
done

if [ "$WAITED" -ge "$MAX_WAIT" ]; then
    log "超时: Matter Server 在 ${MAX_WAIT}s 后仍未启动"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"service start timeout after installation\",\"timeout\":$MAX_WAIT,\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "$VERSION_STR"
    exit 1
fi

# -----------------------------------------------------------------------------
# 验证端口监听
# -----------------------------------------------------------------------------
log "验证端口监听"
sleep 3

if timeout 10 nc -z 127.0.0.1 "$MATTER_PORT" 2>/dev/null; then
    log "端口 $MATTER_PORT 验证成功"
else
    log "警告: 端口 $MATTER_PORT 验证失败，但继续安装流程"
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
    MATTER_PID=$(get_matter_pid || echo "")
    if [ -n "$MATTER_PID" ]; then
        kill "$MATTER_PID" 2>/dev/null || true
        log "已停止测试 Matter Server 进程 $MATTER_PID"
    fi
fi

sleep 2

# -----------------------------------------------------------------------------
# 记录安装历史和版本信息
# -----------------------------------------------------------------------------
log "记录安装历史"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"recording installation history\",\"version\":\"$VERSION_STR\",\"timestamp\":$(date +%s)}"

echo "$VERSION_STR" > "$VERSION_FILE"
record_install_history "SUCCESS" "$VERSION_STR"

# -----------------------------------------------------------------------------
# 安装完成
# -----------------------------------------------------------------------------
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

log "Matter Server 安装完成，耗时 ${DURATION}s"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"installed\",\"version\":\"$VERSION_STR\",\"duration\":$DURATION,\"timestamp\":$END_TIME}"

log "安装摘要:"
log "  - 版本: $VERSION_STR"
log "  - 安装目录: $MATTER_INSTALL_DIR"
log "  - 数据目录: $MATTER_DATA_DIR"
log "  - 监听端口: $MATTER_PORT"
log "  - 服务控制: $SERVICE_CONTROL_DIR"

exit 0

#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Matter Server 安装脚本
# 版本: v1.0.0
# 功能: 在 proot Ubuntu 环境中安装 Matter Server
# =============================================================================

set -euo pipefail

# =============================================================================
# 路径和配置定义
# =============================================================================
SERVICE_ID="matter-server"
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"

# 基础目录
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"
CONFIG_FILE="$BASE_DIR/configuration.yaml"
SERVICEUPDATE_FILE="$BASE_DIR/serviceupdate.json"

# 日志和状态文件
LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/install.log"
VERSION_FILE="$SERVICE_DIR/VERSION"
INSTALL_HISTORY_FILE="$SERVICE_DIR/.install_history"

# 服务监控相关路径
SERVICE_CONTROL_DIR="/data/data/com.termux/files/usr/var/service/$SERVICE_ID"
RUN_FILE="$SERVICE_CONTROL_DIR/run"
DOWN_FILE="$SERVICE_CONTROL_DIR/down"

# 容器内路径
MATTER_INSTALL_DIR="/opt/matter-server"
MATTER_ENV_DIR="$MATTER_INSTALL_DIR/venv"
MATTER_CONFIG_FILE="$MATTER_INSTALL_DIR/config.yaml"
MATTER_SDK_DIR="$MATTER_INSTALL_DIR/connectedhomeip"

# Matter 特定配置
MATTER_PORT="8443"
WS_PORT="5540"
MATTER_SDK_VERSION="${MATTER_SDK_VERSION:-v2023-09-28}"
PYTHON_VERSION="${PYTHON_VERSION:-3.12.6}"

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

get_current_version() {
    proot-distro login "$PROOT_DISTRO" -- bash -c "
        source $MATTER_ENV_DIR/bin/activate 2>/dev/null || exit 1
        python -c 'import matter_server; print(matter_server.__version__)' 2>/dev/null || echo 'unknown'
    " 2>/dev/null || echo "unknown"
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

log "starting matter-server installation process"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"starting installation process\",\"timestamp\":$(date +%s)}"

# -----------------------------------------------------------------------------
# 读取服务依赖配置
# -----------------------------------------------------------------------------
log "reading service dependencies from serviceupdate.json"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"reading service dependencies from serviceupdate.json\",\"timestamp\":$(date +%s)}"

if [ ! -f "$SERVICEUPDATE_FILE" ]; then
    log "serviceupdate.json not found, using default dependencies"
    DEPENDENCIES='["build-essential","libssl-dev","libffi-dev","python3-dev","git","cmake","ninja-build","python3","python3-pip","python3-venv"]'
else
    DEPENDENCIES=$(jq -c ".services[] | select(.id==\"$SERVICE_ID\") | .install_dependencies // [\"build-essential\",\"libssl-dev\",\"libffi-dev\",\"python3-dev\",\"git\",\"cmake\",\"ninja-build\",\"python3\",\"python3-pip\",\"python3-venv\"]" "$SERVICEUPDATE_FILE" 2>/dev/null || echo '["build-essential","libssl-dev","libffi-dev","python3-dev","git","cmake","ninja-build","python3","python3-pip","python3-venv"]')
fi

# 转换为 bash 数组
DEPS_ARRAY=($(echo "$DEPENDENCIES" | jq -r '.[]' 2>/dev/null || echo "build-essential libssl-dev libffi-dev python3-dev git cmake ninja-build python3 python3-pip python3-venv"))

log "installing required dependencies: ${DEPS_ARRAY[*]}"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"installing required dependencies\",\"dependencies\":$DEPENDENCIES,\"timestamp\":$(date +%s)}"

# -----------------------------------------------------------------------------
# 安装系统依赖
# -----------------------------------------------------------------------------
log "installing system dependencies in proot container"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"installing system dependencies\",\"timestamp\":$(date +%s)}"

if ! proot-distro login "$PROOT_DISTRO" -- bash -c "
    apt-get update
    apt-get install -y ${DEPS_ARRAY[*]}
"; then
    log "failed to install system dependencies"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"dependency installation failed\",\"dependencies\":$DEPENDENCIES,\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

# -----------------------------------------------------------------------------
# 创建安装目录和Python虚拟环境
# -----------------------------------------------------------------------------
log "creating installation directory and Python virtual environment"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"creating virtual environment\",\"timestamp\":$(date +%s)}"

if ! proot-distro login "$PROOT_DISTRO" -- bash -c "
    mkdir -p $MATTER_INSTALL_DIR
    cd $MATTER_INSTALL_DIR
    python3 -m venv venv
    source venv/bin/activate
    pip install --upgrade pip setuptools wheel
"; then
    log "failed to create virtual environment"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"virtual environment creation failed\",\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

# -----------------------------------------------------------------------------
# 安装基础 Python 依赖
# -----------------------------------------------------------------------------
log "installing basic Python dependencies"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"installing Python dependencies\",\"timestamp\":$(date +%s)}"

if ! proot-distro login "$PROOT_DISTRO" -- bash -c "
    cd $MATTER_INSTALL_DIR
    source venv/bin/activate
    pip install cryptography
"; then
    log "failed to install basic Python dependencies"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"Python dependencies installation failed\",\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

# -----------------------------------------------------------------------------
# 克隆和编译 ConnectedHomeIP (Matter SDK)
# -----------------------------------------------------------------------------
log "cloning ConnectedHomeIP (Matter SDK)"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"cloning ConnectedHomeIP SDK\",\"timestamp\":$(date +%s)}"

if ! proot-distro login "$PROOT_DISTRO" -- bash -c "
    cd $MATTER_INSTALL_DIR
    git clone --recursive https://github.com/project-chip/connectedhomeip.git
    cd connectedhomeip
    git checkout $MATTER_SDK_VERSION
"; then
    log "failed to clone ConnectedHomeIP"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"ConnectedHomeIP clone failed\",\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

log "building ConnectedHomeIP Python bindings"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"building ConnectedHomeIP Python bindings\",\"timestamp\":$(date +%s)}"

if ! proot-distro login "$PROOT_DISTRO" -- bash -c "
    cd $MATTER_INSTALL_DIR/connectedhomeip
    source ../venv/bin/activate
    
    # 安装 GN (Generate Ninja)
    git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git
    export PATH=\$PWD/depot_tools:\$PATH
    
    # 生成构建文件
    gn gen out/python --args='is_debug=false is_component_build=false python_bindings=true'
    
    # 编译
    ninja -C out/python
    
    # 安装 Python 包
    pip install ./out/python/python_dist/chip_python-*.whl
"; then
    log "failed to build ConnectedHomeIP"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"ConnectedHomeIP build failed\",\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

# -----------------------------------------------------------------------------
# 安装 python-matter-server
# -----------------------------------------------------------------------------
log "installing python-matter-server"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"installing python-matter-server\",\"timestamp\":$(date +%s)}"

if ! proot-distro login "$PROOT_DISTRO" -- bash -c "
    cd $MATTER_INSTALL_DIR
    source venv/bin/activate
    pip install python-matter-server
"; then
    log "failed to install python-matter-server"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"python-matter-server installation failed\",\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

# 获取安装的版本
VERSION_STR=$(get_current_version)
log "matter-server version: $VERSION_STR"

# -----------------------------------------------------------------------------
# 生成 SSL 证书
# -----------------------------------------------------------------------------
log "generating SSL certificates"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"generating SSL certificates\",\"timestamp\":$(date +%s)}"

proot-distro login "$PROOT_DISTRO" -- bash -c "
    cd $MATTER_INSTALL_DIR
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout privatekey.pem \
        -out certificate.pem \
        -subj '/C=US/ST=State/L=City/O=Organization/CN=matter-server'
"

# -----------------------------------------------------------------------------
# 生成初始配置文件
# -----------------------------------------------------------------------------
log "generating initial configuration"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"generating initial configuration\",\"timestamp\":$(date +%s)}"

# 获取 MQTT 配置
load_mqtt_conf

proot-distro login "$PROOT_DISTRO" -- bash -c "
cat > $MATTER_CONFIG_FILE << EOF
mqtt:
  broker: 'mqtt://$MQTT_HOST:$MQTT_PORT'
  username: '$MQTT_USER'
  password: '$MQTT_PASS'

matter:
  listen_ip: '0.0.0.0'
  port: $MATTER_PORT
  storage_path: '$MATTER_INSTALL_DIR/storage'
  ssl:
    certfile: '$MATTER_INSTALL_DIR/certificate.pem'
    keyfile: '$MATTER_INSTALL_DIR/privatekey.pem'

logging:
  level: 'INFO'
  file: '$MATTER_INSTALL_DIR/matter-server.log'
EOF
"

# 创建存储目录
proot-distro login "$PROOT_DISTRO" -- mkdir -p "$MATTER_INSTALL_DIR/storage"

# -----------------------------------------------------------------------------
# 注册 servicemonitor 服务看护
# -----------------------------------------------------------------------------
log "registering servicemonitor service"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"registering servicemonitor service\",\"timestamp\":$(date +%s)}"

# 创建服务目录
mkdir -p "$SERVICE_CONTROL_DIR"

# 写入 run 启动脚本
cat << 'EOF' > "$RUN_FILE"
#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Matter Server Run 脚本 - isgservicemonitor 服务启动脚本
# 版本: v1.0.0
# 功能: 由 isgservicemonitor 调用，启动 Matter Server 守护进程
# =============================================================================

set -euo pipefail

# 基础配置
SERVICE_ID="matter-server"
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
MATTER_INSTALL_DIR="/opt/matter-server"
MATTER_ENV_DIR="$MATTER_INSTALL_DIR/venv"
MATTER_CONFIG_FILE="$MATTER_INSTALL_DIR/config.yaml"

# 日志文件
LOG_FILE="/data/data/com.termux/files/home/servicemanager/$SERVICE_ID/logs/run.log"
mkdir -p "$(dirname "$LOG_FILE")"

# 日志记录函数
log_run() {
    echo "[$(date '+%F %T')] $*" >> "$LOG_FILE"
}

# 清理函数
cleanup() {
    log_run "Matter Server shutting down..."
    exit 0
}

# 设置信号处理
trap cleanup TERM INT

log_run "Starting Matter Server daemon..."

# 检查安装目录
if ! proot-distro login "$PROOT_DISTRO" -- test -d "$MATTER_INSTALL_DIR"; then
    log_run "ERROR: Matter Server installation directory not found: $MATTER_INSTALL_DIR"
    exit 1
fi

# 检查虚拟环境
if ! proot-distro login "$PROOT_DISTRO" -- test -d "$MATTER_ENV_DIR"; then
    log_run "ERROR: Python virtual environment not found: $MATTER_ENV_DIR"
    exit 1
fi

# 检查配置文件
if ! proot-distro login "$PROOT_DISTRO" -- test -f "$MATTER_CONFIG_FILE"; then
    log_run "ERROR: Configuration file not found: $MATTER_CONFIG_FILE"
    exit 1
fi

log_run "All prerequisites checked, starting Matter Server..."

# 启动 Matter Server
exec proot-distro login "$PROOT_DISTRO" -- bash -c "
    cd $MATTER_INSTALL_DIR
    source $MATTER_ENV_DIR/bin/activate
    
    # 启动 python-matter-server
    exec python -m matter_server --config $MATTER_CONFIG_FILE
" 2>&1 | while IFS= read -r line; do
    echo "[$(date '+%F %T')] $line" >> "$LOG_FILE"
done

log_run "Matter Server process ended"
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

bash "$SERVICE_DIR/start.sh"

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
    log "timeout: service not running after ${MAX_WAIT}s"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"service start timeout after installation\",\"timeout\":$MAX_WAIT,\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "$VERSION_STR"
    exit 1
fi

# -----------------------------------------------------------------------------
# 停止服务 (安装完成后暂停运行)
# -----------------------------------------------------------------------------
bash "$SERVICE_DIR/stop.sh"

# -----------------------------------------------------------------------------
# 记录安装历史
# -----------------------------------------------------------------------------
log "recording installation history"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"recording installation history\",\"version\":\"$VERSION_STR\",\"timestamp\":$(date +%s)}"

echo "$VERSION_STR" > "$VERSION_FILE"
record_install_history "SUCCESS" "$VERSION_STR"

# -----------------------------------------------------------------------------
# 安装完成
# -----------------------------------------------------------------------------
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

log "matter-server installation completed successfully in ${DURATION}s"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"installed\",\"version\":\"$VERSION_STR\",\"duration\":$DURATION,\"timestamp\":$END_TIME}"

exit 0
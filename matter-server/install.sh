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
MATTER_SDK_VERSION="${MATTER_SDK_VERSION:-v1.4.2.0}"
PYTHON_VERSION="${PYTHON_VERSION:-3.13.3}"

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
    proot-distro login "$PROOT_DISTRO" -- bash -c '
        if [ -f "'"$MATTER_ENV_DIR"'/bin/activate" ]; then
            source "'"$MATTER_ENV_DIR"'/bin/activate"
            pip show python-matter-server 2>/dev/null | awk -F": " "/^Version/ {print \$2}" || echo "unknown"
        else
            echo "unknown"
        fi
    ' 2>/dev/null || echo "unknown"
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
if [ "$DEPENDENCIES" != "null" ] && [ -n "$DEPENDENCIES" ]; then
    readarray -t DEPS_ARRAY < <(echo "$DEPENDENCIES" | jq -r '.[]' 2>/dev/null)
else
    DEPS_ARRAY=("build-essential" "libssl-dev" "libffi-dev" "python3-dev" "git" "cmake" "ninja-build" "python3" "python3-pip" "python3-venv")
fi

# 确保数组不为空
if [ ${#DEPS_ARRAY[@]} -eq 0 ]; then
    DEPS_ARRAY=("build-essential" "libssl-dev" "libffi-dev" "python3-dev" "git" "cmake" "ninja-build" "python3" "python3-pip" "python3-venv")
fi

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
    python3 -m pip install --upgrade pip setuptools wheel

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
# 安装 python-matter-server
# -----------------------------------------------------------------------------
log "installing python-matter-server"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"installing python-matter-server\",\"timestamp\":$(date +%s)}"

if ! proot-distro login "$PROOT_DISTRO" -- bash -c "
    cd $MATTER_INSTALL_DIR
    source venv/bin/activate
    python3 -m pip install python-matter-server[server]
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
#!/data/data/com.termux/files/usr/bin/sh
# 启动 Matter Server
exec proot-distro login "$PROOT_DISTRO" -- bash -c '
    cd "$MATTER_INSTALL_DIR"
    source "$MATTER_ENV_DIR/bin/activate"
    exec matter-server
'
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

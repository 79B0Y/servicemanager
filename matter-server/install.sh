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
# 克隆和编译 ConnectedHomeIP (Matter SDK) - 优化版本
# -----------------------------------------------------------------------------
log "cloning ConnectedHomeIP (Matter SDK) with retry mechanism"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"cloning ConnectedHomeIP SDK\",\"timestamp\":$(date +%s)}"

# 设置较短的超时时间，并使用浅克隆
if ! proot-distro login "$PROOT_DISTRO" -- bash -c "
    cd $MATTER_INSTALL_DIR
    
    # 配置 git 以处理网络问题
    git config --global http.postBuffer 524288000
    git config --global http.lowSpeedLimit 1000
    git config --global http.lowSpeedTime 300
    
    # 使用浅克隆减少下载量
    git clone --depth 1 --single-branch --branch main https://github.com/project-chip/connectedhomeip.git
    cd connectedhomeip
    
    # 尝试切换到指定版本，如果失败则使用 main 分支
    if git fetch --depth 1 origin tag $MATTER_SDK_VERSION 2>/dev/null; then
        git checkout $MATTER_SDK_VERSION
        log 'switched to SDK version: $MATTER_SDK_VERSION'
    else
        log 'using main branch (SDK version tag not found)'
    fi
    
    # 只初始化必要的子模块
    git submodule update --init --depth 1 third_party/nanopb/repo || true
    git submodule update --init --depth 1 third_party/nlassert/repo || true
    git submodule update --init --depth 1 third_party/nlio/repo || true
"; then
    log "failed to clone ConnectedHomeIP"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"ConnectedHomeIP clone failed\",\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

log "building ConnectedHomeIP Python bindings (simplified)"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"building ConnectedHomeIP Python bindings\",\"timestamp\":$(date +%s)}"

if ! proot-distro login "$PROOT_DISTRO" -- bash -c "
    cd $MATTER_INSTALL_DIR/connectedhomeip
    source ../venv/bin/activate
    
    # 检查是否已安装 gn
    if ! command -v gn >/dev/null 2>&1; then
        # 安装 GN (Generate Ninja) - 使用预编译版本
        log 'installing GN build tool'
        wget -q https://chrome-infra-packages.appspot.com/dl/gn/gn/linux-arm64/+/latest -O gn.zip || {
            # 备用方案：从 depot_tools 安装
            git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git
            export PATH=\$PWD/depot_tools:\$PATH
        }
        
        if [ -f gn.zip ]; then
            unzip -q gn.zip
            chmod +x gn
            sudo mv gn /usr/local/bin/ || mv gn ../venv/bin/
        fi
    fi
    
    # 设置环境变量
    export PATH=\$PWD/depot_tools:\$PATH
    
    # 生成构建文件 - 简化配置
    mkdir -p out/python
    echo 'is_debug = false
is_component_build = false
chip_build_tests = false
chip_build_tools = false
chip_crypto = \"openssl\"
chip_use_clusters_for_ip_commissioning = true' > out/python/args.gn
    
    # 使用 GN 生成构建文件
    if command -v gn >/dev/null 2>&1; then
        gn gen out/python || {
            log 'gn gen failed, trying without args'
            echo '' > out/python/args.gn
            gn gen out/python
        }
    else
        log 'gn not available, skipping native build'
        exit 0
    fi
    
    # 编译 - 只编译必要部分
    ninja -C out/python chip-controller-py || {
        log 'ninja build failed, trying alternative approach'
        
        # 备用方案：直接安装预编译的 Matter 包
        pip install --no-deps chip-core || true
        exit 0
    }
    
    # 安装 Python 包
    if [ -f out/python/python_dist/chip_python-*.whl ]; then
        pip install ./out/python/python_dist/chip_python-*.whl
    else
        log 'no wheel found, installing alternative'
        pip install --no-deps chip-core || true
    fi
"; then
    log "SDK build failed, trying alternative installation"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"SDK build failed, using alternative method\",\"timestamp\":$(date +%s)}"
    
    # 备用方案：跳过 SDK 编译，直接安装 python-matter-server
    log "proceeding without custom SDK build"
fi

# -----------------------------------------------------------------------------
# 安装 python-matter-server
# -----------------------------------------------------------------------------
log "installing python-matter-server"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"installing python-matter-server\",\"timestamp\":$(date +%s)}"

if ! proot-distro login "$PROOT_DISTRO" -- bash -c "
    cd $MATTER_INSTALL_DIR
    source venv/bin/activate
    
    # 首先尝试安装最新版本
    pip install python-matter-server[server] || {
        log 'failed to install with [server] extras, trying basic version'
        pip install python-matter-server
    }
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

# service monitor 路径
SERVICE_CONTROL_DIR="/data/data/com.termux/files/usr/var/service/$SERVICE_ID"
# run 文件路径
RUN_FILE="$SERVICE_CONTROL_DIR/run"
# down 文件路径
DOWN_FILE="$SERVICE_CONTROL_DIR/down"

# 确保 service monitor 目录存在
mkdir -p "$SERVICE_CONTROL_DIR"

cat << 'EOF' > "$RUN_FILE"
#!/data/data/com.termux/files/usr/bin/sh

export PROCESS_TAG="$PROCESS_TAG"
exec proot-distro login ubuntu << 'INNER_EOF'
cd /opt/matter-server/
source venv/bin/activate
matter-server
INNER_EOF
EOF

# 赋予 run 文件执行权限
chmod +x "$RUN_FILE"

# 创建 down 文件,禁用服务的自动启动
touch "$DOWN_FILE"

# 提示 run 与 down 文件生成成功
log "✅ run 和 down 文件已生成: $RUN_FILE, $DOWN_FILE"

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

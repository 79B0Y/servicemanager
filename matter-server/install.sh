#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# 增强版 Matter Server 安装脚本（含 ws 5580 支持）
# - 适用于 Termux + Proot Ubuntu
# - Python 3.13.3
# - 自动编译 CHIP、生成证书、动态写入 config.yaml
# - log 用中文，MQTT 上报全英文
# =============================================================================

set -euo pipefail

# ------------------- 路径与变量 -------------------
SERVICE_ID="matter-server"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"
CONFIG_FILE="$BASE_DIR/configuration.yaml"
MATTER_INSTALL_DIR="/opt/matter-server"
MATTER_DATA_DIR="$MATTER_INSTALL_DIR/data"
MATTER_VENV_DIR="$MATTER_INSTALL_DIR/venv"
CHIP_SRC_DIR="/opt/connectedhomeip"
MATTER_PORT="8443"            # HTTPS/SSL 端口
MATTER_HTTP_PORT="5580"       # WebSocket 明文端口，供 Home Assistant 使用

TERMUX_VAR_DIR="/data/data/com.termux/files/usr/var"
SERVICE_CONTROL_DIR="$TERMUX_VAR_DIR/service/$SERVICE_ID"
RUN_FILE="$SERVICE_CONTROL_DIR/run"
DOWN_FILE="$SERVICE_CONTROL_DIR/down"
LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/install.log"

DEPS=(python3 python3.13-venv python3-pip build-essential libssl-dev libffi-dev python3-dev git cmake ninja-build jq curl openssl)

# ------------------- 函数定义 -------------------
log() {
    mkdir -p "$LOG_DIR"
    echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"
}

load_mqtt_conf() {
    if [ -f "$CONFIG_FILE" ]; then
        MQTT_HOST=$(grep -Po '^[[:space:]]*host:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1 || echo "127.0.0.1")
        MQTT_PORT=$(grep -Po '^[[:space:]]*port:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1 || echo "1883")
        MQTT_USER=$(grep -Po '^[[:space:]]*username:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1 || echo "admin")
        MQTT_PASS=$(grep -Po '^[[:space:]]*password:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1 || echo "admin")
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
    if ! nc -z "$MQTT_HOST" "$MQTT_PORT" 2>/dev/null; then
        echo "[MQTT-OFFLINE] $topic -> $payload" >> "$LOG_FILE"
        return
    fi
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload" 2>/dev/null || true
    echo "[MQTT] $topic -> $payload" >> "$LOG_FILE"
}

ensure_dirs() {
    mkdir -p "$SERVICE_DIR" "$LOG_DIR" "$MATTER_INSTALL_DIR" "$MATTER_DATA_DIR" "$SERVICE_CONTROL_DIR"
}

# ------------------- 主流程 -------------------
ensure_dirs

log "开始安装 Matter Server"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"installing dependencies\",\"timestamp\":$(date +%s)}"
log "正在更新并安装依赖包..."
proot-distro login ubuntu -- bash -c "apt update && apt install -y ${DEPS[*]}"

log "创建 Python 3.13.3 虚拟环境..."
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"creating virtual environment\",\"timestamp\":$(date +%s)}"
proot-distro login ubuntu -- bash -c "
    cd $MATTER_INSTALL_DIR
    rm -rf venv
    python3.13 -m venv venv
    source venv/bin/activate
    pip install --upgrade pip wheel setuptools
"

log "下载并编译 connectedhomeip 源码（CHIP）..."
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"cloning and building connectedhomeip\",\"timestamp\":$(date +%s)}"
proot-distro login ubuntu -- bash -c "
    cd /opt
    rm -rf connectedhomeip
    git clone --recursive https://github.com/project-chip/connectedhomeip.git
    cd connectedhomeip
    git checkout v2023-09-28
    source $MATTER_VENV_DIR/bin/activate
    pip install --upgrade pip
    gn gen out/python --args='is_debug=false is_component_build=false python_bindings=true'
    ninja -C out/python
    pip install ./out/python/python_dist/chip_python-*.whl
"

log "安装 python-matter-server..."
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"installing python-matter-server\",\"timestamp\":$(date +%s)}"
proot-distro login ubuntu -- bash -c "
    cd $MATTER_INSTALL_DIR
    source venv/bin/activate
    pip install python-matter-server
"

log "生成自签名证书..."
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"generating certificates\",\"timestamp\":$(date +%s)}"
proot-distro login ubuntu -- bash -c "
    cd $MATTER_DATA_DIR
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout privatekey.pem -out certificate.pem \
        -subj '/CN=matter-server'
"

log "写入配置文件 config.yaml..."
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"creating config file\",\"timestamp\":$(date +%s)}"
load_mqtt_conf

cat > /tmp/config.yaml <<EOF
mqtt:
  broker: 'mqtt://$MQTT_HOST:$MQTT_PORT'
  username: '$MQTT_USER'
  password: '$MQTT_PASS'

matter:
  listen_ip: '0.0.0.0'
  port: $MATTER_PORT
  http_port: $MATTER_HTTP_PORT
  ssl:
    certfile: '$MATTER_DATA_DIR/certificate.pem'
    keyfile: '$MATTER_DATA_DIR/privatekey.pem'
EOF

proot-distro login ubuntu -- bash -c "cp /tmp/config.yaml $MATTER_DATA_DIR/config.yaml"

log "注册 Termux 服务监控文件..."
cat > "$RUN_FILE" <<EOF
#!/data/data/com.termux/files/usr/bin/sh
exec proot-distro login ubuntu << 'PROOT_EOF'
cd $MATTER_INSTALL_DIR
source venv/bin/activate
python -m matter_server --config $MATTER_DATA_DIR/config.yaml
PROOT_EOF
2>&1
EOF

chmod +x "$RUN_FILE"
touch "$DOWN_FILE"

log "Matter Server 安装完成！"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installed\",\"message\":\"Matter Server installation complete\",\"timestamp\":$(date +%s)}"

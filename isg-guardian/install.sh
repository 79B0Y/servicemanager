#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# isg-guardian 安装脚本
# 版本: v1.0.0
# 功能: 在 proot Ubuntu 环境中安装 isg-guardian
# =============================================================================

set -euo pipefail

# =============================================================================
# 路径和配置定义
# =============================================================================
SERVICE_ID="isg-guardian"
PROOT_DISTRO="ubuntu"

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
GUARDIAN_INSTALL_DIR="/root/isg-guardian"
GUARDIAN_VENV_DIR="$GUARDIAN_INSTALL_DIR/venv"
GUARDIAN_CONFIG_FILE="$GUARDIAN_INSTALL_DIR/config.yaml"

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
        if [ -f "'"$GUARDIAN_VENV_DIR"'/bin/activate" ]; then
            source "'"$GUARDIAN_VENV_DIR"'/bin/activate"
            cd "'"$GUARDIAN_INSTALL_DIR"'"
            grep "VERSION = " isg-guardian 2>/dev/null | sed "s/.*VERSION = [\"'"'"']\(.*\)[\"'"'"'].*/\1/" || echo "unknown"
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



# -----------------------------------------------------------------------------
# 创建安装目录和 Python 虚拟环境
# -----------------------------------------------------------------------------
log "创建安装目录和 Python 虚拟环境"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"creating virtual environment\",\"timestamp\":$(date +%s)}"
if ! proot-distro login "$PROOT_DISTRO" -- bash -c '
    cp -rf /data/data/com.termux/files/home/servicemanager/isg-guardian/isg-guardian /root/
    cd /root/isg-guardian
    if [ ! -d "venv" ]; then
        echo "venv 不存在，正在创建..."
        python3 -m venv venv
    else
        echo "venv 已存在，跳过创建"
    fi
    source venv/bin/activate
    python3 -m pip install --upgrade pip setuptools wheel
'; then
    log "虚拟环境创建失败"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"virtual environment creation failed\",\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi
# -----------------------------------------------------------------------------
# 安装 isg-guardian
# -----------------------------------------------------------------------------
log "安装 isg-guardian"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"installing isg-guardian\",\"timestamp\":$(date +%s)}"

if ! proot-distro login "$PROOT_DISTRO" -- bash -c "
    cd /root/isg-guardian
    source venv/bin/activate
    bash install.sh
"; then
    log "isg-guardian 安装失败"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"isg-guardian installation failed\",\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi
# 获取安装的版本
VERSION_STR=$(get_current_version)
log "isg-guardian 版本: $VERSION_STR"

# -----------------------------------------------------------------------------
# 生成初始配置文件
# -----------------------------------------------------------------------------
log "生成初始配置文件"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"generating initial configuration\",\"timestamp\":$(date +%s)}"

# 获取 MQTT 配置
load_mqtt_conf

proot-distro login "$PROOT_DISTRO" -- bash -lc '
GUARDIAN_CONFIG_FILE="$HOME/isg-guardian/config.yaml"
cat > "$GUARDIAN_CONFIG_FILE" <<EOF
# iSG Guardian Configuration File
app:
  package_name: "com.linknlink.app.device.isg"
  activity_name: "cn.com.broadlink.unify.app.activity.common.LoadingActivity"

adb:
  auto_connect: true
  host: "127.0.0.1"
  port: 5555
  tcp_port: 5555
  retry_count: 3
  retry_delay: 5
  setup_commands:
    - setprop
    - "setprop service.adb.tcp.port 5555"
    - "stop adbd"
    - "start adbd"

monitor:
  check_interval: 30
  restart_delay: 5
  max_restarts: 3
  cooldown_time: 300

logging:
  crash_log_dir: "data/crash_logs"
  status_log_file: "data/app_status.log"
  max_log_files: 50
  max_file_size: "5MB"
  retention_days: 7

mqtt:
  enabled: true
  broker: "'${MQTT_HOST}'"
  port: '"${MQTT_PORT}"'
  username: "'${MQTT_USER}'"
  password: "'${MQTT_PASS}'"
  topic_prefix: "isg"
  device_id: "isg_guardian"
EOF
'

# 创建数据目录
proot-distro login "$PROOT_DISTRO" -- mkdir -p "$GUARDIAN_INSTALL_DIR/data"

# -----------------------------------------------------------------------------
# 注册 servicemonitor 服务看护
# -----------------------------------------------------------------------------
log "注册 servicemonitor 服务"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"registering servicemonitor service\",\"timestamp\":$(date +%s)}"

# 创建服务目录
mkdir -p "$SERVICE_CONTROL_DIR"

# 写入 run 启动脚本
cat << 'EOF' > "$RUN_FILE"
#!/data/data/com.termux/files/usr/bin/sh
export PROCESS_TAG="${PROCESS_TAG}"

exec proot-distro login ubuntu -- bash -lc '
  set -e
  cd /root/isg-guardian

  # 如果有 venv 就激活
  if [ -f "venv/bin/activate" ]; then
    source venv/bin/activate
  fi

  # 补齐 PATH（非交互 shell 不会加载 ~/.profile，补上 ~/.local/bin）
  export PATH="$HOME/.local/bin:$PATH"

  # 优先用命令；没有就回退到 python -m
  if command -v isg-guardian >/dev/null 2>&1; then
    exec isg-guardian start
  else
    echo "[info] isg-guardian 不在 PATH，回退到 python -m..."
    exec python -m isg_guardian start
  fi
'
EOF

# 赋予执行权限
chmod +x "$RUN_FILE"

# 创建 down 文件（初始状态不自启）
touch "$DOWN_FILE"

log "servicemonitor 服务注册成功"

# -----------------------------------------------------------------------------
# 启动服务测试
# -----------------------------------------------------------------------------
log "启动服务进行测试"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"starting service for testing\",\"timestamp\":$(date +%s)}"

bash "$SERVICE_DIR/start.sh"

# -----------------------------------------------------------------------------
# 等待服务启动
# -----------------------------------------------------------------------------
log "等待服务就绪"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"waiting for service ready\",\"timestamp\":$(date +%s)}"

WAITED=0
while [ "$WAITED" -lt "$MAX_WAIT" ]; do
    if bash "$SERVICE_DIR/status.sh" --quiet; then
        log "服务在 ${WAITED}s 后启动成功"
        break
    fi
    sleep "$INTERVAL"
    WAITED=$((WAITED + INTERVAL))
done

if [ "$WAITED" -ge "$MAX_WAIT" ]; then
    log "超时: 服务在 ${MAX_WAIT}s 后仍未启动"
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
log "记录安装历史"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"recording installation history\",\"version\":\"$VERSION_STR\",\"timestamp\":$(date +%s)}"

echo "$VERSION_STR" > "$VERSION_FILE"
record_install_history "SUCCESS" "$VERSION_STR"

# -----------------------------------------------------------------------------
# 安装完成
# -----------------------------------------------------------------------------
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

log "isg-guardian 安装成功完成，耗时 ${DURATION}s"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"installed\",\"version\":\"$VERSION_STR\",\"duration\":$DURATION,\"timestamp\":$END_TIME}"

exit 0

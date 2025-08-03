#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Matter Bridge 安装脚本 - 更新版本
# 版本: v1.2.0
# 功能: 在 proot Ubuntu 环境中使用 pnpm 安装 Home Assistant Matter Hub
# =============================================================================

set -euo pipefail

# =============================================================================
# 路径和配置定义
# =============================================================================
SERVICE_ID="matter-bridge"
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

# 容器内路径 - 修复: 使用新的路径规范
BRIDGE_SCRIPT_DIR="/sdcard/isgbackup/matter-bridge"
BRIDGE_START_SCRIPT="$BRIDGE_SCRIPT_DIR/matter-bridge-start.sh"
BRIDGE_DATA_DIR="/root/.matter_server"
BRIDGE_PACKAGE_JSON="/root/.pnpm-global/global/5/node_modules/home-assistant-matter-hub/package.json"
BRIDGE_CMD="/root/.pnpm-global/global/5/node_modules/.bin/home-assistant-matter-hub"
HASS_TOKEN_FILE="/sdcard/isgbackup/hass/token.txt"

# Matter Bridge 特定配置
BRIDGE_PORT="8482"
HASS_URL="http://127.0.0.1:8123"

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

# 修复: 使用新的版本获取方法
get_current_version() {
    proot-distro login "$PROOT_DISTRO" -- bash -c '
        VERSION_FILE="/root/.pnpm-global/global/5/node_modules/home-assistant-matter-hub/package.json"
        if [ -f "$VERSION_FILE" ]; then
            jq -r .version "$VERSION_FILE" 2>/dev/null || echo "unknown"
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

log "开始安装 Matter Bridge (pnpm 版本)"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"starting installation process with pnpm\",\"timestamp\":$(date +%s)}"

# -----------------------------------------------------------------------------
# 读取服务依赖配置
# -----------------------------------------------------------------------------
log "读取服务依赖配置"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"reading service dependencies from serviceupdate.json\",\"timestamp\":$(date +%s)}"

if [ ! -f "$SERVICEUPDATE_FILE" ]; then
    log "serviceupdate.json 未找到，使用默认依赖"
    DEPENDENCIES='["python3","python3-pip","curl","wget","unzip","git","jq"]'
else
    DEPENDENCIES=$(jq -c ".services[] | select(.id==\"$SERVICE_ID\") | .install_dependencies // [\"python3\",\"python3-pip\",\"curl\",\"wget\",\"unzip\",\"git\",\"jq\"]" "$SERVICEUPDATE_FILE" 2>/dev/null || echo '["nodejs","npm","python3","python3-pip","curl","wget","unzip","git","jq"]')
fi

# 转换为 bash 数组
if [ "$DEPENDENCIES" != "null" ] && [ -n "$DEPENDENCIES" ]; then
    readarray -t DEPS_ARRAY < <(echo "$DEPENDENCIES" | jq -r '.[]' 2>/dev/null)
else
    DEPS_ARRAY=("python3" "python3-pip" "curl" "wget" "unzip" "git" "jq")
fi

# 确保数组不为空
if [ ${#DEPS_ARRAY[@]} -eq 0 ]; then
    DEPS_ARRAY=("python3" "python3-pip" "curl" "wget" "unzip" "git" "jq")
fi

log "安装必需依赖: ${DEPS_ARRAY[*]}"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"installing required dependencies\",\"dependencies\":$DEPENDENCIES,\"timestamp\":$(date +%s)}"

# -----------------------------------------------------------------------------
# 安装系统依赖
# -----------------------------------------------------------------------------
log "在 proot 容器中安装系统依赖"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"installing system dependencies\",\"timestamp\":$(date +%s)}"

if ! proot-distro login "$PROOT_DISTRO" -- bash -c "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq ${DEPS_ARRAY[*]}
"; then
    log "系统依赖安装失败"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"dependency installation failed\",\"dependencies\":$DEPENDENCIES,\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

# -----------------------------------------------------------------------------
# 安装 pnpm
# -----------------------------------------------------------------------------
log "安装 pnpm 包管理器"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"installing pnpm package manager\",\"timestamp\":$(date +%s)}"

if ! proot-distro login "$PROOT_DISTRO" -- bash -c "
    # 安装 pnpm
    npm install -g pnpm
    
    # 验证 pnpm 安装
    pnpm --version
    
    # 配置 pnpm
    pnpm config set store-dir /root/.pnpm-store
    pnpm config set global-dir /root/.pnpm-global
    pnpm config set global-bin-dir /root/.pnpm-global/bin
"; then
    log "pnpm 安装失败"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"pnpm installation failed\",\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

# -----------------------------------------------------------------------------
# 检查 Node.js 和 pnpm 版本
# -----------------------------------------------------------------------------
log "检查 Node.js 和 pnpm 版本"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"checking node and pnpm versions\",\"timestamp\":$(date +%s)}"

if ! proot-distro login "$PROOT_DISTRO" -- bash -c "
    echo 'Node.js 版本:'
    node --version
    echo 'pnpm 版本:'
    pnpm --version
"; then
    log "Node.js 或 pnpm 未正确安装"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"node or pnpm not properly installed\",\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

# -----------------------------------------------------------------------------
# 使用 pnpm 安装 home-assistant-matter-hub
# -----------------------------------------------------------------------------
log "使用 pnpm 安装 home-assistant-matter-hub"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"installing home-assistant-matter-hub with pnpm\",\"timestamp\":$(date +%s)}"

if ! proot-distro login "$PROOT_DISTRO" -- bash -c "
    pnpm add -g home-assistant-matter-hub
"; then
    log "home-assistant-matter-hub 安装失败"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"matter-bridge installation failed\",\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

# 获取安装的版本
VERSION_STR=$(get_current_version)
log "matter-bridge 版本: $VERSION_STR"

# -----------------------------------------------------------------------------
# 生成启动脚本（路径改为 /sdcard/isgbackup/matter-bridge/）
# -----------------------------------------------------------------------------
log "生成启动脚本"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"generating startup script\",\"timestamp\":$(date +%s)}"

proot-distro login "$PROOT_DISTRO" -- bash -c "
SCRIPT_DIR=\"$BRIDGE_SCRIPT_DIR\"
START_SCRIPT=\"$BRIDGE_START_SCRIPT\"
TOKEN_FILE=\"$HASS_TOKEN_FILE\"
HUB_CMD=\"$BRIDGE_CMD\"

mkdir -p \"\$SCRIPT_DIR\"

cat << 'EOF' > \"\$START_SCRIPT\"
#!/bin/bash

export HUB_PORT=$BRIDGE_PORT
export HA_URL=\"$HASS_URL\"
TOKEN_FILE=\"$HASS_TOKEN_FILE\"
HUB_CMD=\"$BRIDGE_CMD\"

if [ -f \"\\\$TOKEN_FILE\" ]; then
  export HA_TOKEN=\\\$(cat \"\\\$TOKEN_FILE\" | tr -d \"\\\r\\\n\")
else
  echo \"[❌] HA token 文件不存在: \\\$TOKEN_FILE\" >&2
  exit 1
fi

if [ ! -x \"\\\$HUB_CMD\" ]; then
  echo \"[❌] Matter Hub 执行文件不存在: \\\$HUB_CMD\" >&2
  exit 1
fi

echo \"[✅] 启动 Home Assistant Matter Hub...\"
exec \"\\\$HUB_CMD\" start \\\\
  --home-assistant-url=\"\\\$HA_URL\" \\\\
  --home-assistant-access-token=\"\\\$HA_TOKEN\" \\\\
  --http-port=\"\\\$HUB_PORT\" \\\\
  --log-level=info
EOF

chmod +x \"\$START_SCRIPT\"
echo \"启动脚本创建完成: \$START_SCRIPT\"
"

# 创建数据目录
proot-distro login "$PROOT_DISTRO" -- mkdir -p "$BRIDGE_DATA_DIR"

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
# 启动 Home Assistant Matter Bridge 服务
START_SCRIPT="/sdcard/isgbackup/matter-bridge/matter-bridge-start.sh"

if [ ! -f "$START_SCRIPT" ]; then
  echo "[❌] 启动脚本不存在: $START_SCRIPT" >&2
  exit 1
fi

exec proot-distro login ubuntu -- bash -c "bash '$START_SCRIPT'"
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
    log "超时: 服务在 ${MAX_WAIT}s 后未启动"
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

log "matter-bridge 安装完成，耗时 ${DURATION}s"
log "如果遇到启动问题，请检查 HA token 文件: $HASS_TOKEN_FILE"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"installed\",\"version\":\"$VERSION_STR\",\"duration\":$DURATION,\"timestamp\":$END_TIME}"

exit 0

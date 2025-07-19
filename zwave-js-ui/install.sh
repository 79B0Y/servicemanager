#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Z-Wave JS UI 安装脚本
# 版本: v1.0.0
# 功能: 在 proot Ubuntu 环境中安装 Z-Wave JS UI
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# 路径和变量定义
# -----------------------------------------------------------------------------
SERVICE_ID="zwave-js-ui"
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
PNPM_HOME="/root/.pnpm-global"
ZUI_INSTALL_PATH="/root/.pnpm-global/global/5/node_modules/zwave-js-ui"
ZUI_DATA_DIR="/usr/src/app/store"
ZUI_PORT="8091"

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

get_zui_pid() {
    local port_pid=$(netstat -tnlp 2>/dev/null | grep ":$ZUI_PORT " | awk '{print $7}' | cut -d'/' -f1 | head -n1)
    
    if [ -n "$port_pid" ] && [ "$port_pid" != "-" ]; then
        local cwd=$(ls -l /proc/$port_pid/cwd 2>/dev/null | grep -o 'zwave\|node' || true)
        if [ -n "$cwd" ]; then
            echo "$port_pid"
            return 0
        fi
    fi
    return 1
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

get_current_version() {
    proot-distro login "$PROOT_DISTRO" -- bash -c "
        if [ -f '$ZUI_INSTALL_PATH/package.json' ]; then
            grep '\"version\"' '$ZUI_INSTALL_PATH/package.json' | head -n1 | sed -E 's/.*\"version\": *\"([^\"]+)\".*/\1/'
        else
            echo 'unknown'
        fi
    " 2>/dev/null || echo "unknown"
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

log "开始安装 Z-Wave JS UI"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"starting installation process\",\"timestamp\":$(date +%s)}"

# -----------------------------------------------------------------------------
# 读取服务依赖配置
# -----------------------------------------------------------------------------
log "读取服务依赖配置"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"reading service dependencies from serviceupdate.json\",\"timestamp\":$(date +%s)}"

if [ ! -f "$SERVICEUPDATE_FILE" ]; then
    log "serviceupdate.json 不存在，使用默认依赖"
    DEPENDENCIES='["nodejs","npm","git","make","g++","gcc","libsystemd-dev"]'
else
    DEPENDENCIES=$(jq -c ".services[] | select(.id==\"$SERVICE_ID\") | .install_dependencies // [\"nodejs\",\"npm\",\"git\",\"make\",\"g++\",\"gcc\",\"libsystemd-dev\"]" "$SERVICEUPDATE_FILE" 2>/dev/null || echo '["nodejs","npm","git","make","g++","gcc","libsystemd-dev"]')
fi

# 转换为 bash 数组
DEPS_ARRAY=($(echo "$DEPENDENCIES" | jq -r '.[]' 2>/dev/null || echo "nodejs npm git make g++ gcc libsystemd-dev"))

log "安装系统依赖: ${DEPS_ARRAY[*]}"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"installing required dependencies\",\"dependencies\":$DEPENDENCIES,\"timestamp\":$(date +%s)}"

# -----------------------------------------------------------------------------
# 安装系统依赖（在 proot 容器内）
# -----------------------------------------------------------------------------
log "在 proot 容器内安装系统依赖"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"installing system dependencies\",\"timestamp\":$(date +%s)}"

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
# 检查 Node.js 版本，如果版本过低则安装更新版本
# -----------------------------------------------------------------------------
log "检查并安装 Node.js"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"checking node.js and npm versions\",\"timestamp\":$(date +%s)}"

NODE_VERSION=$(proot-distro login "$PROOT_DISTRO" -- bash -c "node -v" 2>/dev/null || echo "not installed")
NPM_VERSION=$(proot-distro login "$PROOT_DISTRO" -- bash -c "npm -v" 2>/dev/null || echo "not installed")

log "当前 Node.js 版本: $NODE_VERSION"
log "当前 npm 版本: $NPM_VERSION"

# 如果 Node.js 版本不够或未安装，安装最新 LTS 版本
if [[ "$NODE_VERSION" == "not installed" ]] || [[ ! "$NODE_VERSION" =~ v2[0-9]\. ]]; then
    log "安装/更新 Node.js 到最新 LTS 版本"
    if ! proot-distro login "$PROOT_DISTRO" -- bash -c "
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
        apt-get install -y nodejs
    "; then
        log "Node.js 安装失败"
        mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"node.js installation failed\",\"timestamp\":$(date +%s)}"
        record_install_history "FAILED" "unknown"
        exit 1
    fi
fi

# 验证最终版本
NODE_VERSION=$(proot-distro login "$PROOT_DISTRO" -- bash -c "node -v" 2>/dev/null || echo "not installed")
NPM_VERSION=$(proot-distro login "$PROOT_DISTRO" -- bash -c "npm -v" 2>/dev/null || echo "not installed")

log "最终 Node.js 版本: $NODE_VERSION"
log "最终 npm 版本: $NPM_VERSION"

if [[ "$NODE_VERSION" == "not installed" ]] || [[ "$NPM_VERSION" == "not installed" ]]; then
    log "Node.js 或 npm 未正确安装"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"node.js or npm not properly installed\",\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

# -----------------------------------------------------------------------------
# 安装 pnpm 包管理器
# -----------------------------------------------------------------------------
log "安装 pnpm 包管理器"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"installing pnpm package manager\",\"timestamp\":$(date +%s)}"

if ! proot-distro login "$PROOT_DISTRO" -- bash -c "
    source ~/.bashrc 2>/dev/null || true
    if ! command -v pnpm >/dev/null 2>&1; then
        echo '安装 pnpm...'
        npm install -g pnpm@10.11.0
        echo 'pnpm 安装完成'
    else
        echo \"pnpm 已安装: \$(pnpm --version)\"
    fi
"; then
    log "pnpm 安装失败"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"pnpm installation failed\",\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

# -----------------------------------------------------------------------------
# 设置 pnpm 全局路径环境变量
# -----------------------------------------------------------------------------
log "配置 pnpm 环境变量"
proot-distro login "$PROOT_DISTRO" -- bash -c "
    export PNPM_HOME=$PNPM_HOME
    export PATH=\$PNPM_HOME:\$PATH
    export SHELL=/bin/bash

    # 添加到 bashrc 如果尚未存在
    if ! grep -q 'PNPM_HOME' ~/.bashrc; then
        echo 'export PNPM_HOME=$PNPM_HOME' >> ~/.bashrc
        echo 'export PATH=\$PNPM_HOME:\$PATH' >> ~/.bashrc
        echo 'export SHELL=/bin/bash' >> ~/.bashrc
    fi
    
    # 重新加载 bashrc
    source ~/.bashrc
    
    # 验证 pnpm 是否可用
    if command -v pnpm >/dev/null 2>&1; then
        echo \"pnpm 配置成功: \$(pnpm --version)\"
        
        # 设置 pnpm 全局目录（避免 setup 命令的问题）
        pnpm config set global-dir '$PNPM_HOME/global'
        pnpm config set global-bin-dir '$PNPM_HOME'
        
        echo \"pnpm 全局配置完成\"
    else
        echo \"pnpm 配置失败\"
        exit 1
    fi
"

# -----------------------------------------------------------------------------
# 获取目标版本
# -----------------------------------------------------------------------------
TARGET_VERSION=$(get_latest_version)
if [ "$TARGET_VERSION" = "unknown" ]; then
    TARGET_VERSION="9.18.1"  # 默认版本
    log "使用默认 Z-Wave JS UI 版本: $TARGET_VERSION"
else
    log "目标 Z-Wave JS UI 版本: $TARGET_VERSION"
fi

# -----------------------------------------------------------------------------
# 安装 Z-Wave JS UI
# -----------------------------------------------------------------------------
log "安装 Z-Wave JS UI"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"installing zwave-js-ui application\",\"timestamp\":$(date +%s)}"

if ! proot-distro login "$PROOT_DISTRO" -- bash -c "
    export PNPM_HOME=$PNPM_HOME
    export PATH=\$PNPM_HOME:\$PATH
    export SHELL=/bin/bash
    source ~/.bashrc 2>/dev/null || true
    
    # 验证 pnpm 可用性
    if ! command -v pnpm >/dev/null 2>&1; then
        echo '错误: pnpm 不可用'
        exit 1
    fi
    
    echo \"使用 pnpm 版本: \$(pnpm --version)\"
    echo \"安装 zwave-js-ui@$TARGET_VERSION\"
    
    # 安装 zwave-js-ui
    pnpm add -g zwave-js-ui@$TARGET_VERSION
"; then
    log "Z-Wave JS UI 安装失败"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"zwave-js-ui installation failed\",\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

# 获取安装的版本
VERSION_STR=$(get_current_version)
log "Z-Wave JS UI 版本: $VERSION_STR"

# -----------------------------------------------------------------------------
# 创建数据目录
# -----------------------------------------------------------------------------
log "创建 Z-Wave JS UI 数据目录"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"creating data directory\",\"timestamp\":$(date +%s)}"

proot-distro login "$PROOT_DISTRO" -- mkdir -p "$ZUI_DATA_DIR"

# -----------------------------------------------------------------------------
# 注册 servicemonitor 服务看护
# -----------------------------------------------------------------------------
log "注册 isgservicemonitor 服务"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"registering service monitor\",\"timestamp\":$(date +%s)}"

# 创建 run 文件
cat > "$RUN_FILE" << EOF
#!/data/data/com.termux/files/usr/bin/sh
exec proot-distro login $PROOT_DISTRO << 'PROOT_EOF'
export PNPM_HOME=$PNPM_HOME
export PATH=\$PNPM_HOME:\$PATH
export SHELL=/bin/bash
source ~/.bashrc 2>/dev/null || true
cd /
zwave-js-ui
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
    log "控制文件不存在，直接启动 Z-Wave JS UI 进行测试"
    # 在后台启动 Z-Wave JS UI 进行测试
    proot-distro login "$PROOT_DISTRO" -- bash -c "
        export PNPM_HOME=$PNPM_HOME
        export PATH=\$PNPM_HOME:\$PATH
        export SHELL=/bin/bash
        source ~/.bashrc 2>/dev/null || true
        cd /
        nohup zwave-js-ui > /tmp/zwave-js-ui-test.log 2>&1 &
        echo \"Z-Wave JS UI 测试启动，PID: \$!\"
    "
fi

# -----------------------------------------------------------------------------
# 等待服务启动并验证
# -----------------------------------------------------------------------------
log "等待服务启动"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"waiting for service ready\",\"timestamp\":$(date +%s)}"

WAITED=0
while [ "$WAITED" -lt "$MAX_WAIT" ]; do
    if get_zui_pid > /dev/null 2>&1; then
        log "Z-Wave JS UI 在 ${WAITED}s 后启动成功"
        break
    fi
    sleep "$INTERVAL"
    WAITED=$((WAITED + INTERVAL))
done

if [ "$WAITED" -ge "$MAX_WAIT" ]; then
    log "超时: Z-Wave JS UI 在 ${MAX_WAIT}s 后仍未启动"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"service start timeout after installation\",\"timeout\":$MAX_WAIT,\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "$VERSION_STR"
    exit 1
fi

# -----------------------------------------------------------------------------
# 验证 HTTP 接口
# -----------------------------------------------------------------------------
log "验证 HTTP 接口"
sleep 3

if timeout 10 nc -z 127.0.0.1 "$ZUI_PORT" 2>/dev/null; then
    log "HTTP 接口验证成功"
else
    log "警告: HTTP 接口验证失败，但继续安装流程"
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
    ZUI_PID=$(get_zui_pid || echo "")
    if [ -n "$ZUI_PID" ]; then
        kill "$ZUI_PID" 2>/dev/null || true
        log "已停止测试 Z-Wave JS UI 进程 $ZUI_PID"
    fi
fi

sleep 2

# -----------------------------------------------------------------------------
# 调用 restore.sh 进行配置
# -----------------------------------------------------------------------------
log "调用 restore.sh 进行初始配置"
if [ -f "$SERVICE_DIR/restore.sh" ]; then
    bash "$SERVICE_DIR/restore.sh" || {
        log "配置生成有问题，但安装继续完成"
        mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"configuration setup had issues but installation continues\",\"timestamp\":$(date +%s)}"
    }
else
    log "restore.sh 不存在，跳过配置步骤"
fi

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

log "Z-Wave JS UI 安装完成，耗时 ${DURATION}s"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"installed\",\"version\":\"$VERSION_STR\",\"duration\":$DURATION,\"timestamp\":$END_TIME}"

log "安装摘要:"
log "  - 版本: $VERSION_STR"
log "  - 安装路径: $ZUI_INSTALL_PATH"
log "  - 数据目录: $ZUI_DATA_DIR"
log "  - 监听端口: $ZUI_PORT"
log "  - 服务控制: $SERVICE_CONTROL_DIR"

exit 0
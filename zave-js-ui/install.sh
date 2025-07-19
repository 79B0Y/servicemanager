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
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"

BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"
TERMUX_VAR_DIR="/data/data/com.termux/files/usr/var"

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

ZWAVE_INSTALL_DIR="/root/.local/share/pnpm/global/5/node_modules/zwave-js-ui"
ZWAVE_PORT="8091"
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
    
    load_mqtt_conf
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT_CONFIG" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload" 2>/dev/null || true
    echo "[$(date '+%F %T')] [MQTT] $topic -> $payload" >> "$LOG_FILE"
}

get_zwave_pid() {
    local port_pid=$(netstat -tnlp 2>/dev/null | grep ":$ZWAVE_PORT " | awk '{print $7}' | cut -d'/' -f1 | head -n1)
    
    if [ -n "$port_pid" ] && [ "$port_pid" != "-" ]; then
        local cwd=$(ls -l /proc/$port_pid/cwd 2>/dev/null | grep -o 'zwave-js-ui' || true)
        if [ -n "$cwd" ]; then
            echo "$port_pid"
            return 0
        fi
    fi
    return 1
}

get_current_version() {
    proot-distro login "$PROOT_DISTRO" -- bash -c "
        export SHELL=/data/data/com.termux/files/usr/bin/bash
        export PNPM_HOME=\"/root/.local/share/pnpm\"
        export PATH=\"\$PNPM_HOME:\$PATH\"
        source ~/.bashrc 2>/dev/null || true
        
        if [ -f '$ZWAVE_INSTALL_DIR/package.json' ]; then
            grep -m1 '\"version\"' '$ZWAVE_INSTALL_DIR/package.json' | cut -d'\"' -f4
        elif command -v zwave-js-ui >/dev/null 2>&1; then
            zwave-js-ui --version 2>/dev/null | head -n1 || echo 'unknown'
        else
            echo 'unknown'
        fi
    " 2>/dev/null || echo "unknown"
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

log "开始 zwave-js-ui 安装流程"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"starting installation process\",\"timestamp\":$(date +%s)}"

# -----------------------------------------------------------------------------
# 读取服务依赖配置
# -----------------------------------------------------------------------------
log "读取服务依赖配置"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"reading service dependencies from serviceupdate.json\",\"timestamp\":$(date +%s)}"

if [ ! -f "$SERVICEUPDATE_FILE" ]; then
    log "serviceupdate.json 不存在，使用默认依赖"
    DEPENDENCIES='["nodejs","git","make","g++","gcc","libsystemd-dev"]'
else
    DEPENDENCIES=$(jq -c ".services[] | select(.id==\"$SERVICE_ID\") | .install_dependencies // [\"nodejs\",\"git\",\"make\",\"g++\",\"gcc\",\"libsystemd-dev\"]" "$SERVICEUPDATE_FILE" 2>/dev/null || echo '["nodejs","git","make","g++","gcc","libsystemd-dev"]')
fi

# 转换为 bash 数组
DEPS_ARRAY=($(echo "$DEPENDENCIES" | jq -r '.[]' 2>/dev/null || echo "nodejs git make g++ gcc libsystemd-dev"))

log "安装系统依赖: ${DEPS_ARRAY[*]}"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"installing required dependencies\",\"dependencies\":$DEPENDENCIES,\"timestamp\":$(date +%s)}"

# -----------------------------------------------------------------------------
# 安装系统依赖
# -----------------------------------------------------------------------------
log "在 proot 容器中安装系统依赖"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"installing system dependencies\",\"timestamp\":$(date +%s)}"

if ! proot-distro login "$PROOT_DISTRO" -- bash -c "
    # 安装 Node.js 20
    if ! command -v node >/dev/null 2>&1; then
        echo '安装 Nodejs...'
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
        apt-get install -y nodejs
    else
        echo \"Nodejs 已安装: \$(node --version)\"
    fi
    
    # 安装其他依赖
    apt-get update
    apt-get install -y ${DEPS_ARRAY[*]}
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
    if ! command -v pnpm >/dev/null 2>&1; then
        echo '安装 pnpm...'
        npm install -g pnpm@10.11.0
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
# 初始化 pnpm 环境
# -----------------------------------------------------------------------------
log "初始化 pnpm 环境"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"initializing pnpm environment\",\"timestamp\":$(date +%s)}"

if ! proot-distro login "$PROOT_DISTRO" -- bash -c "
    export SHELL=/data/data/com.termux/files/usr/bin/bash
    
    # 强制重新设置 pnpm 环境
    pnpm setup --force || true
    
    # 手动设置环境变量
    export PNPM_HOME=\"/root/.local/share/pnpm\"
    export PATH=\"\$PNPM_HOME:\$PATH\"
    
    # 创建必要的目录
    mkdir -p \"\$PNPM_HOME\"
    
    # 更新 .bashrc
    if ! grep -q 'PNPM_HOME' ~/.bashrc; then
        echo 'export PNPM_HOME=\"/root/.local/share/pnpm\"' >> ~/.bashrc
        echo 'export PATH=\"\$PNPM_HOME:\$PATH\"' >> ~/.bashrc
    fi
    
    # 重新加载环境
    source ~/.bashrc 2>/dev/null || true
"; then
    log "pnpm 环境初始化失败"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"pnpm environment initialization failed\",\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

# -----------------------------------------------------------------------------
# 全局安装 Z-Wave JS UI
# -----------------------------------------------------------------------------
log "全局安装 zwave-js-ui"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"installing zwave-js-ui globally\",\"timestamp\":$(date +%s)}"

if ! proot-distro login "$PROOT_DISTRO" -- bash -c "
    export SHELL=/data/data/com.termux/files/usr/bin/bash
    export PNPM_HOME=\"/root/.local/share/pnpm\"
    export PATH=\"\$PNPM_HOME:\$PATH\"
    
    # 重新加载环境
    source ~/.bashrc 2>/dev/null || true
    
    # 验证 pnpm 可用性
    which pnpm || exit 1
    
    # 全局安装 zwave-js-ui
    pnpm add -g zwave-js-ui
"; then
    log "zwave-js-ui 安装失败"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"zwave-js-ui installation failed\",\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

# 获取安装的版本
VERSION_STR=$(get_current_version)
log "zwave-js-ui 安装成功，版本: $VERSION_STR"

# -----------------------------------------------------------------------------
# 注册 isgservicemonitor 服务
# -----------------------------------------------------------------------------
log "注册 isgservicemonitor 服务"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"registering service monitor\",\"timestamp\":$(date +%s)}"

# 创建 run 文件
cat > "$RUN_FILE" << EOF
#!/data/data/com.termux/files/usr/bin/sh
# Z-Wave JS UI 服务启动脚本，由 isgservicemonitor 管理
cd "$ZWAVE_INSTALL_DIR"
exec proot-distro login "$PROOT_DISTRO" -- bash -c "
    export SHELL=/data/data/com.termux/files/usr/bin/bash
    export PNPM_HOME=/root/.local/share/pnpm
    export PATH=\$PNPM_HOME:\$PATH
    source ~/.bashrc 2>/dev/null || true
    cd '$ZWAVE_INSTALL_DIR'
    exec zwave-js-ui
" 2>&1
EOF

chmod +x "$RUN_FILE"

# 创建 down 文件，禁用自动启动
touch "$DOWN_FILE"
log "已创建 run 和 down 文件"

# -----------------------------------------------------------------------------
# 创建存储目录
# -----------------------------------------------------------------------------
log "创建存储目录"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"creating store directory\",\"timestamp\":$(date +%s)}"

proot-distro login "$PROOT_DISTRO" -- mkdir -p "$ZWAVE_INSTALL_DIR/store"

# -----------------------------------------------------------------------------
# 生成初始配置
# -----------------------------------------------------------------------------
log "生成初始配置"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"generating initial configuration\",\"timestamp\":$(date +%s)}"

bash "$SERVICE_DIR/restore.sh"

# -----------------------------------------------------------------------------
# 启动服务测试
# -----------------------------------------------------------------------------
log "启动服务进行测试"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"starting service for testing\",\"timestamp\":$(date +%s)}"

# 启动服务
if [ -e "$SERVICE_CONTROL_DIR/supervise/control" ]; then
    echo u > "$SERVICE_CONTROL_DIR/supervise/control"
    rm -f "$DOWN_FILE"  # 移除 down 文件以启用服务
else
    log "控制文件不存在，直接启动 zwave-js-ui 进行测试"
    # 在后台启动进程进行测试
    proot-distro login "$PROOT_DISTRO" -- bash -c "
        export SHELL=/data/data/com.termux/files/usr/bin/bash
        export PNPM_HOME=/root/.local/share/pnpm
        export PATH=\$PNPM_HOME:\$PATH
        source ~/.bashrc 2>/dev/null || true
        cd '$ZWAVE_INSTALL_DIR'
        nohup zwave-js-ui > /dev/null 2>&1 &
    " || true
fi

# -----------------------------------------------------------------------------
# 等待服务启动并验证
# -----------------------------------------------------------------------------
log "等待服务启动"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"waiting for service ready\",\"timestamp\":$(date +%s)}"

WAITED=0
while [ "$WAITED" -lt "$MAX_WAIT" ]; do
    if get_zwave_pid > /dev/null 2>&1; then
        log "zwave-js-ui 在 ${WAITED}s 后启动成功"
        break
    fi
    sleep "$INTERVAL"
    WAITED=$((WAITED + INTERVAL))
done

if [ "$WAITED" -ge "$MAX_WAIT" ]; then
    log "超时: zwave-js-ui 在 ${MAX_WAIT}s 后仍未启动"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"service start timeout after installation\",\"timeout\":$MAX_WAIT,\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "$VERSION_STR"
    exit 1
fi

# -----------------------------------------------------------------------------
# 验证端口监听
# -----------------------------------------------------------------------------
log "验证端口监听"
sleep 3

if ! timeout 5 nc -z 127.0.0.1 "$ZWAVE_PORT" 2>/dev/null; then
    log "警告: zwave-js-ui 未监听在端口 $ZWAVE_PORT"
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
    ZWAVE_PID=$(get_zwave_pid || echo "")
    if [ -n "$ZWAVE_PID" ]; then
        kill "$ZWAVE_PID" 2>/dev/null || true
        log "已停止测试 zwave-js-ui 进程 $ZWAVE_PID"
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

log "zwave-js-ui 安装完成，耗时 ${DURATION}s"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"installed\",\"version\":\"$VERSION_STR\",\"duration\":$DURATION,\"timestamp\":$END_TIME}"

log "安装摘要:"
log "  - 版本: $VERSION_STR"
log "  - 主应用: ✅ 安装成功"
log "  - 安装路径: $ZWAVE_INSTALL_DIR"
log "  - 服务控制: $SERVICE_CONTROL_DIR"
log "  - Web端口: $ZWAVE_PORT"

exit 0
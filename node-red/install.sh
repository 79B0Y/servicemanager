#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Node-RED 安装脚本
# 版本: v1.0.0
# 功能: 在 proot Ubuntu 环境中安装 Node-RED
# =============================================================================

set -euo pipefail

# 加载统一路径定义
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common_paths.sh" || {
    echo "Error: Cannot load common paths"
    exit 1
}

# 设置脚本特定的日志文件
LOG_FILE="$LOG_FILE_INSTALL"

# 确保必要目录存在
ensure_directories

START_TIME=$(date +%s)

log "starting node-red installation process"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"starting installation process\",\"timestamp\":$(date +%s)}"

# -----------------------------------------------------------------------------
# 读取服务依赖配置
# -----------------------------------------------------------------------------
log "reading service dependencies from serviceupdate.json"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"reading service dependencies from serviceupdate.json\",\"timestamp\":$(date +%s)}"

if [ ! -f "$SERVICEUPDATE_FILE" ]; then
    log "serviceupdate.json not found, using default dependencies"
    DEPENDENCIES='["nodejs","npm"]'
else
    DEPENDENCIES=$(jq -c ".services[] | select(.id==\"$SERVICE_ID\") | .install_dependencies // [\"nodejs\",\"npm\"]" "$SERVICEUPDATE_FILE" 2>/dev/null || echo '["nodejs","npm"]')
fi

# 转换为 bash 数组
DEPS_ARRAY=($(echo "$DEPENDENCIES" | jq -r '.[]' 2>/dev/null || echo "nodejs npm"))

log "installing required dependencies: ${DEPS_ARRAY[*]}"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"installing required dependencies\",\"dependencies\":$DEPENDENCIES,\"timestamp\":$(date +%s)}"

# -----------------------------------------------------------------------------
# 安装系统依赖
# -----------------------------------------------------------------------------
log "installing system dependencies in proot container"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"installing system dependencies\",\"timestamp\":$(date +%s)}"

if ! proot-distro login "$PROOT_DISTRO" -- bash -c "
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get update
    apt-get install -y ${DEPS_ARRAY[*]}
"; then
    log "failed to install system dependencies"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"dependency installation failed\",\"dependencies\":$DEPENDENCIES,\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

# -----------------------------------------------------------------------------
# 安装 pnpm
# -----------------------------------------------------------------------------
log "installing pnpm package manager"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"installing pnpm package manager\",\"timestamp\":$(date +%s)}"

if ! proot-distro login "$PROOT_DISTRO" -- npm install -g pnpm; then
    log "failed to install pnpm"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"pnpm installation failed\",\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

# -----------------------------------------------------------------------------
# 获取目标版本
# -----------------------------------------------------------------------------
TARGET_VERSION="${TARGET_VERSION:-$(get_latest_version)}"
if [ "$TARGET_VERSION" = "unknown" ]; then
    TARGET_VERSION="4.0.9"  # 默认版本
fi

log "installing node-red version: $TARGET_VERSION"

# -----------------------------------------------------------------------------
# 安装 Node-RED
# -----------------------------------------------------------------------------
log "installing node-red via pnpm"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"installing node-red\",\"version\":\"$TARGET_VERSION\",\"timestamp\":$(date +%s)}"

if ! proot-distro login "$PROOT_DISTRO" -- pnpm add -g "node-red@$TARGET_VERSION"; then
    log "failed to install node-red"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"node-red installation failed\",\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

# 获取安装的版本
VERSION_STR=$(get_current_version)
log "node-red version: $VERSION_STR"

# -----------------------------------------------------------------------------
# 创建 Node-RED 服务运行脚本
# -----------------------------------------------------------------------------
log "creating node-red service run script"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"creating service run script\",\"timestamp\":$(date +%s)}"

cat > "$RUN_FILE" << 'EOF'
#!/data/data/com.termux/files/usr/bin/sh
exec proot-distro login ubuntu -- bash -c "
export NODE_RED_HOME=/root/.node-red
mkdir -p \$NODE_RED_HOME
cd \$NODE_RED_HOME
exec /root/.pnpm-global/bin/node-red
" 2>&1
EOF

chmod +x "$RUN_FILE"
log "created run script at $RUN_FILE"

# -----------------------------------------------------------------------------
# 初始化 Node-RED 目录和配置
# -----------------------------------------------------------------------------
log "initializing node-red configuration"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"initializing configuration\",\"timestamp\":$(date +%s)}"

proot-distro login "$PROOT_DISTRO" -- bash -c "
export NODE_RED_HOME=/root/.node-red
mkdir -p \$NODE_RED_HOME
cd \$NODE_RED_HOME
# 创建基本的 flows.json 文件
echo '[]' > flows.json
# 创建基本的 settings.js（如果不存在）
if [ ! -f settings.js ]; then
    cat > settings.js << 'SETTINGS_EOF'
module.exports = {
    uiPort: process.env.PORT || 1880,
    uiHost: \"0.0.0.0\",
    httpAdminRoot: false,
    httpNodeRoot: \"/\",
    functionGlobalContext: {},
    exportGlobalContextKeys: false,
    logging: {
        console: {
            level: \"info\",
            metrics: false,
            audit: false
        }
    },
    editorTheme: {
        projects: {
            enabled: false
        }
    }
}
SETTINGS_EOF
fi
"

# -----------------------------------------------------------------------------
# 创建 down 文件（默认禁用自启动）
# -----------------------------------------------------------------------------
touch "$DOWN_FILE"
log "created down file to disable auto-start by default"

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

echo "$VERSION_STR"

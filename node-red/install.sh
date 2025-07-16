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
    source ~/.bashrc
    apt update && apt upgrade -y
    apt install -y ${DEPS_ARRAY[*]}
"; then
    log "failed to install system dependencies"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"dependency installation failed\",\"dependencies\":$DEPENDENCIES,\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

# -----------------------------------------------------------------------------
# 检查 Node.js 和 npm 版本
# -----------------------------------------------------------------------------
log "checking node.js and npm versions"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"checking node.js and npm versions\",\"timestamp\":$(date +%s)}"

NODE_VERSION=$(proot-distro login "$PROOT_DISTRO" -- bash -c "source ~/.bashrc && node -v" 2>/dev/null || echo "not installed")
NPM_VERSION=$(proot-distro login "$PROOT_DISTRO" -- bash -c "source ~/.bashrc && npm -v" 2>/dev/null || echo "not installed")

log "node.js version: $NODE_VERSION"
log "npm version: $NPM_VERSION"

if [[ "$NODE_VERSION" == "not installed" ]] || [[ "$NPM_VERSION" == "not installed" ]]; then
    log "node.js or npm not properly installed"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"node.js or npm not properly installed\",\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

# -----------------------------------------------------------------------------
# 安装 pnpm
# -----------------------------------------------------------------------------
log "installing pnpm package manager"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"installing pnpm package manager\",\"timestamp\":$(date +%s)}"

if ! proot-distro login "$PROOT_DISTRO" -- bash -c "source ~/.bashrc && npm install -g pnpm"; then
    log "failed to install pnpm"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"pnpm installation failed\",\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

# -----------------------------------------------------------------------------
# 获取目标版本
# -----------------------------------------------------------------------------
TARGET_VERSION=$(get_latest_version)
if [ "$TARGET_VERSION" = "unknown" ]; then
    TARGET_VERSION="4.0.9"  # 默认版本
    log "using default node-red version: $TARGET_VERSION"
else
    log "target node-red version: $TARGET_VERSION"
fi

# -----------------------------------------------------------------------------
# 创建安装目录并安装 Node-RED
# -----------------------------------------------------------------------------
log "creating installation directory and installing node-red"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"installing node-red application\",\"timestamp\":$(date +%s)}"

if ! proot-distro login "$PROOT_DISTRO" -- bash -c "
    source ~/.bashrc
    mkdir -p $NR_INSTALL_DIR
    cd $NR_INSTALL_DIR
    pnpm add node-red@$TARGET_VERSION
"; then
    log "failed to install node-red"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"node-red installation failed\",\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

# -----------------------------------------------------------------------------
# 生成 package.json
# -----------------------------------------------------------------------------
log "generating package.json for service management"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"generating package.json\",\"timestamp\":$(date +%s)}"

proot-distro login "$PROOT_DISTRO" -- bash -c "
cd $NR_INSTALL_DIR
cat > package.json << EOF
{
  \"scripts\": {
    \"start\": \"node-red\"
  },
  \"dependencies\": {
    \"node-red\": \"$TARGET_VERSION\"
  }
}
EOF
"

# 获取安装的版本
VERSION_STR=$(get_current_version)
log "node-red version: $VERSION_STR"

# -----------------------------------------------------------------------------
# 创建数据目录
# -----------------------------------------------------------------------------
log "creating node-red data directory"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"creating data directory\",\"timestamp\":$(date +%s)}"

proot-distro login "$PROOT_DISTRO" -- mkdir -p "$NR_DATA_DIR"

# -----------------------------------------------------------------------------
# 注册 servicemonitor 服务看护
# -----------------------------------------------------------------------------
log "registering service with isgservicemonitor"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"registering service monitor\",\"timestamp\":$(date +%s)}"

mkdir -p "$SERVICE_CONTROL_DIR"

cat > "$SERVICE_CONTROL_DIR/run" << EOF
#!/data/data/com.termux/files/usr/bin/sh
exec proot-distro login $PROOT_DISTRO << 'PROOT_EOF'
cd $NR_INSTALL_DIR
npm start
PROOT_EOF
2>&1
EOF

chmod +x "$SERVICE_CONTROL_DIR/run"

# 禁用自启动
touch "$DOWN_FILE"
log "service registered and auto-start disabled"

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

log "node-red installation completed successfully in ${DURATION}s"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"installed\",\"version\":\"$VERSION_STR\",\"duration\":$DURATION,\"timestamp\":$END_TIME}"

exit 0
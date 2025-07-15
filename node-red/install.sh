#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Node-RED 安装脚本
# 版本: v1.1.0
# 功能: 安装 Node-RED 服务和相关依赖
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
    DEPENDENCIES='["nodejs","npm","python3","python3-pip","build-essential","git"]'
else
    DEPENDENCIES=$(jq -c ".services[] | select(.id==\"$SERVICE_ID\") | .install_dependencies // [\"nodejs\",\"npm\",\"python3\",\"python3-pip\",\"build-essential\",\"git\"]" "$SERVICEUPDATE_FILE" 2>/dev/null || echo '["nodejs","npm","python3","python3-pip","build-essential","git"]')
fi

# 转换为 bash 数组
DEPS_ARRAY=($(echo "$DEPENDENCIES" | jq -r '.[]' 2>/dev/null || echo "nodejs npm python3 python3-pip build-essential git"))

log "installing required dependencies: ${DEPS_ARRAY[*]}"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"installing required dependencies\",\"dependencies\":$DEPENDENCIES,\"timestamp\":$(date +%s)}"

# -----------------------------------------------------------------------------
# 安装 Termux 端的 node-red 包
# -----------------------------------------------------------------------------
log "installing node-red package for termux"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"downloading and installing node-red termux package\",\"timestamp\":$(date +%s)}"

# 下载并安装 Termux node-red 包
cd /tmp
if ! wget --no-check-certificate https://eucfg.linklinkiot.com/isg/node-red-2.2.1-3-g88e159e-88e159e-termux-arm.deb -O node-red.deb; then
    log "failed to download node-red termux package"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"failed to download node-red termux package\",\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

if ! dpkg -i node-red.deb; then
    log "failed to install node-red termux package"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"failed to install node-red termux package\",\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

rm -f node-red.deb
log "node-red termux package installed successfully"

# -----------------------------------------------------------------------------
# 安装系统依赖
# -----------------------------------------------------------------------------
log "installing system dependencies in proot container"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"installing system dependencies\",\"timestamp\":$(date +%s)}"

if ! proot-distro login "$PROOT_DISTRO" -- bash -c "
    apt-get update
    apt-get install -y ${DEPS_ARRAY[*]}
    # 安装 pnpm
    npm install -g pnpm@latest
"; then
    log "failed to install system dependencies"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"dependency installation failed\",\"dependencies\":$DEPENDENCIES,\"timestamp\":$(date +%s)}"
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
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"installing node-red version $TARGET_VERSION\",\"timestamp\":$(date +%s)}"

# -----------------------------------------------------------------------------
# 安装 Node-RED
# -----------------------------------------------------------------------------
log "installing node-red via pnpm in proot container"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"installing node-red application\",\"timestamp\":$(date +%s)}"

if ! proot-distro login "$PROOT_DISTRO" -- bash -c "
    pnpm add -g node-red@$TARGET_VERSION
"; then
    log "failed to install node-red"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"node-red installation failed\",\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

# 获取安装的版本
VERSION_STR=$(get_current_version)
log "node-red version: $VERSION_STR"

# -----------------------------------------------------------------------------
# 创建服务控制目录和脚本
# -----------------------------------------------------------------------------
log "creating service control directory and run script"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"creating service control files\",\"timestamp\":$(date +%s)}"

# 创建服务目录
mkdir -p "$SERVICE_CONTROL_DIR/supervise"

# 创建 run 脚本
cat > "$RUN_SCRIPT" << 'EOF'
#!/data/data/com.termux/files/usr/bin/sh
exec proot-distro login ubuntu -- bash -c "cd /root && /root/.pnpm-global/bin/node-red" 2>&1
EOF

chmod +x "$RUN_SCRIPT"

# 创建 down 文件（初始状态为停止）
touch "$DOWN_FILE"

log "service control files created successfully"

# -----------------------------------------------------------------------------
# 创建数据目录和初始配置
# -----------------------------------------------------------------------------
log "creating data directory and initial configuration"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"creating data directory and initial configuration\",\"timestamp\":$(date +%s)}"

proot-distro login "$PROOT_DISTRO" -- mkdir -p "$NODE_RED_DATA_DIR"

# 生成初始配置
bash "$SERVICE_DIR/restore.sh"

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

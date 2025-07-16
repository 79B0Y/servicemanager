#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Z-Wave JS UI 安装脚本
# 版本: v1.0.0
# 功能: 在 proot Ubuntu 环境中安装 Z-Wave JS UI
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

log "starting zwave-js-ui installation process"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"starting installation process\",\"timestamp\":$(date +%s)}"

# -----------------------------------------------------------------------------
# 读取服务依赖配置
# -----------------------------------------------------------------------------
log "reading service dependencies from serviceupdate.json"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"reading service dependencies from serviceupdate.json\",\"timestamp\":$(date +%s)}"

if [ ! -f "$SERVICEUPDATE_FILE" ]; then
    log "serviceupdate.json not found, using default dependencies"
    DEPENDENCIES='["nodejs","git","make","g++","gcc","libsystemd-dev"]'
else
    DEPENDENCIES=$(jq -c ".services[] | select(.id==\"$SERVICE_ID\") | .install_dependencies // [\"nodejs\",\"git\",\"make\",\"g++\",\"gcc\",\"libsystemd-dev\"]" "$SERVICEUPDATE_FILE" 2>/dev/null || echo '["nodejs","git","make","g++","gcc","libsystemd-dev"]')
fi

# 转换为 bash 数组
DEPS_ARRAY=($(echo "$DEPENDENCIES" | jq -r '.[]' 2>/dev/null || echo "nodejs git make g++ gcc libsystemd-dev"))

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

if ! proot-distro login "$PROOT_DISTRO" -- npm install -g pnpm@10.11.0; then
    log "failed to install pnpm"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"pnpm installation failed\",\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

# -----------------------------------------------------------------------------
# 初始化 pnpm 环境
# -----------------------------------------------------------------------------
log "initializing pnpm environment"
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
    echo 'export PNPM_HOME=\"/root/.local/share/pnpm\"' >> ~/.bashrc
    echo 'export PATH=\"\$PNPM_HOME:\$PATH\"' >> ~/.bashrc
    
    # 重新加载环境
    source ~/.bashrc 2>/dev/null || true
"; then
    log "failed to initialize pnpm environment"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"pnpm environment initialization failed\",\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

# -----------------------------------------------------------------------------
# 全局安装 Z-Wave JS UI
# -----------------------------------------------------------------------------
log "installing zwave-js-ui globally via pnpm"
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
    log "failed to install zwave-js-ui"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"zwave-js-ui installation failed\",\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

# 获取安装的版本
VERSION_STR=$(get_current_version)
log "zwave-js-ui version: $VERSION_STR"

# -----------------------------------------------------------------------------
# 创建存储目录
# -----------------------------------------------------------------------------
log "creating store directory"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"creating store directory\",\"timestamp\":$(date +%s)}"

proot-distro login "$PROOT_DISTRO" -- mkdir -p "$ZWAVE_STORE_DIR"

# -----------------------------------------------------------------------------
# 生成初始配置
# -----------------------------------------------------------------------------
log "generating initial configuration"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"generating initial configuration\",\"timestamp\":$(date +%s)}"

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

log "zwave-js-ui installation completed successfully in ${DURATION}s"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"installed\",\"version\":\"$VERSION_STR\",\"duration\":$DURATION,\"timestamp\":$END_TIME}"

exit 0
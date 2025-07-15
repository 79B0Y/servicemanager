#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Node-RED 更新脚本
# 版本: v1.1.0
# 功能: 升级 Node-RED 到最新版本
# =============================================================================

set -euo pipefail

# 加载统一路径定义
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common_paths.sh" || {
    echo "Error: Cannot load common paths"
    exit 1
}

# 设置脚本特定的日志文件
LOG_FILE="$LOG_FILE_UPDATE"

# 确保必要目录存在
ensure_directories

START_TIME=$(date +%s)

# -----------------------------------------------------------------------------
# 获取当前版本
# -----------------------------------------------------------------------------
CURRENT_VERSION=$(get_current_version)

log "starting node-red update from $CURRENT_VERSION"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"starting update process\",\"timestamp\":$(date +%s)}"

# -----------------------------------------------------------------------------
# 读取升级依赖配置
# -----------------------------------------------------------------------------
log "reading upgrade dependencies from serviceupdate.json"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"reading upgrade dependencies from serviceupdate.json\",\"timestamp\":$(date +%s)}"

if [ ! -f "$SERVICEUPDATE_FILE" ]; then
    log "serviceupdate.json not found, using default upgrade dependencies"
    UPGRADE_DEPS='[]'
else
    UPGRADE_DEPS=$(get_upgrade_dependencies)
fi

# 获取目标版本
TARGET_VERSION="${TARGET_VERSION:-$(get_latest_version)}"
if [ "$TARGET_VERSION" = "unknown" ]; then
    TARGET_VERSION="latest"  # 默认使用最新版本
fi

log "updating to version: $TARGET_VERSION"

# 转换为 bash 数组
DEPS_ARRAY=()
if [ "$UPGRADE_DEPS" != "[]" ] && [ "$UPGRADE_DEPS" != "null" ]; then
    while IFS= read -r dep; do
        DEPS_ARRAY+=("$dep")
    done < <(echo "$UPGRADE_DEPS" | jq -r '.[]' 2>/dev/null || true)
fi

if [ ${#DEPS_ARRAY[@]} -gt 0 ]; then
    log "installing upgrade dependencies: ${DEPS_ARRAY[*]}"
    mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"installing upgrade dependencies\",\"dependencies\":$UPGRADE_DEPS,\"timestamp\":$(date +%s)}"
    
    # 安装升级依赖
    for dep in "${DEPS_ARRAY[@]}"; do
        log "installing upgrade dependency: $dep"
        # 这里可以根据具体需求实现依赖安装逻辑
        # 例如：proot-distro login "$PROOT_DISTRO" -- npm install -g "$dep"
    done
else
    log "no upgrade dependencies specified"
fi

# -----------------------------------------------------------------------------
# 停止服务
# -----------------------------------------------------------------------------
log "stopping node-red before update"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"stopping service\",\"timestamp\":$(date +%s)}"

bash "$SERVICE_DIR/stop.sh"
sleep 5

# -----------------------------------------------------------------------------
# 执行升级（进入 proot 容器）
# -----------------------------------------------------------------------------
log "updating node-red"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"updating node-red application\",\"timestamp\":$(date +%s)}"

# 使用 pnpm 升级 Node-RED
UPDATE_CMD="pnpm up -g node-red"
if [ "$TARGET_VERSION" != "latest" ]; then
    UPDATE_CMD="pnpm up -g node-red@$TARGET_VERSION"
fi

if ! proot-distro login "$PROOT_DISTRO" -- bash -c "$UPDATE_CMD"; then
    log "node-red update failed"
    mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"node-red update failed\",\"current_version\":\"$CURRENT_VERSION\",\"timestamp\":$(date +%s)}"
    record_update_history "FAILED" "$CURRENT_VERSION" "unknown" "node-red update failed"
    exit 1
fi

# -----------------------------------------------------------------------------
# 版本校验
# -----------------------------------------------------------------------------
UPDATED_VERSION=$(get_current_version)

if [ "$UPDATED_VERSION" = "unknown" ]; then
    log "failed to get updated version"
    mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"failed to get updated version\",\"current_version\":\"$CURRENT_VERSION\",\"timestamp\":$(date +%s)}"
    record_update_history "FAILED" "$CURRENT_VERSION" "unknown" "failed to get updated version"
    exit 1
fi

log "updated to version: $UPDATED_VERSION"

# -----------------------------------------------------------------------------
# 重启服务并健康检查
# -----------------------------------------------------------------------------
log "starting service"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"starting service\",\"timestamp\":$(date +%s)}"

bash "$SERVICE_DIR/start.sh"

log "waiting for service ready"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"waiting for service ready\",\"timestamp\":$(date +%s)}"

MAX_WAIT=300
INTERVAL=5
WAITED=0

while [ "$WAITED" -lt "$MAX_WAIT" ]; do
    if bash "$SERVICE_DIR/status.sh" --quiet; then
        DURATION=$(( $(date +%s) - START_TIME ))
        log "service is running after ${WAITED}s"
        
        # 记录更新历史
        log "recording update history"
        mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"old_version\":\"$CURRENT_VERSION\",\"new_version\":\"$UPDATED_VERSION\",\"message\":\"recording update history\",\"timestamp\":$(date +%s)}"
        
        record_update_history "SUCCESS" "$CURRENT_VERSION" "$UPDATED_VERSION" ""
        
        mqtt_report "isg/update/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"success\",\"old_version\":\"$CURRENT_VERSION\",\"new_version\":\"$UPDATED_VERSION\",\"duration\":$DURATION,\"timestamp\":$(date +%s)}"
        
        # 更新版本文件
        echo "$UPDATED_VERSION" > "$VERSION_FILE"
        log "update completed: $CURRENT_VERSION → $UPDATED_VERSION"
        exit 0
    fi
    sleep "$INTERVAL"
    WAITED=$((WAITED + INTERVAL))
done

log "timeout: service not running after ${MAX_WAIT}s"
record_update_history "FAILED" "$CURRENT_VERSION" "$UPDATED_VERSION" "service start timeout"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"service start timeout after update\",\"old_version\":\"$CURRENT_VERSION\",\"new_version\":\"$UPDATED_VERSION\",\"timeout\":$MAX_WAIT,\"timestamp\":$(date +%s)}"
exit 1

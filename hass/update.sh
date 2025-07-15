#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Home Assistant 更新脚本
# 版本: v1.4.0
# 功能: 升级 Home Assistant 到指定版本
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
CURRENT_VERSION=$(get_current_ha_version)

# 检查TARGET_VERSION是否设置
if [ -z "${TARGET_VERSION:-}" ]; then
    TARGET_VERSION=$(get_latest_ha_version)
    if [ "$TARGET_VERSION" = "unknown" ]; then
        log "cannot determine target version"
        mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"TARGET_VERSION not set and unable to get latest version\",\"current_version\":\"$CURRENT_VERSION\",\"timestamp\":$(date +%s)}"
        exit 1
    fi
fi

log "starting Home Assistant update from $CURRENT_VERSION to $TARGET_VERSION"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"target_version\":\"$TARGET_VERSION\",\"message\":\"starting update process\",\"timestamp\":$(date +%s)}"

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

# 针对特定版本定义额外依赖
EXTRA_PIP_PKGS=""
case "$TARGET_VERSION" in
    2025.7.1) EXTRA_PIP_PKGS="click==8.1.7";;
    # 添加更多版本特定依赖
esac

# 转换为 bash 数组
DEPS_ARRAY=()
if [ "$UPGRADE_DEPS" != "[]" ] && [ "$UPGRADE_DEPS" != "null" ]; then
    while IFS= read -r dep; do
        DEPS_ARRAY+=("$dep")
    done < <(echo "$UPGRADE_DEPS" | jq -r '.[]' 2>/dev/null || true)
fi

if [ ${#DEPS_ARRAY[@]} -gt 0 ] || [ -n "$EXTRA_PIP_PKGS" ]; then
    ALL_DEPS="${DEPS_ARRAY[*]} $EXTRA_PIP_PKGS"
    log "installing upgrade dependencies: $ALL_DEPS"
    mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"installing upgrade dependencies\",\"dependencies\":\"$ALL_DEPS\",\"timestamp\":$(date +%s)}"
    
    # 在容器内安装升级依赖
    if ! proot-distro login "$PROOT_DISTRO" -- bash -c "
        source $HA_VENV_DIR/bin/activate
        pip install --upgrade pip
        [ -n \"$ALL_DEPS\" ] && pip install $ALL_DEPS
    "; then
        log "failed to install upgrade dependencies"
        mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"upgrade dependencies installation failed\",\"dependencies\":\"$ALL_DEPS\",\"current_version\":\"$CURRENT_VERSION\",\"timestamp\":$(date +%s)}"
        record_update_history "FAILED" "$CURRENT_VERSION" "$TARGET_VERSION" "upgrade dependencies installation failed"
        exit 1
    fi
else
    log "no upgrade dependencies specified"
fi

# -----------------------------------------------------------------------------
# 停止服务
# -----------------------------------------------------------------------------
log "stopping Home Assistant before update"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"stopping service\",\"timestamp\":$(date +%s)}"

bash "$SERVICE_DIR/stop.sh"
sleep 5

# -----------------------------------------------------------------------------
# 执行升级（进入 proot 容器）
# -----------------------------------------------------------------------------
log "updating Home Assistant to version $TARGET_VERSION"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"installing new version\",\"target_version\":\"$TARGET_VERSION\",\"timestamp\":$(date +%s)}"

if ! proot-distro login "$PROOT_DISTRO" -- bash -c "
    source $HA_VENV_DIR/bin/activate
    pip install --upgrade homeassistant==$TARGET_VERSION
"; then
    log "Home Assistant upgrade failed"
    mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"Home Assistant upgrade failed\",\"current_version\":\"$CURRENT_VERSION\",\"target_version\":\"$TARGET_VERSION\",\"timestamp\":$(date +%s)}"
    record_update_history "FAILED" "$CURRENT_VERSION" "$TARGET_VERSION" "pip install failed"
    exit 1
fi

# -----------------------------------------------------------------------------
# 版本校验
# -----------------------------------------------------------------------------
UPDATED_VERSION=$(get_current_ha_version)

if [ "$UPDATED_VERSION" = "unknown" ]; then
    log "failed to get updated version"
    mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"failed to get updated version\",\"current_version\":\"$CURRENT_VERSION\",\"timestamp\":$(date +%s)}"
    record_update_history "FAILED" "$CURRENT_VERSION" "$TARGET_VERSION" "failed to get updated version"
    exit 1
fi

if [ "$UPDATED_VERSION" != "$TARGET_VERSION" ]; then
    log "version mismatch: expected $TARGET_VERSION, got $UPDATED_VERSION"
    mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"version mismatch\",\"expected\":\"$TARGET_VERSION\",\"actual\":\"$UPDATED_VERSION\",\"timestamp\":$(date +%s)}"
    record_update_history "FAILED" "$CURRENT_VERSION" "$UPDATED_VERSION" "version mismatch"
    exit 1
fi

log "updated to version: $UPDATED_VERSION"

# -----------------------------------------------------------------------------
# 重启服务并健康检查
# -----------------------------------------------------------------------------
log "starting service"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"starting service\",\"new_version\":\"$UPDATED_VERSION\",\"timestamp\":$(date +%s)}"

bash "$SERVICE_DIR/start.sh"

log "waiting for service ready"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"waiting for service ready\",\"new_version\":\"$UPDATED_VERSION\",\"timestamp\":$(date +%s)}"

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

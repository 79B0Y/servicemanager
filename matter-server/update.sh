#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Matter Server 更新脚本
# 版本: v1.0.0
# 功能: 升级 Matter Server 到最新版本
# =============================================================================

set -euo pipefail

# =============================================================================
# 路径和配置定义
# =============================================================================
SERVICE_ID="matter-server"
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"

# 基础目录
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"
CONFIG_FILE="$BASE_DIR/configuration.yaml"
SERVICEUPDATE_FILE="$BASE_DIR/serviceupdate.json"

# 日志和状态文件
LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/update.log"
VERSION_FILE="$SERVICE_DIR/VERSION"
UPDATE_HISTORY_FILE="$SERVICE_DIR/.update_history"

# 容器内路径
MATTER_INSTALL_DIR="/opt/matter-server"
MATTER_ENV_DIR="$MATTER_INSTALL_DIR/venv"
MATTER_SDK_DIR="$MATTER_INSTALL_DIR/connectedhomeip"

# Matter 特定配置
MATTER_SDK_VERSION="${MATTER_SDK_VERSION:-v2023-09-28}"

# =============================================================================
# 工具函数
# =============================================================================
ensure_directories() {
    mkdir -p "$LOG_DIR"
    touch "$UPDATE_HISTORY_FILE" 2>/dev/null || true
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
    proot-distro login "$PROOT_DISTRO" -- bash -c "
        source $MATTER_ENV_DIR/bin/activate 2>/dev/null || exit 1
        python -c 'import matter_server; print(matter_server.__version__)' 2>/dev/null || echo 'unknown'
    " 2>/dev/null || echo "unknown"
}

get_upgrade_dependencies() {
    if [[ -f "$SERVICEUPDATE_FILE" ]]; then
        jq -c ".services[] | select(.id==\"$SERVICE_ID\") | .upgrade_dependencies" "$SERVICEUPDATE_FILE" 2>/dev/null || echo "[]"
    else
        echo "[]"
    fi
}

record_update_history() {
    local status="$1"
    local old_version="$2"
    local new_version="$3"
    local reason="$4"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    if [ "$status" = "SUCCESS" ]; then
        echo "$timestamp SUCCESS $old_version -> $new_version" >> "$UPDATE_HISTORY_FILE"
    else
        echo "$timestamp FAILED $old_version -> $new_version ($reason)" >> "$UPDATE_HISTORY_FILE"
    fi
}

# =============================================================================
# 主程序开始
# =============================================================================
ensure_directories
START_TIME=$(date +%s)

# -----------------------------------------------------------------------------
# 获取当前版本
# -----------------------------------------------------------------------------
CURRENT_VERSION=$(get_current_version)

log "starting matter-server update from $CURRENT_VERSION"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"starting update process\",\"timestamp\":$(date +%s)}"

# -----------------------------------------------------------------------------
# 读取升级依赖配置
# -----------------------------------------------------------------------------
log "reading upgrade dependencies from serviceupdate.json"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"reading upgrade dependencies from serviceupdate.json\",\"timestamp\":$(date +%s)}"

UPGRADE_DEPS=$(get_upgrade_dependencies)

# 转换为 bash 数组
DEPS_ARRAY=()
if [ "$UPGRADE_DEPS" != "[]" ] && [ "$UPGRADE_DEPS" != "null" ] && [ -n "$UPGRADE_DEPS" ]; then
    while IFS= read -r dep; do
        [[ -n "$dep" ]] && DEPS_ARRAY+=("$dep")
    done < <(echo "$UPGRADE_DEPS" | jq -r '.[]' 2>/dev/null || true)
fi

if [ ${#DEPS_ARRAY[@]} -gt 0 ]; then
    log "installing upgrade dependencies: ${DEPS_ARRAY[*]}"
    mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"installing upgrade dependencies\",\"dependencies\":$UPGRADE_DEPS,\"timestamp\":$(date +%s)}"
    
    # 安装升级依赖
    for dep in "${DEPS_ARRAY[@]}"; do
        log "installing upgrade dependency: $dep"
        proot-distro login "$PROOT_DISTRO" -- bash -c "
            cd $MATTER_INSTALL_DIR
            source venv/bin/activate
            pip install '$dep'
        " || log "failed to install dependency: $dep"
    done
else
    log "no upgrade dependencies specified"
fi

# -----------------------------------------------------------------------------
# 停止服务
# -----------------------------------------------------------------------------
log "stopping matter-server before update"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"stopping service\",\"timestamp\":$(date +%s)}"

bash "$SERVICE_DIR/stop.sh"
sleep 5

# -----------------------------------------------------------------------------
# 更新 ConnectedHomeIP SDK
# -----------------------------------------------------------------------------
log "updating ConnectedHomeIP SDK"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"updating ConnectedHomeIP SDK\",\"timestamp\":$(date +%s)}"

if ! proot-distro login "$PROOT_DISTRO" -- bash -c "
    cd $MATTER_SDK_DIR
    
    # 配置 git 以处理网络问题
    git config --global http.postBuffer 524288000
    git config --global http.lowSpeedLimit 1000
    git config --global http.lowSpeedTime 300
    
    # 获取最新代码
    git fetch --depth 1 origin || {
        log 'git fetch failed, trying to reset'
        git reset --hard HEAD
        git clean -fd
        git fetch --depth 1 origin
    }
    
    # 尝试切换到指定版本
    if git fetch --depth 1 origin tag $MATTER_SDK_VERSION 2>/dev/null; then
        git checkout $MATTER_SDK_VERSION
    else
        git checkout origin/main || git checkout main
        log 'using main branch (SDK version tag not found)'
    fi
    
    # 更新子模块（仅必要的）
    git submodule update --init --depth 1 third_party/nanopb/repo || true
    git submodule update --init --depth 1 third_party/nlassert/repo || true
    git submodule update --init --depth 1 third_party/nlio/repo || true
"; then
    log "ConnectedHomeIP SDK update failed"
    mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"ConnectedHomeIP SDK update failed\",\"current_version\":\"$CURRENT_VERSION\",\"timestamp\":$(date +%s)}"
    record_update_history "FAILED" "$CURRENT_VERSION" "unknown" "SDK update failed"
    exit 1
fi

# -----------------------------------------------------------------------------
# 重新编译 SDK
# -----------------------------------------------------------------------------
log "rebuilding ConnectedHomeIP SDK"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"rebuilding SDK\",\"timestamp\":$(date +%s)}"

if ! proot-distro login "$PROOT_DISTRO" -- bash -c "
    cd $MATTER_SDK_DIR
    source $MATTER_ENV_DIR/bin/activate
    export PATH=\$PWD/depot_tools:\$PATH
    
    # 清理旧的构建文件
    rm -rf out/python
    
    # 检查是否有 GN 可用
    if command -v gn >/dev/null 2>&1; then
        # 重新生成构建文件
        mkdir -p out/python
        echo 'is_debug = false
is_component_build = false
chip_build_tests = false
chip_build_tools = false
chip_crypto = \"openssl\"' > out/python/args.gn
        
        gn gen out/python || {
            log 'gn gen failed during update'
            exit 0  # 不强制失败
        }
        
        # 编译
        ninja -C out/python chip-controller-py || {
            log 'ninja build failed during update'
            exit 0  # 不强制失败
        }
        
        # 重新安装 Python 包
        pip uninstall -y chip-python || true
        if [ -f out/python/python_dist/chip_python-*.whl ]; then
            pip install ./out/python/python_dist/chip_python-*.whl
        fi
    else
        log 'gn not available, skipping SDK rebuild'
    fi
"; then
    log "SDK rebuild failed, continuing with python-matter-server update"
    # 不强制退出，继续后续步骤
fi

# -----------------------------------------------------------------------------
# 更新 python-matter-server
# -----------------------------------------------------------------------------
log "updating python-matter-server"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"updating python-matter-server\",\"timestamp\":$(date +%s)}"

if ! proot-distro login "$PROOT_DISTRO" -- bash -c "
    cd $MATTER_INSTALL_DIR
    source venv/bin/activate
    pip install --upgrade python-matter-server
"; then
    log "python-matter-server update failed"
    mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"python-matter-server update failed\",\"current_version\":\"$CURRENT_VERSION\",\"timestamp\":$(date +%s)}"
    record_update_history "FAILED" "$CURRENT_VERSION" "unknown" "python-matter-server update failed"
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

#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Node-RED 更新脚本
# 版本: v1.0.0
# 功能: 升级 Node-RED 到最新版本
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# 路径和变量定义
# -----------------------------------------------------------------------------
SERVICE_ID="node-red"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"

CONFIG_FILE="$BASE_DIR/configuration.yaml"
SERVICEUPDATE_FILE="$BASE_DIR/serviceupdate.json"
VERSION_FILE="$SERVICE_DIR/VERSION"

LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/update.log"
BACKUP_DIR="/sdcard/isgbackup/$SERVICE_ID"
UPDATE_HISTORY_FILE="$BACKUP_DIR/.update_history"

PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
NR_INSTALL_DIR="/opt/node-red"
NR_PORT="1880"

# -----------------------------------------------------------------------------
# 辅助函数
# -----------------------------------------------------------------------------
ensure_directories() {
    mkdir -p "$LOG_DIR"
    mkdir -p "$BACKUP_DIR"
    touch "$UPDATE_HISTORY_FILE" 2>/dev/null || true
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

get_nr_pid() {
    local port_pid=$(netstat -tnlp 2>/dev/null | grep ":$NR_PORT " | awk '{print $7}' | cut -d'/' -f1 | head -n1)
    
    if [ -n "$port_pid" ] && [ "$port_pid" != "-" ]; then
        local cwd=$(ls -l /proc/$port_pid/cwd 2>/dev/null | grep -o 'node-red\|\.node-red' || true)
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
    proot-distro login "$PROOT_DISTRO" -- bash -c "cd $NR_INSTALL_DIR && cat package.json | grep '\"node-red\"' | grep -v 'start' | sed -E 's/.*\"node-red\": *\"([^\"]+)\".*/\1/'" 2>/dev/null || echo "unknown"
}

get_latest_version() {
    jq -r ".services[] | select(.id==\"$SERVICE_ID\") | .latest_service_version" "$SERVICEUPDATE_FILE" 2>/dev/null || echo "unknown"
}

get_upgrade_dependencies() {
    jq -c ".services[] | select(.id==\"$SERVICE_ID\") | .upgrade_dependencies" "$SERVICEUPDATE_FILE" 2>/dev/null || echo "[]"
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

START_TIME=$(date +%s)

# -----------------------------------------------------------------------------
# 主更新流程
# -----------------------------------------------------------------------------
ensure_directories

# -----------------------------------------------------------------------------
# 获取当前版本
# -----------------------------------------------------------------------------
CURRENT_VERSION=$(get_current_version)

log "开始更新 Node-RED，当前版本: $CURRENT_VERSION"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"starting update process\",\"timestamp\":$(date +%s)}"

# -----------------------------------------------------------------------------
# 读取升级依赖配置
# -----------------------------------------------------------------------------
log "读取升级依赖配置"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"reading upgrade dependencies from serviceupdate.json\",\"timestamp\":$(date +%s)}"

if [ ! -f "$SERVICEUPDATE_FILE" ]; then
    log "serviceupdate.json 不存在，使用默认升级依赖"
    UPGRADE_DEPS='[]'
    TARGET_VERSION=$(get_latest_version)
else
    UPGRADE_DEPS=$(get_upgrade_dependencies)
    TARGET_VERSION=$(get_latest_version)
fi

# 如果没有指定目标版本，使用默认值
if [ "$TARGET_VERSION" = "unknown" ]; then
    TARGET_VERSION="4.0.9"
    log "使用默认目标版本: $TARGET_VERSION"
else
    log "目标版本: $TARGET_VERSION"
fi

# 转换为 bash 数组
DEPS_ARRAY=()
if [ "$UPGRADE_DEPS" != "[]" ] && [ "$UPGRADE_DEPS" != "null" ]; then
    while IFS= read -r dep; do
        DEPS_ARRAY+=("$dep")
    done < <(echo "$UPGRADE_DEPS" | jq -r '.[]' 2>/dev/null || true)
fi

if [ ${#DEPS_ARRAY[@]} -gt 0 ]; then
    log "安装升级依赖: ${DEPS_ARRAY[*]}"
    mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"installing upgrade dependencies\",\"dependencies\":$UPGRADE_DEPS,\"timestamp\":$(date +%s)}"
    
    # 安装升级依赖
    for dep in "${DEPS_ARRAY[@]}"; do
        log "安装升级依赖: $dep"
        if ! proot-distro login "$PROOT_DISTRO" -- bash -c "source ~/.bashrc && npm install -g '$dep'"; then
            log "升级依赖 $dep 安装失败"
            mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"upgrade dependencies installation failed\",\"dependencies\":$UPGRADE_DEPS,\"current_version\":\"$CURRENT_VERSION\",\"timestamp\":$(date +%s)}"
            record_update_history "FAILED" "$CURRENT_VERSION" "unknown" "upgrade dependencies installation failed"
            exit 1
        fi
    done
else
    log "无需安装升级依赖"
fi

# -----------------------------------------------------------------------------
# 停止服务
# -----------------------------------------------------------------------------
log "停止 Node-RED 服务进行更新"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"stopping service\",\"timestamp\":$(date +%s)}"

bash "$SERVICE_DIR/stop.sh"
sleep 5

# -----------------------------------------------------------------------------
# 执行升级（进入 proot 容器）
# -----------------------------------------------------------------------------
log "更新 Node-RED 到版本 $TARGET_VERSION"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"updating node-red package\",\"timestamp\":$(date +%s)}"

if ! proot-distro login "$PROOT_DISTRO" -- bash -c "
    source ~/.bashrc
    cd $NR_INSTALL_DIR
    pnpm up node-red@$TARGET_VERSION
"; then
    log "Node-RED 更新失败"
    mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"node-red package update failed\",\"current_version\":\"$CURRENT_VERSION\",\"timestamp\":$(date +%s)}"
    record_update_history "FAILED" "$CURRENT_VERSION" "unknown" "package update failed"
    exit 1
fi

# -----------------------------------------------------------------------------
# 更新 package.json
# -----------------------------------------------------------------------------
log "更新 package.json"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"updating package.json\",\"timestamp\":$(date +%s)}"

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

# -----------------------------------------------------------------------------
# 版本校验
# -----------------------------------------------------------------------------
UPDATED_VERSION=$(get_current_version)

if [ "$UPDATED_VERSION" = "unknown" ]; then
    log "无法获取更新后的版本"
    mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"failed to get updated version\",\"current_version\":\"$CURRENT_VERSION\",\"timestamp\":$(date +%s)}"
    record_update_history "FAILED" "$CURRENT_VERSION" "unknown" "failed to get updated version"
    exit 1
fi

log "更新到版本: $UPDATED_VERSION"

# 检查版本是否实际发生了变化
if [ "$CURRENT_VERSION" = "$UPDATED_VERSION" ]; then
    log "版本未发生变化，可能已经是最新版本"
fi

# -----------------------------------------------------------------------------
# 重启服务并健康检查
# -----------------------------------------------------------------------------
log "启动服务"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"starting service\",\"timestamp\":$(date +%s)}"

bash "$SERVICE_DIR/start.sh"

log "等待服务就绪"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"waiting for service ready\",\"timestamp\":$(date +%s)}"

MAX_WAIT=300
INTERVAL=5
WAITED=0

while [ "$WAITED" -lt "$MAX_WAIT" ]; do
    if bash "$SERVICE_DIR/status.sh" --quiet; then
        DURATION=$(( $(date +%s) - START_TIME ))
        log "服务在 ${WAITED}s 后启动成功"
        
        # 记录更新历史
        log "记录更新历史"
        mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"old_version\":\"$CURRENT_VERSION\",\"new_version\":\"$UPDATED_VERSION\",\"message\":\"recording update history\",\"timestamp\":$(date +%s)}"
        
        record_update_history "SUCCESS" "$CURRENT_VERSION" "$UPDATED_VERSION" ""
        
        mqtt_report "isg/update/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"success\",\"old_version\":\"$CURRENT_VERSION\",\"new_version\":\"$UPDATED_VERSION\",\"duration\":$DURATION,\"timestamp\":$(date +%s)}"
        
        # 更新版本文件
        echo "$UPDATED_VERSION" > "$VERSION_FILE"
        log "更新完成: $CURRENT_VERSION → $UPDATED_VERSION，耗时 ${DURATION}s"
        
        # 验证服务状态
        sleep 3
        if bash "$SERVICE_DIR/status.sh" --json | grep -q '"status":"running"'; then
            log "✅ 服务状态验证成功"
        else
            log "⚠️  服务状态验证失败，但更新已完成"
        fi
        
        exit 0
    fi
    sleep "$INTERVAL"
    WAITED=$((WAITED + INTERVAL))
done

log "超时: 服务在 ${MAX_WAIT}s 后仍未启动"
record_update_history "FAILED" "$CURRENT_VERSION" "$UPDATED_VERSION" "service start timeout"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"service start timeout after update\",\"old_version\":\"$CURRENT_VERSION\",\"new_version\":\"$UPDATED_VERSION\",\"timeout\":$MAX_WAIT,\"timestamp\":$(date +%s)}"
exit 1
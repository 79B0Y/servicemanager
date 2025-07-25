#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Matter Server 升级脚本 (新版)
# - 风格与 install/restore 完全统一
# - 升级前自动备份
# - 日志中文/MQTT全英文
# =============================================================================

set -euo pipefail

# ------------------- 路径与变量 -------------------
SERVICE_ID="matter-server"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"
CONFIG_FILE="$BASE_DIR/configuration.yaml"
SERVICEUPDATE_FILE="$BASE_DIR/serviceupdate.json"
VERSION_FILE="$SERVICE_DIR/VERSION"
BACKUP_DIR="/sdcard/isgbackup/$SERVICE_ID"
LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/update.log"
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
MATTER_INSTALL_DIR="/opt/matter-server"
MATTER_VENV_DIR="$MATTER_INSTALL_DIR/venv"
MATTER_PORT="5580"
MAX_WAIT=300
INTERVAL=5

START_TIME=$(date +%s)

# ------------------- 工具函数 -------------------
ensure_directories() {
    mkdir -p "$LOG_DIR" "$BACKUP_DIR"
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
    if ! nc -z "$MQTT_HOST" "$MQTT_PORT_CONFIG" 2>/dev/null; then
        echo "[$(date '+%F %T')] [MQTT-OFFLINE] $topic -> $payload" >> "$LOG_FILE"
        return
    fi
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT_CONFIG" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload" 2>/dev/null || true
    echo "[$(date '+%F %T')] [MQTT] $topic -> $payload" >> "$LOG_FILE"
}
get_current_version() {
    proot-distro login "$PROOT_DISTRO" -- bash -c "source $MATTER_VENV_DIR/bin/activate && pip show python-matter-server | grep ^Version: | awk '{print \$2}'" 2>/dev/null || echo "unknown"
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
    echo "$timestamp $status $old_version -> $new_version $reason" >> "$BACKUP_DIR/.update_history"
}

# ------------------- 主流程 -------------------
ensure_directories
log "Matter Server 升级开始"
CURRENT_VERSION=$(get_current_version)
log "当前版本: $CURRENT_VERSION"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"starting update process\",\"timestamp\":$(date +%s)}"

# ------------------- 自动备份 -------------------
if [ -f "$SERVICE_DIR/backup.sh" ]; then
    log "升级前自动备份数据..."
    bash "$SERVICE_DIR/backup.sh"
    log "自动备份完成"
else
    log "未检测到 backup.sh，跳过自动备份"
fi

# ------------------- 获取目标版本与升级依赖 -------------------
log "读取升级依赖配置"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"reading upgrade dependencies\",\"timestamp\":$(date +%s)}"
if [ -f "$SERVICEUPDATE_FILE" ]; then
    UPGRADE_DEPS=$(get_upgrade_dependencies)
    TARGET_VERSION=$(get_latest_version)
else
    UPGRADE_DEPS='[]'
    TARGET_VERSION="unknown"
fi

# 获取 PyPI 最新版
if [ "$TARGET_VERSION" = "unknown" ]; then
    TARGET_VERSION=$(proot-distro login "$PROOT_DISTRO" -- bash -c "source $MATTER_VENV_DIR/bin/activate && pip install --upgrade pip > /dev/null && pip index versions python-matter-server 2>/dev/null | grep -Eo '[0-9]+\\.[0-9]+\\.[0-9]+' | head -n1") || TARGET_VERSION="latest"
    log "目标版本自动检测为: $TARGET_VERSION"
else
    log "目标版本: $TARGET_VERSION"
fi

# 升级依赖
DEPS_ARRAY=()
if [ "$UPGRADE_DEPS" != "[]" ] && [ "$UPGRADE_DEPS" != "null" ]; then
    while IFS= read -r dep; do
        DEPS_ARRAY+=("$dep")
    done < <(echo "$UPGRADE_DEPS" | jq -r '.[]' 2>/dev/null || true)
fi

if [ ${#DEPS_ARRAY[@]} -gt 0 ]; then
    log "安装升级依赖: ${DEPS_ARRAY[*]}"
    mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"installing upgrade dependencies\",\"dependencies\":$UPGRADE_DEPS,\"timestamp\":$(date +%s)}"
    for dep in "${DEPS_ARRAY[@]}"; do
        log "安装依赖: $dep"
        if ! proot-distro login "$PROOT_DISTRO" -- bash -c "source $MATTER_VENV_DIR/bin/activate && pip install '$dep'"; then
            log "依赖 $dep 安装失败"
            mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"upgrade dependencies installation failed\",\"dependencies\":$UPGRADE_DEPS,\"current_version\":\"$CURRENT_VERSION\",\"timestamp\":$(date +%s)}"
            record_update_history "FAILED" "$CURRENT_VERSION" "unknown" "upgrade dependencies installation failed"
            exit 1
        fi
    done
else
    log "无需安装升级依赖"
fi

# ------------------- 停止服务 -------------------
log "停止 Matter Server 服务进行升级"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"stopping service\",\"timestamp\":$(date +%s)}"
bash "$SERVICE_DIR/stop.sh"
sleep 5

# ------------------- 升级核心包 -------------------
log "升级 python-matter-server 到版本 $TARGET_VERSION"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"updating python-matter-server package\",\"target_version\":\"$TARGET_VERSION\",\"timestamp\":$(date +%s)}"

if ! proot-distro login "$PROOT_DISTRO" -- bash -c "source $MATTER_VENV_DIR/bin/activate && pip install --upgrade python-matter-server==$TARGET_VERSION"; then
    log "python-matter-server 升级失败"
    mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"python-matter-server package update failed\",\"current_version\":\"$CURRENT_VERSION\",\"timestamp\":$(date +%s)}"
    record_update_history "FAILED" "$CURRENT_VERSION" "unknown" "package update failed"
    exit 1
fi

# ------------------- 版本校验 -------------------
UPDATED_VERSION=$(get_current_version)
if [ "$UPDATED_VERSION" = "unknown" ]; then
    log "无法获取升级后的版本"
    mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"failed to get updated version\",\"current_version\":\"$CURRENT_VERSION\",\"timestamp\":$(date +%s)}"
    record_update_history "FAILED" "$CURRENT_VERSION" "unknown" "failed to get updated version"
    exit 1
fi
log "已升级到版本: $UPDATED_VERSION"
if [ "$CURRENT_VERSION" = "$UPDATED_VERSION" ]; then
    log "版本未发生变化，可能已是最新版"
fi

# ------------------- 启动服务并健康检查 -------------------
log "启动服务"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"starting service\",\"timestamp\":$(date +%s)}"
bash "$SERVICE_DIR/start.sh"
log "等待服务就绪"
WAITED=0
while [ "$WAITED" -lt "$MAX_WAIT" ]; do
    if bash "$SERVICE_DIR/status.sh" --quiet; then
        DURATION=$(( $(date +%s) - START_TIME ))
        log "服务在 ${WAITED}s 后启动成功"
        # 记录更新历史
        record_update_history "SUCCESS" "$CURRENT_VERSION" "$UPDATED_VERSION" ""
        mqtt_report "isg/update/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"success\",\"old_version\":\"$CURRENT_VERSION\",\"new_version\":\"$UPDATED_VERSION\",\"duration\":$DURATION,\"timestamp\":$(date +%s)}"
        echo "$UPDATED_VERSION" > "$VERSION_FILE"
        log "升级完成: $CURRENT_VERSION → $UPDATED_VERSION，耗时 ${DURATION}s"
        sleep 3
        if bash "$SERVICE_DIR/status.sh" --json | grep -q '\"status\":\"running\"'; then
            log "✅ 服务状态验证成功"
        else
            log "⚠️  服务状态验证失败，但升级已完成"
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

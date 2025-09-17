#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# isg-credential-services 升级脚本 - 完整修复版本
# 版本: v1.0.0
# 功能: 
# - 统一使用基础要求里的版本获取方法
# - 新增版本比较逻辑，避免不必要的降级
# - 升级前自动备份
# - 日志中文/MQTT全英文
# =============================================================================

set -euo pipefail

# ------------------- 路径与变量 -------------------
SERVICE_ID="isg-credential-services"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"
CONFIG_FILE="$BASE_DIR/configuration.yaml"
SERVICEUPDATE_FILE="$BASE_DIR/serviceupdate.json"
VERSION_FILE="$SERVICE_DIR/VERSION"
BACKUP_DIR="/sdcard/isgbackup/$SERVICE_ID"
LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/update.log"
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
CREDENTIAL_INSTALL_DIR="/root/isg-credential-services"
CREDENTIAL_PORT="3000"
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

# 修复: 使用基础要求里的标准版本获取方法
get_current_version() {
    proot-distro login "$PROOT_DISTRO" -- bash -c '
        if [ -d "'"$CREDENTIAL_INSTALL_DIR"'" ]; then
            cd "'"$CREDENTIAL_INSTALL_DIR"'"
            bash manage-service.sh version
        else
            echo "unknown"
        fi
    ' 2>/dev/null || echo "unknown"
}

get_latest_version() {
    jq -r ".services[] | select(.id==\"$SERVICE_ID\") | .latest_service_version" "$SERVICEUPDATE_FILE" 2>/dev/null || echo "unknown"
}

get_upgrade_dependencies() {
    jq -c ".services[] | select(.id==\"$SERVICE_ID\") | .upgrade_dependencies" "$SERVICEUPDATE_FILE" 2>/dev/null || echo "[]"
}

# 版本比较函数：比较两个语义化版本号
# 返回值：0=相等，1=第一个版本较新，2=第二个版本较新，3=无法比较
compare_versions() {
    local current="$1"
    local target="$2"
    
    # 处理 unknown 版本
    if [[ "$current" == "unknown" || "$target" == "unknown" ]]; then
        echo 3
        return
    fi
    
    # 处理相同版本
    if [[ "$current" == "$target" ]]; then
        echo 0
        return
    fi
    
    # 提取版本号数字（去除非数字字符）
    local current_clean=$(echo "$current" | sed 's/[^0-9.]//g')
    local target_clean=$(echo "$target" | sed 's/[^0-9.]//g')
    
    # 如果清理后为空，无法比较
    if [[ -z "$current_clean" || -z "$target_clean" ]]; then
        echo 3
        return
    fi
    
    # 使用 sort -V 进行版本比较
    local sorted=$(printf '%s\n%s\n' "$current_clean" "$target_clean" | sort -V)
    local first_line=$(echo "$sorted" | head -n1)
    
    if [[ "$first_line" == "$current_clean" ]]; then
        if [[ "$current_clean" == "$target_clean" ]]; then
            echo 0  # 相等
        else
            echo 2  # target 版本较新
        fi
    else
        echo 1  # current 版本较新
    fi
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
log "isg-credential-services 升级开始"
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

# 获取 GitHub 最新版
if [ "$TARGET_VERSION" = "unknown" ]; then
    TARGET_VERSION=$(proot-distro login "$PROOT_DISTRO" -- bash -c "
        cd '$CREDENTIAL_INSTALL_DIR'
        git fetch origin
        git describe --tags --abbrev=0 HEAD 2>/dev/null || echo 'latest'
    " 2>/dev/null || echo "latest")
    log "目标版本自动检测为: $TARGET_VERSION"
else
    log "目标版本: $TARGET_VERSION"
fi

# ------------------- 版本比较检查 -------------------
log "检查版本比较: 当前版本 $CURRENT_VERSION vs 目标版本 $TARGET_VERSION"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"target_version\":\"$TARGET_VERSION\",\"message\":\"comparing versions\",\"timestamp\":$(date +%s)}"

VERSION_COMPARE=$(compare_versions "$CURRENT_VERSION" "$TARGET_VERSION")

case $VERSION_COMPARE in
    0)
        log "当前版本与目标版本相同，无需升级"
        END_TIME=$(date +%s)
        DURATION=$((END_TIME - START_TIME))
        record_update_history "SKIPPED" "$CURRENT_VERSION" "$TARGET_VERSION" "versions are identical"
        mqtt_report "isg/update/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"skipped\",\"current_version\":\"$CURRENT_VERSION\",\"target_version\":\"$TARGET_VERSION\",\"reason\":\"versions are identical\",\"duration\":$DURATION,\"timestamp\":$END_TIME}"
        log "✅ 升级跳过: 版本相同"
        exit 0
        ;;
    1)
        log "当前版本 ($CURRENT_VERSION) 比目标版本 ($TARGET_VERSION) 更新，跳过升级"
        END_TIME=$(date +%s)
        DURATION=$((END_TIME - START_TIME))
        record_update_history "SKIPPED" "$CURRENT_VERSION" "$TARGET_VERSION" "current version is newer"
        mqtt_report "isg/update/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"skipped\",\"current_version\":\"$CURRENT_VERSION\",\"target_version\":\"$TARGET_VERSION\",\"reason\":\"current version is newer\",\"duration\":$DURATION,\"timestamp\":$END_TIME}"
        log "✅ 升级跳过: 当前版本更新"
        exit 0
        ;;
    2)
        log "目标版本 ($TARGET_VERSION) 比当前版本 ($CURRENT_VERSION) 更新，继续升级"
        mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"target_version\":\"$TARGET_VERSION\",\"message\":\"target version is newer, proceeding with upgrade\",\"timestamp\":$(date +%s)}"
        ;;
    3)
        log "无法比较版本 ($CURRENT_VERSION vs $TARGET_VERSION)，强制升级"
        mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"target_version\":\"$TARGET_VERSION\",\"message\":\"cannot compare versions, forcing upgrade\",\"timestamp\":$(date +%s)}"
        ;;
esac

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
        if ! proot-distro login "$PROOT_DISTRO" -- bash -c "apt-get update && apt-get install -y '$dep'"; then
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
log "停止 isg-credential-services 服务进行升级"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"stopping service\",\"timestamp\":$(date +%s)}"
bash "$SERVICE_DIR/stop.sh"
sleep 5

# ------------------- 升级核心包 -------------------
log "升级 isg-credential-services 到版本 $TARGET_VERSION"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"updating isg-credential-services package\",\"target_version\":\"$TARGET_VERSION\",\"timestamp\":$(date +%s)}"

if ! proot-distro login "$PROOT_DISTRO" -- bash -c "
    cd /root
    rm -rf isg-credential-services
    git clone https://github.com/79B0Y/isg-credential-services.git
    cd isg-credential-services
    npm install
"; then
    log "isg-credential-services 升级失败"
    mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"isg-credential-services package update failed\",\"current_version\":\"$CURRENT_VERSION\",\"timestamp\":$(date +%s)}"
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
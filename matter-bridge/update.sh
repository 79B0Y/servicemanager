#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Matter Bridge 升级脚本
# 版本: v1.0.0
# 功能: 升级 Home Assistant Matter Bridge 到最新版本
# =============================================================================

set -euo pipefail

# ------------------- 路径与变量 -------------------
SERVICE_ID="matter-bridge"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"
CONFIG_FILE="$BASE_DIR/configuration.yaml"
SERVICEUPDATE_FILE="$BASE_DIR/serviceupdate.json"
VERSION_FILE="$SERVICE_DIR/VERSION"
BACKUP_DIR="/sdcard/isgbackup/$SERVICE_ID"
LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/update.log"
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
MATTER_BRIDGE_PORT="8482"
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
    proot-distro login "$PROOT_DISTRO" -- bash -c '
        VERSION_FILE="/root/.pnpm-global/global/5/node_modules/home-assistant-matter-hub/package.json"
        if [ -f "$VERSION_FILE" ]; then
            jq -r .version "$VERSION_FILE" 2>/dev/null || echo "unknown"
        else
            echo "unknown"
        fi
    ' 2>/dev/null || echo "unknown"
}

get_latest_version() {
    # 从 serviceupdate.json 获取最新版本
    if [ -f "$SERVICEUPDATE_FILE" ]; then
        jq -r ".services[] | select(.id==\"$SERVICE_ID\") | .latest_service_version" "$SERVICEUPDATE_FILE" 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
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
log "Matter Bridge 升级开始"
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

# ------------------- 获取目标版本 -------------------
TARGET_VERSION=$(get_latest_version)

# 如果从配置文件获取失败，使用 latest
if [ "$TARGET_VERSION" = "unknown" ]; then
    TARGET_VERSION="latest"
    log "目标版本设置为: latest (从 npm 获取最新版本)"
else
    log "目标版本: $TARGET_VERSION"
fi

# ------------------- 版本比较检查 -------------------
if [ "$TARGET_VERSION" != "latest" ]; then
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
fi

# ------------------- 停止服务 -------------------
log "停止 Matter Bridge 服务进行升级"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"stopping service\",\"timestamp\":$(date +%s)}"
bash "$SERVICE_DIR/stop.sh"
sleep 5

# ------------------- 升级核心包 -------------------
log "升级 home-assistant-matter-hub"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"updating home-assistant-matter-hub package\",\"target_version\":\"$TARGET_VERSION\",\"timestamp\":$(date +%s)}"

UPGRADE_CMD="pnpm add -g home-assistant-matter-hub@latest"
if [ "$TARGET_VERSION" != "latest" ]; then
    UPGRADE_CMD="pnpm add -g home-assistant-matter-hub@$TARGET_VERSION"
fi

if ! proot-distro login "$PROOT_DISTRO" -- bash -c "
    export PATH=\"\$HOME/.pnpm-global/global/bin:\$PATH\"
    $UPGRADE_CMD
"; then
    log "home-assistant-matter-hub 升级失败"
    mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"home-assistant-matter-hub package update failed\",\"current_version\":\"$CURRENT_VERSION\",\"timestamp\":$(date +%s)}"
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
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"waiting for service ready\",\"timestamp\":$(date +%s)}"

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
        
        # 验证服务状态
        sleep 3
        if bash "$SERVICE_DIR/status.sh" --json | grep -q '"status":"running"'; then
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

#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# isg-android-control 升级脚本
# 版本: v1.0.0
# 功能: 比较版本并执行重新安装升级
# =============================================================================

set -euo pipefail

# ------------------- 路径与变量 -------------------
SERVICE_ID="isg-android-control"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"
CONFIG_FILE="$BASE_DIR/configuration.yaml"
SERVICEUPDATE_FILE="$BASE_DIR/serviceupdate.json"
VERSION_FILE="$SERVICE_DIR/VERSION"

LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/update.log"
UPDATE_HISTORY_FILE="$SERVICE_DIR/.update_history"

PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"

START_TIME=$(date +%s)

# ------------------- 工具函数 -------------------
ensure_directories() {
    mkdir -p "$LOG_DIR"
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

mqtt_report() {
    local topic="$1"
    local payload="$2"
    if ! nc -z 127.0.0.1 1883 2>/dev/null; then
        echo "[$(date '+%F %T')] [MQTT-OFFLINE] $topic -> $payload" >> "$LOG_FILE"
        return
    fi
    load_mqtt_conf
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT_CONFIG" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload" 2>/dev/null || true
    echo "[$(date '+%F %T')] [MQTT] $topic -> $payload" >> "$LOG_FILE"
}

get_android_control_version() {
    # 使用临时文件避免管道导致的文件描述符问题
    local temp_file="/data/data/com.termux/files/usr/tmp/isg_version_$"
    mkdir -p "/data/data/com.termux/files/usr/tmp"
    
    if proot-distro login ubuntu -- bash -lc '
        /root/.local/bin/isg-android-control version
    ' > "$temp_file" 2>/dev/null; then
        local version=$(cat "$temp_file" | head -n1 | tr -d '\n\r\t ')
        rm -f "$temp_file"
        echo "${version:-unknown}"
    else
        rm -f "$temp_file"
        echo "unknown"
    fi
}

get_latest_version() {
    if [[ -f "$SERVICEUPDATE_FILE" ]]; then
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
    echo "$timestamp UPDATE $status $old_version -> $new_version $reason" >> "$UPDATE_HISTORY_FILE"
}

# ------------------- 主流程 -------------------
ensure_directories

log "开始 isg-android-control 升级检查"
CURRENT_VERSION=$(get_android_control_version)
log "当前版本: $CURRENT_VERSION"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"starting update process\",\"timestamp\":$(date +%s)}"

# ------------------- 获取目标版本 -------------------
log "获取最新版本信息"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"reading latest version from serviceupdate.json\",\"timestamp\":$(date +%s)}"

TARGET_VERSION=$(get_latest_version)
log "目标版本: $TARGET_VERSION"

if [[ "$TARGET_VERSION" == "unknown" ]]; then
    log "无法获取最新版本信息，升级终止"
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    record_update_history "FAILED" "$CURRENT_VERSION" "unknown" "cannot get latest version"
    mqtt_report "isg/update/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"failed\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"cannot get latest version from serviceupdate.json\",\"duration\":$DURATION,\"timestamp\":$END_TIME}"
    exit 1
fi

# ------------------- 版本比较检查 -------------------
log "比较版本: 当前版本 $CURRENT_VERSION vs 目标版本 $TARGET_VERSION"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"target_version\":\"$TARGET_VERSION\",\"message\":\"comparing versions\",\"timestamp\":$(date +%s)}"

VERSION_COMPARE=$(compare_versions "$CURRENT_VERSION" "$TARGET_VERSION")

case $VERSION_COMPARE in
    0)
        log "当前版本与目标版本相同，无需升级"
        END_TIME=$(date +%s)
        DURATION=$((END_TIME - START_TIME))
        record_update_history "SKIPPED" "$CURRENT_VERSION" "$TARGET_VERSION" "versions are identical"
        mqtt_report "isg/update/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"updated\",\"current_version\":\"$CURRENT_VERSION\",\"target_version\":\"$TARGET_VERSION\",\"reason\":\"versions are identical\",\"duration\":$DURATION,\"timestamp\":$END_TIME}"
        log "✅ 升级跳过: 版本相同"
        exit 0
        ;;
    1)
        log "当前版本 ($CURRENT_VERSION) 比目标版本 ($TARGET_VERSION) 更新，跳过升级"
        END_TIME=$(date +%s)
        DURATION=$((END_TIME - START_TIME))
        record_update_history "SKIPPED" "$CURRENT_VERSION" "$TARGET_VERSION" "current version is newer"
        mqtt_report "isg/update/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"updated\",\"current_version\":\"$CURRENT_VERSION\",\"target_version\":\"$TARGET_VERSION\",\"reason\":\"current version is newer\",\"duration\":$DURATION,\"timestamp\":$END_TIME}"
        log "✅ 升级跳过: 当前版本更新"
        exit 0
        ;;
    2)
        log "目标版本 ($TARGET_VERSION) 比当前版本 ($CURRENT_VERSION) 更新，开始升级"
        mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"target_version\":\"$TARGET_VERSION\",\"message\":\"target version is newer, proceeding with upgrade\",\"timestamp\":$(date +%s)}"
        ;;
    3)
        log "无法比较版本 ($CURRENT_VERSION vs $TARGET_VERSION)，强制升级"
        mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"target_version\":\"$TARGET_VERSION\",\"message\":\"cannot compare versions, forcing upgrade\",\"timestamp\":$(date +%s)}"
        ;;
esac

# ------------------- 执行升级流程 -------------------
log "开始升级流程: $CURRENT_VERSION -> $TARGET_VERSION"

# 步骤1: 停止服务
log "步骤1: 停止服务"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"target_version\":\"$TARGET_VERSION\",\"message\":\"stopping service\",\"timestamp\":$(date +%s)}"

if [ -f "$SERVICE_DIR/stop.sh" ]; then
    if ! bash "$SERVICE_DIR/stop.sh"; then
        log "停止服务失败"
        record_update_history "FAILED" "$CURRENT_VERSION" "$TARGET_VERSION" "failed to stop service"
        mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"failed to stop service\",\"current_version\":\"$CURRENT_VERSION\",\"target_version\":\"$TARGET_VERSION\",\"timestamp\":$(date +%s)}"
        exit 1
    fi
else
    log "警告: stop.sh 不存在"
fi

sleep 3

# 步骤2: 卸载当前版本
log "步骤2: 卸载当前版本"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"target_version\":\"$TARGET_VERSION\",\"message\":\"uninstalling current version\",\"timestamp\":$(date +%s)}"

if [ -f "$SERVICE_DIR/uninstall.sh" ]; then
    if ! bash "$SERVICE_DIR/uninstall.sh"; then
        log "卸载失败"
        record_update_history "FAILED" "$CURRENT_VERSION" "$TARGET_VERSION" "failed to uninstall"
        mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"failed to uninstall current version\",\"current_version\":\"$CURRENT_VERSION\",\"target_version\":\"$TARGET_VERSION\",\"timestamp\":$(date +%s)}"
        exit 1
    fi
else
    log "警告: uninstall.sh 不存在"
fi

sleep 3

# 步骤3: 重新安装新版本
log "步骤3: 安装新版本"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"target_version\":\"$TARGET_VERSION\",\"message\":\"installing new version\",\"timestamp\":$(date +%s)}"

if [ -f "$SERVICE_DIR/install.sh" ]; then
    if ! bash "$SERVICE_DIR/install.sh"; then
        log "安装新版本失败"
        record_update_history "FAILED" "$CURRENT_VERSION" "$TARGET_VERSION" "failed to install new version"
        mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"failed to install new version\",\"current_version\":\"$CURRENT_VERSION\",\"target_version\":\"$TARGET_VERSION\",\"timestamp\":$(date +%s)}"
        exit 1
    fi
else
    log "错误: install.sh 不存在"
    record_update_history "FAILED" "$CURRENT_VERSION" "$TARGET_VERSION" "install.sh not found"
    mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"install.sh not found\",\"current_version\":\"$CURRENT_VERSION\",\"target_version\":\"$TARGET_VERSION\",\"timestamp\":$(date +%s)}"
    exit 1
fi

# ------------------- 验证升级结果 -------------------
log "验证升级结果"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"target_version\":\"$TARGET_VERSION\",\"message\":\"verifying upgrade\",\"timestamp\":$(date +%s)}"

# 等待一下让服务稳定
sleep 5

# 获取升级后的版本
UPDATED_VERSION=$(get_android_control_version)
log "升级后版本: $UPDATED_VERSION"

# 检查服务状态
if bash "$SERVICE_DIR/status.sh" --quiet; then
    SERVICE_STATUS="running"
else
    SERVICE_STATUS="stopped"
fi

# ------------------- 升级完成 -------------------
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

if [[ "$UPDATED_VERSION" != "unknown" && "$SERVICE_STATUS" == "running" ]]; then
    log "升级成功完成: $CURRENT_VERSION -> $UPDATED_VERSION，耗时 ${DURATION}s"
    record_update_history "SUCCESS" "$CURRENT_VERSION" "$UPDATED_VERSION" ""
    
    # 更新版本缓存文件
    echo "$UPDATED_VERSION" > "$VERSION_FILE" 2>/dev/null || true
    
    mqtt_report "isg/update/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"updated\",\"old_version\":\"$CURRENT_VERSION\",\"new_version\":\"$UPDATED_VERSION\",\"target_version\":\"$TARGET_VERSION\",\"duration\":$DURATION,\"timestamp\":$END_TIME}"
    log "✅ 升级成功"
    exit 0
else
    log "升级失败: 服务状态=$SERVICE_STATUS, 版本=$UPDATED_VERSION"
    record_update_history "FAILED" "$CURRENT_VERSION" "$UPDATED_VERSION" "service not running or version unknown"
    mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"service not running after upgrade or version unknown\",\"old_version\":\"$CURRENT_VERSION\",\"new_version\":\"$UPDATED_VERSION\",\"target_version\":\"$TARGET_VERSION\",\"service_status\":\"$SERVICE_STATUS\",\"duration\":$DURATION,\"timestamp\":$END_TIME}"
    exit 1
fi

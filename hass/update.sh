#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Home Assistant 更新脚本 - 独立版本
# 版本: v1.5.0
# 功能: 升级 Home Assistant 到指定版本
# 特点: 完全独立，不依赖 common_paths.sh
# =============================================================================

set -euo pipefail

# =============================================================================
# 独立的路径和配置定义
# =============================================================================
SERVICE_ID="hass"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"

# 配置文件路径
CONFIG_FILE="$BASE_DIR/configuration.yaml"
SERVICEUPDATE_FILE="$BASE_DIR/serviceupdate.json"
VERSION_FILE="$SERVICE_DIR/VERSION.yaml"

# 日志和临时文件
LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/update.log"
TEMP_DIR="/data/data/com.termux/files/usr/tmp"
HA_VERSION_TEMP="$TEMP_DIR/hass_version.txt"

# 备份相关
BACKUP_DIR="${BACKUP_DIR:-/sdcard/isgbackup/$SERVICE_ID}"
UPDATE_HISTORY_FILE="$BACKUP_DIR/.update_history"

# 容器相关
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
HA_VENV_DIR="/root/homeassistant"

# 服务默认版本
DEFAULT_HA_VERSION="${TARGET_VERSION:-2025.5.3}"

# =============================================================================
# 独立的工具函数
# =============================================================================

# 确保目录存在
ensure_directories() {
    mkdir -p "$LOG_DIR" "$BACKUP_DIR" "$TEMP_DIR" 2>/dev/null || true
}

# 日志记录
log() {
    echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"
}

# 加载 MQTT 配置
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

# MQTT 消息发布
mqtt_report() {
    local topic="$1"
    local payload="$2"
    
    load_mqtt_conf
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload" 2>/dev/null || true
    log "[MQTT] $topic -> $payload"
}

# 获取当前 HA 版本
get_current_ha_version() {
    if proot-distro login "$PROOT_DISTRO" -- bash -c "source $HA_VENV_DIR/bin/activate && hass --version" 2>/dev/null | head -n1; then
        return
    else
        echo "unknown"
    fi
}

# 获取最新 HA 版本
get_latest_ha_version() {
    if [[ -f "$SERVICEUPDATE_FILE" ]]; then
        jq -r ".services[] | select(.id==\"$SERVICE_ID\") | .latest_ha_version" "$SERVICEUPDATE_FILE" 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
}

# 获取升级依赖
get_upgrade_dependencies() {
    if [[ -f "$SERVICEUPDATE_FILE" ]]; then
        jq -c ".services[] | select(.id==\"$SERVICE_ID\") | .upgrade_dependencies // []" "$SERVICEUPDATE_FILE" 2>/dev/null || echo "[]"
    else
        echo "[]"
    fi
}

# 记录更新历史
record_update_history() {
    local status="$1"
    local old_version="$2"
    local new_version="$3"
    local reason="$4"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    ensure_directories
    if [ "$status" = "SUCCESS" ]; then
        echo "$timestamp SUCCESS $old_version -> $new_version" >> "$UPDATE_HISTORY_FILE"
    else
        echo "$timestamp FAILED $old_version -> $new_version ($reason)" >> "$UPDATE_HISTORY_FILE"
    fi
}

# =============================================================================
# 主程序开始
# =============================================================================

START_TIME=$(date +%s)
ensure_directories

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

UPGRADE_DEPS=$(get_upgrade_dependencies)

# 针对特定版本定义额外依赖
EXTRA_PIP_PKGS=""
case "$TARGET_VERSION" in
    2025.7.1) EXTRA_PIP_PKGS="click==8.1.7";;
    2025.8.0) EXTRA_PIP_PKGS="setuptools>=65.0.0";;
    # 添加更多版本特定依赖
esac

# 转换为 bash 数组
DEPS_ARRAY=()
if [ "$UPGRADE_DEPS" != "[]" ] && [ "$UPGRADE_DEPS" != "null" ]; then
    while IFS= read -r dep; do
        DEPS_ARRAY+=("$dep")
    done < <(echo "$UPGRADE_DEPS" | jq -r '.[]' 2>/dev/null || true)
fi

# 合并所有依赖
ALL_DEPS="${DEPS_ARRAY[*]} $EXTRA_PIP_PKGS"
ALL_DEPS=$(echo "$ALL_DEPS" | xargs)  # 去除多余空格

if [ -n "$ALL_DEPS" ]; then
    log "will install upgrade dependencies: $ALL_DEPS"
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
# 执行升级
# -----------------------------------------------------------------------------
log "performing Home Assistant upgrade in proot container"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"installing new version\",\"target_version\":\"$TARGET_VERSION\",\"timestamp\":$(date +%s)}"

if ! proot-distro login "$PROOT_DISTRO" << EOF
set -euo pipefail

log_step() {
    echo "[STEP] \$1"
}

# 传递外部变量到容器内
export TARGET_VERSION="$TARGET_VERSION"
export ALL_DEPS="$ALL_DEPS"
export CURRENT_VERSION="$CURRENT_VERSION"

log_step "Activating virtual environment"
source $HA_VENV_DIR/bin/activate

log_step "Verifying current Home Assistant version"
ACTUAL_CURRENT=\$(hass --version 2>/dev/null | head -n1 || echo "unknown")
log_step "Current version in container: \$ACTUAL_CURRENT"

log_step "Upgrading pip to latest version"
pip install --upgrade pip

# 安装升级依赖（如果有）
if [ -n "\$ALL_DEPS" ]; then
    log_step "Installing upgrade dependencies: \$ALL_DEPS"
    pip install \$ALL_DEPS
else
    log_step "No upgrade dependencies to install"
fi

log_step "Upgrading Home Assistant to version \$TARGET_VERSION"
pip install --upgrade "homeassistant==\$TARGET_VERSION"

log_step "Verifying new Home Assistant version"
NEW_VERSION=\$(hass --version 2>/dev/null | head -n1 || echo "unknown")
log_step "New version after upgrade: \$NEW_VERSION"

# 将版本信息写入临时文件供外部脚本读取
echo "\$NEW_VERSION" > $HA_VERSION_TEMP

log_step "Home Assistant upgrade completed successfully"
EOF
then
    log "Home Assistant upgrade failed"
    mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"Home Assistant upgrade failed\",\"current_version\":\"$CURRENT_VERSION\",\"target_version\":\"$TARGET_VERSION\",\"timestamp\":$(date +%s)}"
    record_update_history "FAILED" "$CURRENT_VERSION" "$TARGET_VERSION" "pip install failed"
    exit 1
fi

# -----------------------------------------------------------------------------
# 版本校验
# -----------------------------------------------------------------------------
log "verifying upgrade results"
UPDATED_VERSION=$(cat "$HA_VERSION_TEMP" 2>/dev/null || echo "unknown")

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

log "version verification successful: $CURRENT_VERSION → $UPDATED_VERSION"

# -----------------------------------------------------------------------------
# 清理临时文件
# -----------------------------------------------------------------------------
rm -f "$HA_VERSION_TEMP"

# -----------------------------------------------------------------------------
# 重启服务并健康检查
# -----------------------------------------------------------------------------
log "starting service after upgrade"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"starting service\",\"new_version\":\"$UPDATED_VERSION\",\"timestamp\":$(date +%s)}"

bash "$SERVICE_DIR/start.sh"

log "waiting for service ready after upgrade"
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
        if [[ -f "$VERSION_FILE" ]]; then
            # 更新现有版本文件中的版本号，保持其他内容不变
            sed -i "s/version: .*/version: $UPDATED_VERSION/" "$VERSION_FILE"
        else
            # 创建简单的版本文件
            echo "version: $UPDATED_VERSION" > "$VERSION_FILE"
        fi
        
        log "update completed successfully: $CURRENT_VERSION → $UPDATED_VERSION (${DURATION}s)"
        exit 0
    fi
    sleep "$INTERVAL"
    WAITED=$((WAITED + INTERVAL))
done

log "timeout: service not running after ${MAX_WAIT}s"
record_update_history "FAILED" "$CURRENT_VERSION" "$UPDATED_VERSION" "service start timeout"
mqtt_report "isg/update/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"service start timeout after update\",\"old_version\":\"$CURRENT_VERSION\",\"new_version\":\"$UPDATED_VERSION\",\"timeout\":$MAX_WAIT,\"timestamp\":$(date +%s)}"
exit 1

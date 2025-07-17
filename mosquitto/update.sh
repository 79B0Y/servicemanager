#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Mosquitto 更新脚本
# 版本: v1.0.1
# 功能: 升级 Mosquitto 到最新版本
# 修复: IPv4监听验证，MQTT上报时机控制
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

log "starting mosquitto update from $CURRENT_VERSION"

# 检查当前服务状态，如果运行中则可以上报MQTT
SERVICE_WAS_RUNNING=false
if bash "$SERVICE_DIR/status.sh" --quiet 2>/dev/null; then
    SERVICE_WAS_RUNNING=true
    log "service currently running, MQTT reporting available"
    
    mqtt_report "isg/update/$SERVICE_ID/status" \
        "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"starting update process\",\"timestamp\":$(date +%s)}" \
        2 2>/dev/null || log "MQTT initial report failed"
else
    log "service not running, will skip MQTT reporting until service is available"
fi

# -----------------------------------------------------------------------------
# 读取升级依赖配置
# -----------------------------------------------------------------------------
log "reading upgrade dependencies from serviceupdate.json"

if [ "$SERVICE_WAS_RUNNING" = true ]; then
    mqtt_report "isg/update/$SERVICE_ID/status" \
        "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"reading upgrade dependencies from serviceupdate.json\",\"timestamp\":$(date +%s)}" \
        1 2>/dev/null || true
fi

if [ ! -f "$SERVICEUPDATE_FILE" ]; then
    log "serviceupdate.json not found, using default upgrade dependencies"
    UPGRADE_DEPS='[]'
else
    UPGRADE_DEPS=$(get_upgrade_dependencies)
fi

# 转换为 bash 数组
DEPS_ARRAY=()
if [ "$UPGRADE_DEPS" != "[]" ] && [ "$UPGRADE_DEPS" != "null" ]; then
    while IFS= read -r dep; do
        DEPS_ARRAY+=("$dep")
    done < <(echo "$UPGRADE_DEPS" | jq -r '.[]' 2>/dev/null || true)
fi

if [ ${#DEPS_ARRAY[@]} -gt 0 ]; then
    log "installing upgrade dependencies: ${DEPS_ARRAY[*]}"
    
    if [ "$SERVICE_WAS_RUNNING" = true ]; then
        mqtt_report "isg/update/$SERVICE_ID/status" \
            "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"installing upgrade dependencies\",\"dependencies\":$UPGRADE_DEPS,\"timestamp\":$(date +%s)}" \
            1 2>/dev/null || true
    fi
    
    # 安装升级依赖
    for dep in "${DEPS_ARRAY[@]}"; do
        log "installing upgrade dependency: $dep"
        if ! pkg install -y "$dep"; then
            log "failed to install upgrade dependency: $dep"
            
            if [ "$SERVICE_WAS_RUNNING" = true ]; then
                mqtt_report "isg/update/$SERVICE_ID/status" \
                    "{\"status\":\"failed\",\"message\":\"upgrade dependencies installation failed\",\"dependency\":\"$dep\",\"current_version\":\"$CURRENT_VERSION\",\"timestamp\":$(date +%s)}" \
                    1 2>/dev/null || true
            fi
            
            record_update_history "FAILED" "$CURRENT_VERSION" "unknown" "upgrade dependencies installation failed"
            exit 1
        fi
    done
else
    log "no upgrade dependencies specified"
fi

# -----------------------------------------------------------------------------
# 备份当前配置
# -----------------------------------------------------------------------------
log "backing up current configuration"

if [ "$SERVICE_WAS_RUNNING" = true ]; then
    mqtt_report "isg/update/$SERVICE_ID/status" \
        "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"backing up current configuration\",\"timestamp\":$(date +%s)}" \
        1 2>/dev/null || true
fi

# 执行备份（只在服务运行时）
if [ "$SERVICE_WAS_RUNNING" = true ]; then
    bash "$SERVICE_DIR/backup.sh" || log "backup failed, continuing with update"
else
    log "service not running, skipping backup"
fi

# -----------------------------------------------------------------------------
# 检查配置更新需求
# -----------------------------------------------------------------------------
log "checking for configuration updates"

if [ "$SERVICE_WAS_RUNNING" = true ]; then
    mqtt_report "isg/update/$SERVICE_ID/status" \
        "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"checking configuration updates\",\"timestamp\":$(date +%s)}" \
        1 2>/dev/null || true
fi

CONFIG_NEEDS_UPDATE=false
if check_config_changes; then
    log "configuration changes detected, will update after service upgrade"
    CONFIG_NEEDS_UPDATE=true
fi

# -----------------------------------------------------------------------------
# 停止服务
# -----------------------------------------------------------------------------
log "stopping mosquitto before update"

if [ "$SERVICE_WAS_RUNNING" = true ]; then
    mqtt_report "isg/update/$SERVICE_ID/status" \
        "{\"status\":\"updating\",\"current_version\":\"$CURRENT_VERSION\",\"message\":\"stopping service\",\"timestamp\":$(date +%s)}" \
        1 2>/dev/null || true
fi

bash "$SERVICE_DIR/stop.sh"
sleep 5

# -----------------------------------------------------------------------------
# 更新包列表
# -----------------------------------------------------------------------------
log "updating package list"

if ! pkg update; then
    log "package list update failed"
    record_update_history "FAILED" "$CURRENT_VERSION" "unknown" "package list update failed"
    exit 1
fi

# -----------------------------------------------------------------------------
# 执行升级
# -----------------------------------------------------------------------------
log "upgrading mosquitto"

if ! pkg upgrade -y mosquitto; then
    log "mosquitto upgrade failed"
    record_update_history "FAILED" "$CURRENT_VERSION" "unknown" "mosquitto upgrade failed"
    exit 1
fi

# -----------------------------------------------------------------------------
# 版本校验
# -----------------------------------------------------------------------------
UPDATED_VERSION=$(get_current_version)

if [ "$UPDATED_VERSION" = "unknown" ]; then
    log "failed to get updated version"
    record_update_history "FAILED" "$CURRENT_VERSION" "unknown" "failed to get updated version"
    exit 1
fi

log "updated to version: $UPDATED_VERSION"

# -----------------------------------------------------------------------------
# 验证和修复配置文件（确保IPv4监听）
# -----------------------------------------------------------------------------
log "verifying configuration file and IPv4 listening support"

if [ -f "$MOSQUITTO_CONF_FILE" ]; then
    if ! mosquitto -c "$MOSQUITTO_CONF_FILE" -t 2>/dev/null; then
        log "configuration file validation failed, attempting to restore"
        bash "$SERVICE_DIR/restore.sh" || log "restore failed, generating new config"
    else
        # 检查IPv4监听配置
        if ! grep -q "listener.*1883.*0.0.0.0" "$MOSQUITTO_CONF_FILE" && 
           ! grep -q "port.*1883" "$MOSQUITTO_CONF_FILE"; then
            log "configuration lacks IPv4 listening, updating configuration"
            
            # 备份当前配置
            cp "$MOSQUITTO_CONF_FILE" "$MOSQUITTO_CONF_FILE.pre_update.$(date +%Y%m%d_%H%M%S)"
            
            # 重新生成配置以确保IPv4监听
            if generate_mosquitto_config_from_serviceupdate; then
                log "regenerated configuration with IPv4 listening support"
            else
                log_warn "failed to regenerate from serviceupdate, using restore"
                bash "$SERVICE_DIR/restore.sh" || log "restore also failed"
            fi
        fi
    fi
else
    log "configuration file not found, restoring from backup or generating new"
    bash "$SERVICE_DIR/restore.sh" || log "restore failed"
fi

# -----------------------------------------------------------------------------
# 应用配置更新（如果需要）
# -----------------------------------------------------------------------------
if [ "$CONFIG_NEEDS_UPDATE" = true ]; then
    log "applying detected configuration updates"
    
    if generate_mosquitto_config_from_serviceupdate; then
        log "applied configuration updates from serviceupdate.json"
    else
        log_warn "failed to apply configuration updates"
    fi
    
    if update_users_from_serviceupdate; then
        log "updated user configuration"
    else
        log_warn "failed to update user configuration"
    fi
    
    if sync_to_global_config; then
        log "synchronized global configuration"
    else
        log_warn "failed to sync global configuration"
    fi
fi

# -----------------------------------------------------------------------------
# 重启服务并健康检查IPv4监听
# -----------------------------------------------------------------------------
log "starting service and verifying IPv4 listening"

bash "$SERVICE_DIR/start.sh"

log "waiting for service ready with IPv4 listening verification"

MAX_WAIT=300
INTERVAL=5
WAITED=0
IPV4_LISTENING_VERIFIED=false

while [ "$WAITED" -lt "$MAX_WAIT" ]; do
    # 检查进程和IPv4监听
    if MOSQUITTO_PID=$(get_mosquitto_pid); then
        log_debug "mosquitto process found (PID: $MOSQUITTO_PID)"
        
        # 验证IPv4监听 - 关键检查
        if netstat -tulnp 2>/dev/null | grep -q "0.0.0.0:1883"; then
            log "SUCCESS: mosquitto listening on 0.0.0.0:1883 after ${WAITED}s"
            IPV4_LISTENING_VERIFIED=true
            
            # 验证WebSocket端口（可选）
            if netstat -tulnp 2>/dev/null | grep -q "0.0.0.0:9001"; then
                log "SUCCESS: mosquitto WebSocket listening on 0.0.0.0:9001"
            else
                log_warn "WebSocket port 9001 not listening on IPv4, but main port OK"
            fi
            
            break
        else
            log_debug "process exists but not listening on IPv4 yet (${WAITED}s)"
        fi
    else
        log_debug "waiting for mosquitto process (${WAITED}s)"
    fi
    
    sleep "$INTERVAL"
    WAITED=$((WAITED + INTERVAL))
done

# -----------------------------------------------------------------------------
# 验证更新结果
# -----------------------------------------------------------------------------
if [ "$IPV4_LISTENING_VERIFIED" = true ]; then
    DURATION=$(( $(date +%s) - START_TIME ))
    log "service is running with IPv4 listening verified after ${WAITED}s"
    
    # 记录更新历史
    log "recording update history"
    record_update_history "SUCCESS" "$CURRENT_VERSION" "$UPDATED_VERSION" ""
    
    # 现在服务运行正常，可以安全上报MQTT
    mqtt_report "isg/update/$SERVICE_ID/status" \
        "{\"service\":\"$SERVICE_ID\",\"status\":\"success\",\"old_version\":\"$CURRENT_VERSION\",\"new_version\":\"$UPDATED_VERSION\",\"duration\":$DURATION,\"ipv4_listening\":true,\"timestamp\":$(date +%s)}" \
        3 2>/dev/null || log "MQTT success report failed"
    
    # 更新版本文件
    echo "$UPDATED_VERSION" > "$VERSION_FILE"
    log "update completed successfully: $CURRENT_VERSION → $UPDATED_VERSION (IPv4 listening verified)"
    exit 0
else
    log "service failed to achieve IPv4 listening after ${MAX_WAIT}s"
    
    # 获取诊断信息
    log "=== UPDATE FAILURE DIAGNOSTIC ==="
    log "Mosquitto process status:"
    ps aux | grep mosquitto | grep -v grep >> "$LOG_FILE" || echo "No mosquitto processes found" >> "$LOG_FILE"
    
    log "Network listening status:"
    netstat -tulnp 2>/dev/null | grep -E "(1883|9001)" >> "$LOG_FILE" || echo "No mosquitto ports listening" >> "$LOG_FILE"
    
    log "Configuration file test:"
    mosquitto -c "$MOSQUITTO_CONF_FILE" -t >> "$LOG_FILE" 2>&1 || echo "Configuration test failed" >> "$LOG_FILE"
    
    record_update_history "FAILED" "$CURRENT_VERSION" "$UPDATED_VERSION" "service failed to achieve IPv4 listening"
    
    # 尝试上报失败状态（可能其他MQTT服务可用）
    (
        sleep 5
        mqtt_report "isg/update/$SERVICE_ID/status" \
            "{\"status\":\"failed\",\"message\":\"service failed to achieve IPv4 listening after update\",\"old_version\":\"$CURRENT_VERSION\",\"new_version\":\"$UPDATED_VERSION\",\"timeout\":$MAX_WAIT,\"ipv4_listening\":false,\"timestamp\":$(date +%s)}" \
            1 2>/dev/null || true
    ) &
    
    exit 1
fi
#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Mosquitto 自检脚本
# 版本: v1.1.1
# 功能: 单服务自检、性能监控、健康检查和环境变量驱动的配置管理
# 修复: IPv4监听验证，MQTT上报时机控制，修复缺失函数
# =============================================================================

set -euo pipefail

# 加载统一路径定义
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common_paths.sh" || {
    echo "Error: Cannot load common paths"
    exit 1
}

# 设置脚本特定的日志文件
LOG_FILE="$LOG_FILE_AUTOCHECK"

# 确保必要目录存在
ensure_directories

# -----------------------------------------------------------------------------
# 更新serviceupdate.json中的配置
# -----------------------------------------------------------------------------
update_serviceupdate_config() {
    local new_username="$1"
    local new_password="$2"
    
    if [ ! -f "$SERVICEUPDATE_FILE" ]; then
        log "serviceupdate.json not found, cannot update config"
        return 1
    fi
    
    log "updating serviceupdate.json config with new credentials"
    
    # 使用jq更新用户名和密码
    local temp_file=$(mktemp)
    jq "(.services[] | select(.id==\"$SERVICE_ID\") | .config.username) = \"$new_username\" | 
        (.services[] | select(.id==\"$SERVICE_ID\") | .config.password) = \"$new_password\"" \
        "$SERVICEUPDATE_FILE" > "$temp_file"
    
    if [ $? -eq 0 ]; then
        mv "$temp_file" "$SERVICEUPDATE_FILE"
        log "serviceupdate.json config updated successfully"
        return 0
    else
        rm -f "$temp_file"
        log "failed to update serviceupdate.json config"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# 环境变量驱动的配置更新流程
# -----------------------------------------------------------------------------
process_env_config_update() {
    local env_username="${MQTT_USERNAME:-}"
    local env_password="${MQTT_PASSWORD:-}"
    
    if [ -z "$env_username" ] && [ -z "$env_password" ]; then
        return 1  # 没有环境变量，跳过配置更新
    fi
    
    log "detected MQTT credentials in environment variables"
    
    # 只有在服务运行时才上报MQTT状态
    if bash "$SERVICE_DIR/status.sh" --quiet 2>/dev/null; then
        mqtt_report "isg/autocheck/$SERVICE_ID/status" \
            "{\"status\":\"config_updating\",\"message\":\"environment variables detected, updating configuration\",\"timestamp\":$(date +%s)}" \
            1 2>/dev/null || log "MQTT report failed during env config update start"
    fi
    
    # 使用默认值
    env_username="${env_username:-admin}"
    env_password="${env_password:-admin}"
    
    # 步骤1：更新serviceupdate.json中的config字段
    log "step 1: updating serviceupdate.json config"
    if update_serviceupdate_config "$env_username" "$env_password"; then
        log "serviceupdate.json updated successfully"
    else
        if bash "$SERVICE_DIR/status.sh" --quiet 2>/dev/null; then
            mqtt_report "isg/autocheck/$SERVICE_ID/status" \
                "{\"status\":\"config_failed\",\"message\":\"failed to update serviceupdate.json\",\"timestamp\":$(date +%s)}" \
                1 2>/dev/null || true
        fi
        return 1
    fi
    
    # 步骤2：对比serviceupdate配置与本地服务配置
    log "step 2: comparing serviceupdate config with local service config"
    if compare_serviceupdate_with_local_config; then
        log "local service config needs update"
        
        # 更新本地服务配置
        if generate_mosquitto_config_from_serviceupdate; then
            log "mosquitto.conf updated successfully"
        else
            if bash "$SERVICE_DIR/status.sh" --quiet 2>/dev/null; then
                mqtt_report "isg/autocheck/$SERVICE_ID/status" \
                    "{\"status\":\"config_failed\",\"message\":\"failed to update mosquitto.conf\",\"timestamp\":$(date +%s)}" \
                    1 2>/dev/null || true
            fi
            return 1
        fi
        
        if update_users_from_serviceupdate; then
            log "mqtt users updated successfully"
        else
            if bash "$SERVICE_DIR/status.sh" --quiet 2>/dev/null; then
                mqtt_report "isg/autocheck/$SERVICE_ID/status" \
                    "{\"status\":\"config_failed\",\"message\":\"failed to update mqtt users\",\"timestamp\":$(date +%s)}" \
                    1 2>/dev/null || true
            fi
            return 1
        fi
        
        # 验证配置
        if validate_config "$MOSQUITTO_CONF_FILE" "mosquitto"; then
            log "mosquitto configuration file is readable"
        else
            log "mosquitto configuration validation failed"
            if bash "$SERVICE_DIR/status.sh" --quiet 2>/dev/null; then
                mqtt_report "isg/autocheck/$SERVICE_ID/status" \
                    "{\"status\":\"config_failed\",\"message\":\"configuration validation failed\",\"timestamp\":$(date +%s)}" \
                    1 2>/dev/null || true
            fi
            return 1
        fi
        
        SERVICE_CONFIG_UPDATED=true
    else
        log "local service config is up to date"
        SERVICE_CONFIG_UPDATED=false
    fi
    
    # 步骤3：对比本地配置与configuration.yaml中的mqtt信息
    log "step 3: comparing local config with global configuration.yaml"
    if compare_local_with_global_config; then
        log "global configuration.yaml needs update"
        
        # 更新全局配置
        if sync_to_global_config; then
            log "configuration.yaml updated successfully"
            GLOBAL_CONFIG_UPDATED=true
        else
            if bash "$SERVICE_DIR/status.sh" --quiet 2>/dev/null; then
                mqtt_report "isg/autocheck/$SERVICE_ID/status" \
                    "{\"status\":\"config_failed\",\"message\":\"failed to update configuration.yaml\",\"timestamp\":$(date +%s)}" \
                    1 2>/dev/null || true
            fi
            return 1
        fi
    else
        log "global configuration.yaml is up to date"
        GLOBAL_CONFIG_UPDATED=false
    fi
    
    # 如果有配置更新，重启服务
    if [ "$SERVICE_CONFIG_UPDATED" = true ]; then
        log "restarting service to apply configuration changes"
        
        bash "$SERVICE_DIR/stop.sh"
        sleep 5
        bash "$SERVICE_DIR/start.sh"
        
        # 等待服务启动并验证IPv4监听
        local max_wait=60
        local waited=0
        local ipv4_verified=false
        
        while [ $waited -lt $max_wait ]; do
            if bash "$SERVICE_DIR/status.sh" --quiet 2>/dev/null; then
                # 验证IPv4监听
                if netstat -tulnp 2>/dev/null | grep -q "0.0.0.0:1883"; then
                    log "service restarted successfully with IPv4 listening"
                    ipv4_verified=true
                    break
                else
                    log_debug "service running but IPv4 not verified yet (${waited}s)"
                fi
            fi
            sleep 5
            waited=$((waited + 5))
        done
        
        if [ "$ipv4_verified" = false ]; then
            if bash "$SERVICE_DIR/status.sh" --quiet 2>/dev/null; then
                mqtt_report "isg/autocheck/$SERVICE_ID/status" \
                    "{\"status\":\"config_failed\",\"message\":\"service failed to restart with IPv4 listening after configuration update\",\"timestamp\":$(date +%s)}" \
                    1 2>/dev/null || true
            fi
            return 1
        fi
    fi
    
    # 成功完成配置更新，上报状态（如果服务运行中）
    if bash "$SERVICE_DIR/status.sh" --quiet 2>/dev/null; then
        mqtt_report "isg/autocheck/$SERVICE_ID/status" \
            "{\"status\":\"config_updated\",\"message\":\"configuration updated successfully from environment variables\",\"service_restarted\":$SERVICE_CONFIG_UPDATED,\"global_updated\":$GLOBAL_CONFIG_UPDATED,\"ipv4_listening\":true,\"timestamp\":$(date +%s)}" \
            2 2>/dev/null || log "MQTT final report failed"
    fi
    
    return 0
}

# -----------------------------------------------------------------------------
# 处理命令行参数 - App驱动的配置管理
# -----------------------------------------------------------------------------
case "${1:-}" in
    --check-config)
        log "checking configuration consistency (app triggered)"
        
        if bash "$SERVICE_DIR/status.sh" --quiet 2>/dev/null; then
            mqtt_report "isg/autocheck/$SERVICE_ID/status" \
                "{\"status\":\"config_checking\",\"message\":\"app triggered configuration check\",\"timestamp\":$(date +%s)}" \
                1 2>/dev/null || log "MQTT check report failed"
        fi
        
        if check_config_changes; then
            log "configuration inconsistency detected"
            if bash "$SERVICE_DIR/status.sh" --quiet 2>/dev/null; then
                mqtt_report "isg/autocheck/$SERVICE_ID/status" \
                    "{\"status\":\"config_inconsistent\",\"message\":\"configuration changes detected but not applied\",\"timestamp\":$(date +%s)}" \
                    1 2>/dev/null || true
            fi
            exit 1
        else
            log "configuration is consistent"
            if bash "$SERVICE_DIR/status.sh" --quiet 2>/dev/null; then
                mqtt_report "isg/autocheck/$SERVICE_ID/status" \
                    "{\"status\":\"config_consistent\",\"message\":\"configuration is up to date\",\"timestamp\":$(date +%s)}" \
                    1 2>/dev/null || true
            fi
            exit 0
        fi
        ;;
    --update-env-config)
        log "environment variable driven configuration update"
        if process_env_config_update; then
            exit 0
        else
            exit 1
        fi
        ;;
    --sync-config)
        log "force syncing configuration from serviceupdate.json"
        
        if bash "$SERVICE_DIR/status.sh" --quiet 2>/dev/null; then
            mqtt_report "isg/autocheck/$SERVICE_ID/status" \
                "{\"status\":\"config_syncing\",\"message\":\"force syncing configuration\",\"timestamp\":$(date +%s)}" \
                1 2>/dev/null || log "MQTT sync start report failed"
        fi
        
        if sync_to_global_config && generate_mosquitto_config_from_serviceupdate && update_users_from_serviceupdate; then
            log "configuration force synced successfully"
            if bash "$SERVICE_DIR/status.sh" --quiet 2>/dev/null; then
                mqtt_report "isg/autocheck/$SERVICE_ID/status" \
                    "{\"status\":\"config_synced\",\"message\":\"configuration force synced successfully\",\"timestamp\":$(date +%s)}" \
                    1 2>/dev/null || true
            fi
            exit 0
        else
            log "configuration force sync failed"
            if bash "$SERVICE_DIR/status.sh" --quiet 2>/dev/null; then
                mqtt_report "isg/autocheck/$SERVICE_ID/status" \
                    "{\"status\":\"config_failed\",\"message\":\"configuration force sync failed\",\"timestamp\":$(date +%s)}" \
                    1 2>/dev/null || true
            fi
            exit 1
        fi
        ;;
    --update-config)
        log "app triggered configuration update"
        
        if bash "$SERVICE_DIR/status.sh" --quiet 2>/dev/null; then
            mqtt_report "isg/autocheck/$SERVICE_ID/status" \
                "{\"status\":\"config_checking\",\"message\":\"app triggered configuration check\",\"timestamp\":$(date +%s)}" \
                1 2>/dev/null || log "MQTT update start report failed"
        fi
        
        if check_config_changes; then
            if bash "$SERVICE_DIR/status.sh" --quiet 2>/dev/null; then
                mqtt_report "isg/autocheck/$SERVICE_ID/status" \
                    "{\"status\":\"config_updating\",\"message\":\"configuration changes detected, starting sync\",\"timestamp\":$(date +%s)}" \
                    1 2>/dev/null || true
            fi
            
            # 执行配置同步
            local sync_success=true
            
            if ! generate_mosquitto_config_from_serviceupdate; then
                log "failed to update mosquitto.conf"
                sync_success=false
            fi
            
            if ! update_users_from_serviceupdate; then
                log "failed to update mqtt users"
                sync_success=false
            fi
            
            if ! sync_to_global_config; then
                log "failed to sync global configuration"
                sync_success=false
            fi
            
            if [ "$sync_success" = true ]; then
                # 验证配置
                if validate_config "$MOSQUITTO_CONF_FILE" "mosquitto"; then
                    log "configuration file is readable and basic checks passed"
                    
                    # 重启服务应用配置
                    bash "$SERVICE_DIR/stop.sh"
                    sleep 5
                    bash "$SERVICE_DIR/start.sh"
                    
                    # 等待服务启动并验证IPv4监听
                    local max_wait=60
                    local waited=0
                    local ipv4_verified=false
                    
                    while [ $waited -lt $max_wait ]; do
                        if bash "$SERVICE_DIR/status.sh" --quiet 2>/dev/null; then
                            if netstat -tulnp 2>/dev/null | grep -q "0.0.0.0:1883"; then
                                log "service restarted successfully with IPv4 listening after config update"
                                ipv4_verified=true
                                break
                            fi
                        fi
                        sleep 5
                        waited=$((waited + 5))
                    done
                    
                    if [ "$ipv4_verified" = true ]; then
                        mqtt_report "isg/autocheck/$SERVICE_ID/status" \
                            "{\"status\":\"config_updated\",\"message\":\"configuration synchronized successfully\",\"ipv4_listening\":true,\"timestamp\":$(date +%s)}" \
                            2 2>/dev/null || log "MQTT update success report failed"
                        exit 0
                    else
                        if bash "$SERVICE_DIR/status.sh" --quiet 2>/dev/null; then
                            mqtt_report "isg/autocheck/$SERVICE_ID/status" \
                                "{\"status\":\"config_failed\",\"message\":\"service failed to restart with IPv4 listening after config sync\",\"timestamp\":$(date +%s)}" \
                                1 2>/dev/null || true
                        fi
                        exit 1
                    fi
                else
                    log "configuration validation failed after sync"
                    if bash "$SERVICE_DIR/status.sh" --quiet 2>/dev/null; then
                        mqtt_report "isg/autocheck/$SERVICE_ID/status" \
                            "{\"status\":\"config_failed\",\"message\":\"configuration validation failed after sync\",\"timestamp\":$(date +%s)}" \
                            1 2>/dev/null || true
                    fi
                    exit 1
                fi
            else
                if bash "$SERVICE_DIR/status.sh" --quiet 2>/dev/null; then
                    mqtt_report "isg/autocheck/$SERVICE_ID/status" \
                        "{\"status\":\"config_failed\",\"message\":\"configuration sync failed\",\"timestamp\":$(date +%s)}" \
                        1 2>/dev/null || true
                fi
                exit 1
            fi
        else
            if bash "$SERVICE_DIR/status.sh" --quiet 2>/dev/null; then
                mqtt_report "isg/autocheck/$SERVICE_ID/status" \
                    "{\"status\":\"config_unchanged\",\"message\":\"no configuration changes detected\",\"timestamp\":$(date +%s)}" \
                    1 2>/dev/null || true
            fi
            exit 0
        fi
        ;;
    --help)
        echo "Mosquitto autocheck configuration management:"
        echo "  $0 --check-config       Check configuration consistency only"
        echo "  $0 --sync-config        Force sync configuration from serviceupdate.json"
        echo "  $0 --update-config      Detect and sync configuration changes (App triggered)"
        echo "  $0 --update-env-config  Update configuration from environment variables"
        echo "  $0                      Normal health check with optional env config update"
        echo ""
        echo "Environment variables for configuration update:"
        echo "  MQTT_USERNAME          New MQTT username"
        echo "  MQTT_PASSWORD          New MQTT password"
        echo ""
        echo "Environment variables for MQTT maintenance (optional):"
        echo "  MQTT_MAINTENANCE_ENABLED=1     Enable full MQTT maintenance"
        echo "  MQTT_MAINTENANCE_TYPE          Type: monitor|cleanup|optimize|full (default: monitor)"
        echo "  MQTT_CLEANUP_ENABLED=1         Enable only cleanup function"
        echo "  MQTT_CLEANUP_LEVEL             Level: normal|aggressive|emergency (default: normal)"
        echo "  MQTT_OPTIMIZE_ENABLED=1        Enable only optimization function"
        echo "  MQTT_OPTIMIZE_LEVEL            Level: normal|performance|memory (default: normal)"
        echo ""
        echo "Examples:"
        echo "  $0                                              # Basic health check only"
        echo "  MQTT_MAINTENANCE_ENABLED=1 $0                  # Health check + monitoring"
        echo "  MQTT_CLEANUP_ENABLED=1 MQTT_CLEANUP_LEVEL=aggressive $0  # With cleanup"
        echo "  MQTT_OPTIMIZE_ENABLED=1 MQTT_OPTIMIZE_LEVEL=memory $0     # With optimization"
        exit 0
        ;;
    *)
        # 执行正常的健康检查，并检查环境变量配置更新
        ;;
esac

RESULT_STATUS="healthy"
SERVICE_CONFIG_UPDATED=false
GLOBAL_CONFIG_UPDATED=false

# 创建锁文件，防止重复执行
exec 200>"$LOCK_FILE_AUTOCHECK"
flock -n 200 || exit 0

NOW=$(date +%s)

log "starting autocheck for $SERVICE_ID"

# 初始状态消息 - 只有在服务运行时才上报MQTT
if bash "$SERVICE_DIR/status.sh" --quiet 2>/dev/null; then
    mqtt_report "isg/autocheck/$SERVICE_ID/status" \
        "{\"status\":\"start\",\"run\":\"unknown\",\"config\":{},\"install\":\"checking\",\"current_version\":\"unknown\",\"latest_version\":\"unknown\",\"update\":\"checking\",\"message\":\"starting autocheck process\",\"timestamp\":$NOW}" \
        1 2>/dev/null || log "MQTT start report failed"
fi

# -----------------------------------------------------------------------------
# 检查环境变量驱动的配置更新（正常autocheck流程中）
# -----------------------------------------------------------------------------
if [ -n "${MQTT_USERNAME:-}" ] || [ -n "${MQTT_PASSWORD:-}" ]; then
    log "environment variables detected, processing configuration update"
    if process_env_config_update; then
        log "environment configuration update completed"
    else
        log "environment configuration update failed"
        RESULT_STATUS="problem"
    fi
fi

# -----------------------------------------------------------------------------
# 检查必要脚本是否存在
# -----------------------------------------------------------------------------
for script in start.sh stop.sh install.sh status.sh; do
    if [ ! -f "$SERVICE_DIR/$script" ]; then
        RESULT_STATUS="problem"
        if bash "$SERVICE_DIR/status.sh" --quiet 2>/dev/null; then
            mqtt_report "isg/autocheck/$SERVICE_ID/status" \
                "{\"status\":\"problem\",\"message\":\"missing $script\"}" \
                1 2>/dev/null || true
        fi
        exit 1
    fi
done

# -----------------------------------------------------------------------------
# 获取版本信息
# -----------------------------------------------------------------------------
MOSQUITTO_VERSION=$(get_current_version)
LATEST_MOSQUITTO_VERSION=$(get_latest_version)
SCRIPT_VERSION=$(get_script_version)
LATEST_SCRIPT_VERSION=$(get_latest_script_version)
UPGRADE_DEPS=$(get_upgrade_dependencies)

# -----------------------------------------------------------------------------
# 获取各脚本状态
# -----------------------------------------------------------------------------
RUN_STATUS=$(get_improved_run_status)
INSTALL_STATUS=$(get_improved_install_status)
BACKUP_STATUS=$(get_improved_backup_status)
UPDATE_STATUS=$(get_improved_update_status)
RESTORE_STATUS=$(get_improved_restore_status)
UPDATE_INFO=$(get_update_info)

log "status check results:"
log "  run: $RUN_STATUS"
log "  install: $INSTALL_STATUS"
log "  backup: $BACKUP_STATUS"
log "  update: $UPDATE_STATUS"
log "  restore: $RESTORE_STATUS"

# -----------------------------------------------------------------------------
# 检查是否被禁用
# -----------------------------------------------------------------------------
if [ -f "$DISABLED_FLAG" ]; then
    CONFIG_INFO=$(get_config_info)
    
    # 服务被禁用时，不上报MQTT（因为服务不运行）
    log "service is disabled"
    RESULT_STATUS="disabled"
    exit 0
fi

# -----------------------------------------------------------------------------
# 检查服务状态并尝试恢复
# -----------------------------------------------------------------------------
if [ "$RUN_STATUS" = "stopped" ]; then
    log "mosquitto not running, attempting to start"
    for i in $(seq 1 $MAX_TRIES); do
        bash "$SERVICE_DIR/start.sh"
        sleep $RETRY_INTERVAL
        NEW_RUN_STATUS=$(get_improved_run_status)
        if [ "$NEW_RUN_STATUS" = "running" ]; then
            log "service recovered on attempt $i"
            
            # 验证IPv4监听
            if netstat -tulnp 2>/dev/null | grep -q "0.0.0.0:1883"; then
                log "service recovered with IPv4 listening verified"
                mqtt_report "isg/autocheck/$SERVICE_ID/status" \
                    "{\"status\":\"recovered\",\"message\":\"service recovered after restart attempts\",\"ipv4_listening\":true,\"timestamp\":$(date +%s)}" \
                    2 2>/dev/null || log "MQTT recovery report failed"
            else
                log "service recovered but IPv4 listening not verified"
                mqtt_report "isg/autocheck/$SERVICE_ID/status" \
                    "{\"status\":\"recovered\",\"message\":\"service recovered but IPv4 listening issue\",\"ipv4_listening\":false,\"timestamp\":$(date +%s)}" \
                    2 2>/dev/null || log "MQTT recovery report failed"
                RESULT_STATUS="problem"
            fi
            
            RUN_STATUS="running"
            break
        fi
        [ $i -eq $MAX_TRIES ] && {
            RESULT_STATUS="problem"
            RUN_STATUS="failed"
        }
    done
fi

# -----------------------------------------------------------------------------
# 检查服务重启情况
# -----------------------------------------------------------------------------
MOSQUITTO_PID=$(get_mosquitto_pid || echo "")
if [ -n "$MOSQUITTO_PID" ]; then
    MOSQUITTO_UPTIME=$(ps -o etimes= -p "$MOSQUITTO_PID" 2>/dev/null | head -n1 | awk '{print $1}' || echo 0)
    # 确保是数字，移除任何非数字字符
    MOSQUITTO_UPTIME=$(echo "$MOSQUITTO_UPTIME" | tr -d '\n\r\t ' | grep -o '^[0-9]*' || echo 0)
    MOSQUITTO_UPTIME=${MOSQUITTO_UPTIME:-0}
else
    MOSQUITTO_UPTIME=0
fi

LAST_CHECK=$(cat "$LAST_CHECK_FILE" 2>/dev/null | head -n1 | tr -d '\n\r\t ' || echo 0)
# 确保LAST_CHECK是数字
LAST_CHECK=${LAST_CHECK:-0}

if [ "$LAST_CHECK" -gt 0 ] && [ "$MOSQUITTO_UPTIME" -lt $((NOW - LAST_CHECK)) ]; then
    RESULT_STATUS="problem"
fi
echo "$NOW" > "$LAST_CHECK_FILE"

# -----------------------------------------------------------------------------
# 性能监控 - 只有在服务运行时上报
# -----------------------------------------------------------------------------
if [ -n "$MOSQUITTO_PID" ]; then
    # 安全获取CPU和内存使用率
    CPU=$(top -b -n 1 -p "$MOSQUITTO_PID" 2>/dev/null | awk '/'"$MOSQUITTO_PID"'/ {if($9 != "") print $9; else print "0.0"}' | head -n1 || echo "0.0")
    MEM=$(top -b -n 1 -p "$MOSQUITTO_PID" 2>/dev/null | awk '/'"$MOSQUITTO_PID"'/ {if($10 != "") print $10; else print "0.0"}' | head -n1 || echo "0.0")
    
    # 确保是数字，如果不是则设为默认值
    CPU=${CPU:-0.0}
    MEM=${MEM:-0.0}
    
    # 验证是否为有效数字
    if ! [[ "$CPU" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        CPU="0.0"
    fi
    if ! [[ "$MEM" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        MEM="0.0"
    fi
    
    # 只有在服务运行时上报性能数据
    if [ "$RUN_STATUS" = "running" ]; then
        mqtt_report "isg/autocheck/$SERVICE_ID/performance" \
            "{\"cpu\":\"$CPU\",\"mem\":\"$MEM\",\"timestamp\":$NOW}" \
            1 2>/dev/null || log "MQTT performance report failed"
        mqtt_report "isg/status/$SERVICE_ID/performance" \
            "{\"cpu\":\"$CPU\",\"mem\":\"$MEM\",\"timestamp\":$NOW}" \
            1 2>/dev/null || log "MQTT status performance report failed"
    fi
else
    CPU="0.0"
    MEM="0.0"
fi

# -----------------------------------------------------------------------------
# 版本信息上报 - 只有在服务运行时上报
# -----------------------------------------------------------------------------
log "script_version: $SCRIPT_VERSION"
log "latest_script_version: $LATEST_SCRIPT_VERSION"
log "mosquitto_version: $MOSQUITTO_VERSION"
log "latest_mosquitto_version: $LATEST_MOSQUITTO_VERSION"
log "upgrade_dependencies: $UPGRADE_DEPS"
log "install_status: $INSTALL_STATUS"
log "run_status: $RUN_STATUS"
log "update_info: $UPDATE_INFO"

if [ "$RUN_STATUS" = "running" ]; then
    mqtt_report "isg/autocheck/$SERVICE_ID/version" \
        "{\"script_version\":\"$SCRIPT_VERSION\",\"latest_script_version\":\"$LATEST_SCRIPT_VERSION\",\"mosquitto_version\":\"$MOSQUITTO_VERSION\",\"latest_mosquitto_version\":\"$LATEST_MOSQUITTO_VERSION\",\"upgrade_dependencies\":$UPGRADE_DEPS}" \
        1 2>/dev/null || log "MQTT version report failed"
fi

# -----------------------------------------------------------------------------
# 检查端口监听状态（重点检查IPv4）
# -----------------------------------------------------------------------------
PORT_LISTENING=false
WS_PORT_LISTENING=false
IPV4_LISTENING=false

# 检查IPv4监听 - 关键检查
if netstat -tulnp 2>/dev/null | grep -q "0.0.0.0:1883"; then
    PORT_LISTENING=true
    IPV4_LISTENING=true
elif netstat -tulnp 2>/dev/null | grep -q ":1883"; then
    PORT_LISTENING=true  # 监听但非全局IPv4
    IPV4_LISTENING=false
fi

if netstat -tulnp 2>/dev/null | grep -q "0.0.0.0:9001"; then
    WS_PORT_LISTENING=true
elif netstat -tulnp 2>/dev/null | grep -q ":9001"; then
    WS_PORT_LISTENING=true  # 监听但可能非全局IPv4
fi

# 如果进程存在但IPv4监听有问题，标记为问题状态
if [ -n "$MOSQUITTO_PID" ] && [ "$IPV4_LISTENING" = false ]; then
    RESULT_STATUS="problem"
    log "mosquitto process exists but not listening on IPv4 0.0.0.0:1883"
fi

# -----------------------------------------------------------------------------
# 检查配置文件有效性（适配Mosquitto 2.0.22）
# -----------------------------------------------------------------------------
CONFIG_VALID=true
if [ -f "$MOSQUITTO_CONF_FILE" ]; then
    if ! validate_config "$MOSQUITTO_CONF_FILE" "mosquitto"; then
        CONFIG_VALID=false
        RESULT_STATUS="problem"
        log "configuration file validation failed"
    fi
else
    CONFIG_VALID=false
    RESULT_STATUS="problem"
    log "configuration file not found"
fi

# -----------------------------------------------------------------------------
# 获取配置信息和状态消息
# -----------------------------------------------------------------------------
CONFIG_INFO=$(get_config_info 2>/dev/null)
STATUS_MESSAGE=$(generate_status_message "$RUN_STATUS")

# -----------------------------------------------------------------------------
# 生成最终的综合状态消息 - 只有在服务运行时上报
# -----------------------------------------------------------------------------
log "autocheck complete with IPv4 listening status: $IPV4_LISTENING"

if [ "$RUN_STATUS" = "running" ] || [ "$RUN_STATUS" = "starting" ]; then
    # 构建最终状态消息
    FINAL_MESSAGE="{"
    FINAL_MESSAGE="$FINAL_MESSAGE\"status\":\"$RESULT_STATUS\","
    FINAL_MESSAGE="$FINAL_MESSAGE\"run\":\"$RUN_STATUS\","
    FINAL_MESSAGE="$FINAL_MESSAGE\"config\":$CONFIG_INFO,"
    FINAL_MESSAGE="$FINAL_MESSAGE\"install\":\"$INSTALL_STATUS\","
    FINAL_MESSAGE="$FINAL_MESSAGE\"backup\":\"$BACKUP_STATUS\","
    FINAL_MESSAGE="$FINAL_MESSAGE\"restore\":\"$RESTORE_STATUS\","
    FINAL_MESSAGE="$FINAL_MESSAGE\"update\":\"$UPDATE_STATUS\","
    FINAL_MESSAGE="$FINAL_MESSAGE\"current_version\":\"$MOSQUITTO_VERSION\","
    FINAL_MESSAGE="$FINAL_MESSAGE\"latest_version\":\"$LATEST_MOSQUITTO_VERSION\","
    FINAL_MESSAGE="$FINAL_MESSAGE\"update_info\":\"$UPDATE_INFO\","
    FINAL_MESSAGE="$FINAL_MESSAGE\"message\":\"$STATUS_MESSAGE\","
    FINAL_MESSAGE="$FINAL_MESSAGE\"port_listening\":$PORT_LISTENING,"
    FINAL_MESSAGE="$FINAL_MESSAGE\"ws_port_listening\":$WS_PORT_LISTENING,"
    FINAL_MESSAGE="$FINAL_MESSAGE\"ipv4_listening\":$IPV4_LISTENING,"
    FINAL_MESSAGE="$FINAL_MESSAGE\"config_valid\":$CONFIG_VALID,"
    FINAL_MESSAGE="$FINAL_MESSAGE\"timestamp\":$NOW"
    FINAL_MESSAGE="$FINAL_MESSAGE}"

    mqtt_report "isg/autocheck/$SERVICE_ID/status" "$FINAL_MESSAGE" \
        2 2>/dev/null || log "MQTT final status report failed"
else
    log "service not running, skipping MQTT status report"
fi

# -----------------------------------------------------------------------------
# MQTT Broker 消息清理和优化（如果启用）
# -----------------------------------------------------------------------------

# 检查是否启用MQTT维护功能
if [ -n "${MQTT_MAINTENANCE_ENABLED:-}" ]; then
    log "MQTT maintenance enabled via environment variable"
    
    # 确定维护类型
    local maintenance_type="${MQTT_MAINTENANCE_TYPE:-monitor}"
    local cleanup_level="${MQTT_CLEANUP_LEVEL:-normal}"
    local optimize_level="${MQTT_OPTIMIZE_LEVEL:-normal}"
    
    log "Performing MQTT broker maintenance (type: $maintenance_type)"
    
    case "$maintenance_type" in
        "monitor")
            monitor_mqtt_load 2>/dev/null || log "MQTT load monitoring failed"
            ;;
        "cleanup")
            cleanup_mqtt_persistence "$cleanup_level" 2>/dev/null || log "MQTT cleanup failed"
            ;;
        "optimize")
            optimize_mqtt_config "$optimize_level" 2>/dev/null || log "MQTT optimization failed"
            ;;
        "full")
            monitor_mqtt_load 2>/dev/null || log "MQTT load monitoring failed"
            cleanup_mqtt_persistence "$cleanup_level" 2>/dev/null || log "MQTT cleanup failed"
            optimize_mqtt_config "$optimize_level" 2>/dev/null || log "MQTT optimization failed"
            ;;
        *)
            log_warn "Unknown MQTT maintenance type: $maintenance_type, using monitor"
            monitor_mqtt_load 2>/dev/null || log "MQTT load monitoring failed"
            ;;
    esac
    
    log "MQTT broker maintenance completed"
elif [ -n "${MQTT_CLEANUP_ENABLED:-}" ]; then
    # 只启用清理功能
    log "MQTT cleanup enabled via environment variable"
    local cleanup_level="${MQTT_CLEANUP_LEVEL:-normal}"
    cleanup_mqtt_persistence "$cleanup_level" 2>/dev/null || log "MQTT cleanup failed"
elif [ -n "${MQTT_OPTIMIZE_ENABLED:-}" ]; then
    # 只启用优化功能
    log "MQTT optimization enabled via environment variable"
    local optimize_level="${MQTT_OPTIMIZE_LEVEL:-normal}"
    optimize_mqtt_config "$optimize_level" 2>/dev/null || log "MQTT optimization failed"
else
    log_debug "MQTT maintenance not enabled (no environment variables set)"
fi

# -----------------------------------------------------------------------------
# 清理日志文件
# -----------------------------------------------------------------------------
trim_log() {
    tail -n 500 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
}

trim_log
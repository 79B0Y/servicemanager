#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Mosquitto 自检脚本
# 版本: v1.1.0
# 功能: 单服务自检、性能监控、健康检查和环境变量驱动的配置管理
# 更新: 修复缺失函数、增强错误处理、保持原有简洁设计
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
    mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"status\":\"config_updating\",\"message\":\"environment variables detected, updating configuration\",\"timestamp\":$(date +%s)}"
    
    # 使用默认值
    env_username="${env_username:-admin}"
    env_password="${env_password:-admin}"
    
    # 步骤1：更新serviceupdate.json中的config字段
    log "step 1: updating serviceupdate.json config"
    if update_serviceupdate_config "$env_username" "$env_password"; then
        log "serviceupdate.json updated successfully"
    else
        mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"status\":\"config_failed\",\"message\":\"failed to update serviceupdate.json\",\"timestamp\":$(date +%s)}"
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
            mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"status\":\"config_failed\",\"message\":\"failed to update mosquitto.conf\",\"timestamp\":$(date +%s)}"
            return 1
        fi
        
        if update_users_from_serviceupdate; then
            log "mqtt users updated successfully"
        else
            mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"status\":\"config_failed\",\"message\":\"failed to update mqtt users\",\"timestamp\":$(date +%s)}"
            return 1
        fi
        
        # 验证配置
        if mosquitto -c "$MOSQUITTO_CONF_FILE" -t; then
            log "mosquitto configuration validated"
        else
            log "mosquitto configuration validation failed"
            mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"status\":\"config_failed\",\"message\":\"configuration validation failed\",\"timestamp\":$(date +%s)}"
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
            mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"status\":\"config_failed\",\"message\":\"failed to update configuration.yaml\",\"timestamp\":$(date +%s)}"
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
        
        # 等待服务启动
        local max_wait=60
        local waited=0
        while [ $waited -lt $max_wait ]; do
            if bash "$SERVICE_DIR/status.sh" --quiet; then
                log "service restarted successfully"
                break
            fi
            sleep 5
            waited=$((waited + 5))
        done
        
        if [ $waited -ge $max_wait ]; then
            mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"status\":\"config_failed\",\"message\":\"service failed to restart after configuration update\",\"timestamp\":$(date +%s)}"
            return 1
        fi
    fi
    
    mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"status\":\"config_updated\",\"message\":\"configuration updated successfully from environment variables\",\"service_restarted\":$SERVICE_CONFIG_UPDATED,\"global_updated\":$GLOBAL_CONFIG_UPDATED,\"timestamp\":$(date +%s)}"
    return 0
}

# -----------------------------------------------------------------------------
# 处理命令行参数 - App驱动的配置管理
# -----------------------------------------------------------------------------
case "${1:-}" in
    --check-config)
        log "checking configuration consistency (app triggered)"
        mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"status\":\"config_checking\",\"message\":\"app triggered configuration check\",\"timestamp\":$(date +%s)}"
        
        if check_config_changes; then
            log "configuration inconsistency detected"
            mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"status\":\"config_inconsistent\",\"message\":\"configuration changes detected but not applied\",\"timestamp\":$(date +%s)}"
            exit 1
        else
            log "configuration is consistent"
            mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"status\":\"config_consistent\",\"message\":\"configuration is up to date\",\"timestamp\":$(date +%s)}"
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
        mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"status\":\"config_syncing\",\"message\":\"force syncing configuration\",\"timestamp\":$(date +%s)}"
        
        if sync_to_global_config && generate_mosquitto_config_from_serviceupdate && update_users_from_serviceupdate; then
            log "configuration force synced successfully"
            mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"status\":\"config_synced\",\"message\":\"configuration force synced successfully\",\"timestamp\":$(date +%s)}"
            exit 0
        else
            log "configuration force sync failed"
            mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"status\":\"config_failed\",\"message\":\"configuration force sync failed\",\"timestamp\":$(date +%s)}"
            exit 1
        fi
        ;;
    --update-config)
        log "app triggered configuration update"
        mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"status\":\"config_checking\",\"message\":\"app triggered configuration check\",\"timestamp\":$(date +%s)}"
        
        if check_config_changes; then
            mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"status\":\"config_updating\",\"message\":\"configuration changes detected, starting sync\",\"timestamp\":$(date +%s)}"
            
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
                if mosquitto -c "$MOSQUITTO_CONF_FILE" -t; then
                    log "configuration validation passed"
                    
                    # 重启服务应用配置
                    bash "$SERVICE_DIR/stop.sh"
                    sleep 5
                    bash "$SERVICE_DIR/start.sh"
                    
                    # 等待服务启动
                    local max_wait=60
                    local waited=0
                    while [ $waited -lt $max_wait ]; do
                        if bash "$SERVICE_DIR/status.sh" --quiet; then
                            log "service restarted successfully after config update"
                            break
                        fi
                        sleep 5
                        waited=$((waited + 5))
                    done
                    
                    if [ $waited -ge $max_wait ]; then
                        mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"status\":\"config_failed\",\"message\":\"service failed to restart after config sync\",\"timestamp\":$(date +%s)}"
                        exit 1
                    fi
                    
                    mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"status\":\"config_updated\",\"message\":\"configuration synchronized successfully\",\"timestamp\":$(date +%s)}"
                    exit 0
                else
                    log "configuration validation failed after sync"
                    mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"status\":\"config_failed\",\"message\":\"configuration validation failed after sync\",\"timestamp\":$(date +%s)}"
                    exit 1
                fi
            else
                mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"status\":\"config_failed\",\"message\":\"configuration sync failed\",\"timestamp\":$(date +%s)}"
                exit 1
            fi
        else
            mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"status\":\"config_unchanged\",\"message\":\"no configuration changes detected\",\"timestamp\":$(date +%s)}"
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
mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"status\":\"start\",\"run\":\"unknown\",\"config\":{},\"install\":\"checking\",\"current_version\":\"unknown\",\"latest_version\":\"unknown\",\"update\":\"checking\",\"message\":\"starting autocheck process\",\"timestamp\":$NOW}"

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
        mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"status\":\"problem\",\"message\":\"missing $script\"}"
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
    mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"status\":\"disabled\",\"run\":\"disabled\",\"config\":$CONFIG_INFO,\"install\":\"$INSTALL_STATUS\",\"backup\":\"$BACKUP_STATUS\",\"restore\":\"$RESTORE_STATUS\",\"update\":\"$UPDATE_STATUS\",\"current_version\":\"$MOSQUITTO_VERSION\",\"latest_version\":\"$LATEST_MOSQUITTO_VERSION\",\"update_info\":\"$UPDATE_INFO\",\"message\":\"service is disabled\",\"timestamp\":$NOW}"
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
            mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"status\":\"recovered\",\"message\":\"service recovered after restart attempts\",\"timestamp\":$(date +%s)}"
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
# 性能监控
# -----------------------------------------------------------------------------
if [ -n "$MOSQUITTO_PID" ]; then
    CPU=$(top -b -n 1 -p "$MOSQUITTO_PID" 2>/dev/null | awk '/'"$MOSQUITTO_PID"'/ {print $9}' | head -n1)
    MEM=$(top -b -n 1 -p "$MOSQUITTO_PID" 2>/dev/null | awk '/'"$MOSQUITTO_PID"'/ {print $10}' | head -n1)
    # 确保是数字
    CPU=${CPU:-0.0}
    MEM=${MEM:-0.0}
else
    CPU="0.0"
    MEM="0.0"
fi

mqtt_report "isg/autocheck/$SERVICE_ID/performance" "{\"cpu\":\"$CPU\",\"mem\":\"$MEM\",\"timestamp\":$NOW}"
mqtt_report "isg/status/$SERVICE_ID/performance" "{\"cpu\":\"$CPU\",\"mem\":\"$MEM\",\"timestamp\":$NOW}"

# -----------------------------------------------------------------------------
# 版本信息上报
# -----------------------------------------------------------------------------
log "script_version: $SCRIPT_VERSION"
log "latest_script_version: $LATEST_SCRIPT_VERSION"
log "mosquitto_version: $MOSQUITTO_VERSION"
log "latest_mosquitto_version: $LATEST_MOSQUITTO_VERSION"
log "upgrade_dependencies: $UPGRADE_DEPS"
log "install_status: $INSTALL_STATUS"
log "run_status: $RUN_STATUS"
log "update_info: $UPDATE_INFO"

mqtt_report "isg/autocheck/$SERVICE_ID/version" "{\"script_version\":\"$SCRIPT_VERSION\",\"latest_script_version\":\"$LATEST_SCRIPT_VERSION\",\"mosquitto_version\":\"$MOSQUITTO_VERSION\",\"latest_mosquitto_version\":\"$LATEST_MOSQUITTO_VERSION\",\"upgrade_dependencies\":$UPGRADE_DEPS}"

# -----------------------------------------------------------------------------
# 检查端口监听状态
# -----------------------------------------------------------------------------
PORT_LISTENING=false
WS_PORT_LISTENING=false

if check_port_listening "$MOSQUITTO_PORT"; then
    PORT_LISTENING=true
fi

if check_port_listening "$MOSQUITTO_WS_PORT"; then
    WS_PORT_LISTENING=true
fi

if [ -n "$MOSQUITTO_PID" ] && [ "$PORT_LISTENING" = false ]; then
    RESULT_STATUS="problem"
fi

# -----------------------------------------------------------------------------
# 检查配置文件有效性
# -----------------------------------------------------------------------------
CONFIG_VALID=true
if [ -f "$MOSQUITTO_CONF_FILE" ]; then
    if ! mosquitto -c "$MOSQUITTO_CONF_FILE" -t 2>/dev/null; then
        CONFIG_VALID=false
        RESULT_STATUS="problem"
    fi
fi

# -----------------------------------------------------------------------------
# 获取配置信息和状态消息
# -----------------------------------------------------------------------------
CONFIG_INFO=$(get_config_info 2>/dev/null)
STATUS_MESSAGE=$(generate_status_message "$RUN_STATUS")

# -----------------------------------------------------------------------------
# 生成最终的综合状态消息
# -----------------------------------------------------------------------------
log "autocheck complete"

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
FINAL_MESSAGE="$FINAL_MESSAGE\"config_valid\":$CONFIG_VALID,"
FINAL_MESSAGE="$FINAL_MESSAGE\"timestamp\":$NOW"
FINAL_MESSAGE="$FINAL_MESSAGE}"

mqtt_report "isg/autocheck/$SERVICE_ID/status" "$FINAL_MESSAGE"

# -----------------------------------------------------------------------------
# MQTT Broker 消息清理和优化
# -----------------------------------------------------------------------------

# 获取MQTT broker存储使用情况
get_mqtt_storage_usage() {
    local persistence_dir="$TERMUX_VAR_DIR/lib/mosquitto"
    local storage_info="{}"
    
    if [ -d "$persistence_dir" ]; then
        local total_size_kb=$(du -sk "$persistence_dir" 2>/dev/null | cut -f1 || echo "0")
        local file_count=$(find "$persistence_dir" -type f 2>/dev/null | wc -l || echo "0")
        local db_files=$(find "$persistence_dir" -name "*.db" -type f 2>/dev/null | wc -l || echo "0")
        
        # 获取最大和最旧的文件信息
        local largest_file=""
        local oldest_file=""
        local largest_size=0
        local oldest_date=""
        
        if [ "$file_count" -gt 0 ]; then
            # 查找最大文件
            while IFS= read -r file; do
                if [ -f "$file" ]; then
                    local size=$(du -k "$file" 2>/dev/null | cut -f1 || echo "0")
                    if [ "$size" -gt "$largest_size" ]; then
                        largest_size="$size"
                        largest_file="$(basename "$file")"
                    fi
                fi
            done < <(find "$persistence_dir" -type f 2>/dev/null)
            
            # 查找最旧文件
            oldest_file=$(find "$persistence_dir" -type f -printf '%T+ %p\n' 2>/dev/null | sort | head -1 | cut -d' ' -f2- | xargs basename 2>/dev/null || echo "")
            if [ -n "$oldest_file" ]; then
                oldest_date=$(stat -c %Y "$persistence_dir/$oldest_file" 2>/dev/null || echo "0")
            fi
        fi
        
        storage_info=$(cat << EOF
{
    "total_size_kb": $total_size_kb,
    "file_count": $file_count,
    "db_files": $db_files,
    "largest_file": "$largest_file",
    "largest_size_kb": $largest_size,
    "oldest_file": "$oldest_file",
    "oldest_date": $oldest_date,
    "path": "$persistence_dir"
}
EOF
        )
    else
        storage_info='{"error": "persistence directory not found"}'
    fi
    
    echo "$storage_info"
}

# 分析MQTT消息负载
analyze_mqtt_load() {
    local log_file="$MOSQUITTO_LOG_DIR/mosquitto.log"
    local analysis="{}"
    
    if [ -f "$log_file" ]; then
        # 分析最近10分钟的日志
        local recent_log=$(tail -1000 "$log_file" 2>/dev/null | tail -500)
        
        # 统计不同类型的消息
        local connections=$(echo "$recent_log" | grep -c "New connection" 2>/dev/null || echo "0")
        local disconnections=$(echo "$recent_log" | grep -c "disconnected" 2>/dev/null || echo "0")
        local publishes=$(echo "$recent_log" | grep -c "PUBLISH" 2>/dev/null || echo "0")
        local subscribes=$(echo "$recent_log" | grep -c "SUBSCRIBE" 2>/dev/null || echo "0")
        local errors=$(echo "$recent_log" | grep -ci "error" 2>/dev/null || echo "0")
        local warnings=$(echo "$recent_log" | grep -ci "warning" 2>/dev/null || echo "0")
        
        # 检测高频客户端
        local top_clients=$(echo "$recent_log" | grep -o "Client [a-zA-Z0-9_-]*" | sort | uniq -c | sort -nr | head -5 | while read count client; do
            echo "\"$client\": $count"
        done | paste -sd,)
        
        # 检测高频主题模式
        local topic_patterns=$(echo "$recent_log" | grep -o "on topic [^[:space:]]*" | cut -d' ' -f3 | cut -d'/' -f1-2 | sort | uniq -c | sort -nr | head -5 | while read count pattern; do
            echo "\"$pattern/*\": $count"
        done | paste -sd,)
        
        analysis=$(cat << EOF
{
    "timestamp": $(date +%s),
    "period_minutes": 10,
    "connections": $connections,
    "disconnections": $disconnections,
    "publishes": $publishes,
    "subscribes": $subscribes,
    "errors": $errors,
    "warnings": $warnings,
    "top_clients": {$top_clients},
    "topic_patterns": {$topic_patterns},
    "net_connections": $((connections - disconnections))
}
EOF
        )
    else
        analysis='{"error": "log file not found"}'
    fi
    
    echo "$analysis"
}

# 清理MQTT broker持久化数据
cleanup_mqtt_persistence() {
    local cleanup_level="${1:-normal}"  # normal, aggressive, emergency
    local persistence_dir="$TERMUX_VAR_DIR/lib/mosquitto"
    local cleaned_size=0
    local cleaned_files=0
    
    if [ ! -d "$persistence_dir" ]; then
        log "MQTT persistence directory not found, skipping cleanup"
        return 0
    fi
    
    log "Starting MQTT persistence cleanup (level: $cleanup_level)"
    
    # 获取清理前的大小
    local before_size=$(du -sk "$persistence_dir" 2>/dev/null | cut -f1 || echo "0")
    
    case "$cleanup_level" in
        "normal")
            # 清理7天前的数据
            local old_files=$(find "$persistence_dir" -name "*.db" -mtime +7 2>/dev/null)
            if [ -n "$old_files" ]; then
                echo "$old_files" | while read -r file; do
                    if [ -f "$file" ]; then
                        local size=$(du -k "$file" 2>/dev/null | cut -f1 || echo "0")
                        rm -f "$file"
                        cleaned_size=$((cleaned_size + size))
                        cleaned_files=$((cleaned_files + 1))
                        log_debug "Removed old persistence file: $(basename "$file") (${size}KB)"
                    fi
                done
            fi
            ;;
            
        "aggressive")
            # 清理3天前的数据和大文件
            local old_files=$(find "$persistence_dir" -name "*.db" -mtime +3 2>/dev/null)
            local large_files=$(find "$persistence_dir" -name "*.db" -size +10M 2>/dev/null)
            
            for file in $old_files $large_files; do
                if [ -f "$file" ]; then
                    local size=$(du -k "$file" 2>/dev/null | cut -f1 || echo "0")
                    rm -f "$file"
                    cleaned_size=$((cleaned_size + size))
                    cleaned_files=$((cleaned_files + 1))
                    log "Removed persistence file: $(basename "$file") (${size}KB)"
                fi
            done
            ;;
            
        "emergency")
            # 清理所有持久化数据（保留配置）
            log_warn "Emergency cleanup: removing all MQTT persistence data"
            
            # 备份当前持久化数据
            local backup_file="$BACKUP_DIR/mqtt_persistence_emergency_$(date +%Y%m%d_%H%M%S).tar.gz"
            if tar -czf "$backup_file" -C "$(dirname "$persistence_dir")" "$(basename "$persistence_dir")" 2>/dev/null; then
                log "Emergency backup created: $(basename "$backup_file")"
            fi
            
            # 清理所有.db文件
            find "$persistence_dir" -name "*.db" -type f -delete 2>/dev/null || true
            cleaned_files=$(find "$persistence_dir" -name "*.db" 2>/dev/null | wc -l || echo "0")
            ;;
    esac
    
    # 获取清理后的大小
    local after_size=$(du -sk "$persistence_dir" 2>/dev/null | cut -f1 || echo "0")
    cleaned_size=$((before_size - after_size))
    
    log "MQTT persistence cleanup completed: ${cleaned_files} files, ${cleaned_size}KB freed"
    
    # 上报清理结果
    mqtt_report "isg/maintenance/$SERVICE_ID/mqtt_cleanup" \
        "{\"level\":\"$cleanup_level\",\"files_removed\":$cleaned_files,\"size_freed_kb\":$cleaned_size,\"before_size_kb\":$before_size,\"after_size_kb\":$after_size,\"timestamp\":$(date +%s)}"
    
    return 0
}

# 优化MQTT broker配置
optimize_mqtt_config() {
    local optimization_level="${1:-normal}"  # normal, performance, memory
    local config_changed=false
    
    if [ ! -f "$MOSQUITTO_CONF_FILE" ]; then
        log_error "Mosquitto config file not found, cannot optimize"
        return 1
    fi
    
    log "Starting MQTT configuration optimization (level: $optimization_level)"
    
    # 备份当前配置
    cp "$MOSQUITTO_CONF_FILE" "$MOSQUITTO_CONF_FILE.backup.$(date +%Y%m%d_%H%M%S)"
    
    case "$optimization_level" in
        "normal")
            # 基础优化：调整连接和消息限制
            if ! grep -q "max_connections" "$MOSQUITTO_CONF_FILE"; then
                echo "max_connections 100" >> "$MOSQUITTO_CONF_FILE"
                config_changed=true
            fi
            
            if ! grep -q "max_inflight_messages" "$MOSQUITTO_CONF_FILE"; then
                echo "max_inflight_messages 20" >> "$MOSQUITTO_CONF_FILE"
                config_changed=true
            fi
            
            if ! grep -q "max_queued_messages" "$MOSQUITTO_CONF_FILE"; then
                echo "max_queued_messages 100" >> "$MOSQUITTO_CONF_FILE"
                config_changed=true
            fi
            ;;
            
        "performance")
            # 性能优化：增加限制，优化吞吐量
            sed -i 's/max_connections .*/max_connections 200/' "$MOSQUITTO_CONF_FILE"
            sed -i 's/max_inflight_messages .*/max_inflight_messages 50/' "$MOSQUITTO_CONF_FILE"
            sed -i 's/max_queued_messages .*/max_queued_messages 1000/' "$MOSQUITTO_CONF_FILE"
            
            # 添加性能相关配置
            if ! grep -q "message_size_limit" "$MOSQUITTO_CONF_FILE"; then
                echo "message_size_limit 1048576" >> "$MOSQUITTO_CONF_FILE"  # 1MB
                config_changed=true
            fi
            
            if ! grep -q "sys_interval" "$MOSQUITTO_CONF_FILE"; then
                echo "sys_interval 30" >> "$MOSQUITTO_CONF_FILE"
                config_changed=true
            fi
            ;;
            
        "memory")
            # 内存优化：降低限制，减少内存使用
            sed -i 's/max_connections .*/max_connections 50/' "$MOSQUITTO_CONF_FILE"
            sed -i 's/max_inflight_messages .*/max_inflight_messages 10/' "$MOSQUITTO_CONF_FILE"
            sed -i 's/max_queued_messages .*/max_queued_messages 50/' "$MOSQUITTO_CONF_FILE"
            
            # 添加内存优化配置
            if ! grep -q "persistent_client_expiration" "$MOSQUITTO_CONF_FILE"; then
                echo "persistent_client_expiration 1m" >> "$MOSQUITTO_CONF_FILE"
                config_changed=true
            fi
            
            # 禁用某些功能以节省内存
            if ! grep -q "allow_zero_length_clientid" "$MOSQUITTO_CONF_FILE"; then
                echo "allow_zero_length_clientid false" >> "$MOSQUITTO_CONF_FILE"
                config_changed=true
            fi
            ;;
    esac
    
    if [ "$config_changed" = true ]; then
        # 验证配置
        if mosquitto -c "$MOSQUITTO_CONF_FILE" -t 2>/dev/null; then
            log "MQTT configuration optimized and validated (level: $optimization_level)"
            return 0
        else
            log_error "Optimized configuration validation failed, restoring backup"
            # 恢复备份
            local backup_file="$MOSQUITTO_CONF_FILE.backup.$(date +%Y%m%d_%H%M%S)"
            if [ -f "$backup_file" ]; then
                cp "$backup_file" "$MOSQUITTO_CONF_FILE"
            fi
            return 1
        fi
    else
        log "MQTT configuration already optimized"
        return 0
    fi
}

# 监控和告警MQTT负载
monitor_mqtt_load() {
    local storage_info=$(get_mqtt_storage_usage)
    local load_info=$(analyze_mqtt_load)
    
    # 提取关键指标
    local total_size_kb=$(echo "$storage_info" | jq -r '.total_size_kb // 0')
    local file_count=$(echo "$storage_info" | jq -r '.file_count // 0')
    local publishes=$(echo "$load_info" | jq -r '.publishes // 0')
    local errors=$(echo "$load_info" | jq -r '.errors // 0')
    local warnings=$(echo "$load_info" | jq -r '.warnings // 0')
    
    # 定义告警阈值
    local size_warning_mb=100
    local size_critical_mb=500
    local error_warning=5
    local error_critical=20
    local publish_warning=1000
    local publish_critical=5000
    
    local size_mb=$((total_size_kb / 1024))
    local alert_level="normal"
    local alert_messages=()
    
    # 检查存储使用
    if [ "$size_mb" -gt $size_critical_mb ]; then
        alert_level="critical"
        alert_messages+=("CRITICAL: MQTT storage usage ${size_mb}MB exceeds ${size_critical_mb}MB")
        # 自动执行紧急清理
        cleanup_mqtt_persistence "emergency"
    elif [ "$size_mb" -gt $size_warning_mb ]; then
        alert_level="warning"
        alert_messages+=("WARNING: MQTT storage usage ${size_mb}MB exceeds ${size_warning_mb}MB")
        # 自动执行常规清理
        cleanup_mqtt_persistence "normal"
    fi
    
    # 检查错误率
    if [ "$errors" -gt $error_critical ]; then
        alert_level="critical"
        alert_messages+=("CRITICAL: High MQTT error count: $errors")
    elif [ "$errors" -gt $error_warning ]; then
        if [ "$alert_level" != "critical" ]; then
            alert_level="warning"
        fi
        alert_messages+=("WARNING: Elevated MQTT error count: $errors")
    fi
    
    # 检查发布频率
    if [ "$publishes" -gt $publish_critical ]; then
        alert_level="critical"
        alert_messages+=("CRITICAL: Very high MQTT publish rate: $publishes/10min")
    elif [ "$publishes" -gt $publish_warning ]; then
        if [ "$alert_level" != "critical" ]; then
            alert_level="warning"
        fi
        alert_messages+=("WARNING: High MQTT publish rate: $publishes/10min")
    fi
    
    # 发送告警
    if [ "$alert_level" != "normal" ]; then
        local alert_message=$(IFS='; '; echo "${alert_messages[*]}")
        log_warn "MQTT Load Alert ($alert_level): $alert_message"
        
        mqtt_report "isg/alert/$SERVICE_ID/mqtt_load" \
            "{\"level\":\"$alert_level\",\"message\":\"$alert_message\",\"storage_mb\":$size_mb,\"errors\":$errors,\"publishes\":$publishes,\"timestamp\":$(date +%s)}"
        
        # 自动优化配置
        if [ "$alert_level" = "critical" ]; then
            optimize_mqtt_config "memory"
        fi
    fi
    
    # 上报监控数据
    mqtt_report "isg/monitor/$SERVICE_ID/mqtt_metrics" \
        "{\"storage\":$storage_info,\"load\":$load_info,\"alert_level\":\"$alert_level\",\"timestamp\":$(date +%s)}"
    
    log_debug "MQTT load monitoring completed: $alert_level level"
}

# MQTT broker维护主函数
maintain_mqtt_broker() {
    local maintenance_type="${1:-monitor}"  # monitor, cleanup, optimize, full
    
    log "Starting MQTT broker maintenance (type: $maintenance_type)"
    
    case "$maintenance_type" in
        "monitor")
            monitor_mqtt_load
            ;;
        "cleanup")
            cleanup_mqtt_persistence "normal"
            ;;
        "optimize")
            optimize_mqtt_config "normal"
            ;;
        "full")
            monitor_mqtt_load
            cleanup_mqtt_persistence "normal"
            optimize_mqtt_config "normal"
            ;;
        *)
            log_error "Unknown MQTT maintenance type: $maintenance_type"
            return 1
            ;;
    esac
    
    log "MQTT broker maintenance completed (type: $maintenance_type)"
}

# -----------------------------------------------------------------------------
# 清理日志文件
# -----------------------------------------------------------------------------
trim_log() {
    tail -n 500 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
}

# -----------------------------------------------------------------------------
# 在主要autocheck流程中集成MQTT维护（仅在环境变量启用时）
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
            monitor_mqtt_load
            ;;
        "cleanup")
            cleanup_mqtt_persistence "$cleanup_level"
            ;;
        "optimize")
            optimize_mqtt_config "$optimize_level"
            ;;
        "full")
            monitor_mqtt_load
            cleanup_mqtt_persistence "$cleanup_level"
            optimize_mqtt_config "$optimize_level"
            ;;
        *)
            log_warn "Unknown MQTT maintenance type: $maintenance_type, using monitor"
            monitor_mqtt_load
            ;;
    esac
    
    log "MQTT broker maintenance completed"
elif [ -n "${MQTT_CLEANUP_ENABLED:-}" ]; then
    # 只启用清理功能
    log "MQTT cleanup enabled via environment variable"
    local cleanup_level="${MQTT_CLEANUP_LEVEL:-normal}"
    cleanup_mqtt_persistence "$cleanup_level"
elif [ -n "${MQTT_OPTIMIZE_ENABLED:-}" ]; then
    # 只启用优化功能
    log "MQTT optimization enabled via environment variable"
    local optimize_level="${MQTT_OPTIMIZE_LEVEL:-normal}"
    optimize_mqtt_config "$optimize_level"
else
    log_debug "MQTT maintenance not enabled (no environment variables set)"
fi

trim_log
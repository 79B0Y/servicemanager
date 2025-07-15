#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Home Assistant 还原脚本
# 版本: v1.4.0
# 功能: 还原备份文件或生成默认配置
# =============================================================================

set -euo pipefail

# 加载统一路径定义
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common_paths.sh" || {
    echo "Error: Cannot load common paths"
    exit 1
}

# 设置脚本特定的日志文件
LOG_FILE="$LOG_FILE_RESTORE"

# 确保必要目录存在
ensure_directories

# 确保配置目录存在
proot-distro login "$PROOT_DISTRO" -- mkdir -p "$HA_CONFIG_DIR"

START_TIME=$(date +%s)
CUSTOM_BACKUP_FILE="${RESTORE_FILE:-}"

# -----------------------------------------------------------------------------
# 生成默认配置文件
# -----------------------------------------------------------------------------
generate_default_config() {
    log "generating default Home Assistant configuration"
    
    # 获取 MQTT 配置
    load_mqtt_conf
    
    # 生成基础配置文件
    proot-distro login "$PROOT_DISTRO" -- bash -c "cat > $HA_CONFIG_DIR/configuration.yaml << 'EOF'
# Loads default set of integrations. Do not remove.
default_config:

# Load frontend themes from the themes folder
frontend:
  themes: !include_dir_merge_named themes

# Text to speech
tts:
  - platform: google_translate

automation: !include automations.yaml
script: !include scripts.yaml
scene: !include scenes.yaml

# HTTP configuration
http:
  use_x_frame_options: false

# Logger configuration
logger:
  default: warning
  logs:
    homeassistant.core: info

# Time zone configuration
homeassistant:
  name: Home
  latitude: !secret latitude
  longitude: !secret longitude
  elevation: !secret elevation
  unit_system: metric
  time_zone: !secret time_zone
  currency: CNY
  country: CN
EOF"

    # 创建 secrets.yaml 文件
    proot-distro login "$PROOT_DISTRO" -- bash -c "cat > $HA_CONFIG_DIR/secrets.yaml << 'EOF'
# Use this file to store secrets like usernames and passwords.
# Learn more at https://www.home-assistant.io/docs/configuration/secrets/
latitude: 39.9042
longitude: 116.4074
elevation: 43
time_zone: Asia/Shanghai
EOF"

    # 创建空的自动化文件
    proot-distro login "$PROOT_DISTRO" -- bash -c "
        echo '[]' > $HA_CONFIG_DIR/automations.yaml
        echo '{}' > $HA_CONFIG_DIR/scripts.yaml
        echo '[]' > $HA_CONFIG_DIR/scenes.yaml
    "

    log "default configuration generated successfully"
}

# -----------------------------------------------------------------------------
# 确定恢复文件
# -----------------------------------------------------------------------------
if [ -n "$CUSTOM_BACKUP_FILE" ]; then
    RESTORE_FILE="$CUSTOM_BACKUP_FILE"
    if [ -f "$RESTORE_FILE" ]; then
        log "using user specified file: $RESTORE_FILE"
        METHOD="user_specified"
    else
        log "user specified file not found: $RESTORE_FILE"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"user specified file not found\",\"file\":\"$RESTORE_FILE\",\"timestamp\":$(date +%s)}"
        exit 1
    fi
else
    RESTORE_FILE=$(ls -1t "$BACKUP_DIR"/homeassistant_backup_*.tar.gz 2>/dev/null | head -n1 || true)
    if [ -n "$RESTORE_FILE" ] && [ -f "$RESTORE_FILE" ]; then
        log "using latest backup: $RESTORE_FILE"
        METHOD="latest_backup"
    else
        RESTORE_FILE=""
        METHOD="default_config"
    fi
fi

#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Home Assistant 还原脚本
# 版本: v1.4.1
# 功能: 智能还原备份文件或生成默认配置
# 优化: 增加智能判断逻辑
# =============================================================================

set -euo pipefail

# 加载统一路径定义
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common_paths.sh" || {
    echo "Error: Cannot load common paths"
    exit 1
}

# 设置脚本特定的日志文件
LOG_FILE="$LOG_FILE_RESTORE"

# 确保必要目录存在
ensure_directories

# 确保配置目录存在
proot-distro login "$PROOT_DISTRO" -- mkdir -p "$HA_CONFIG_DIR"

START_TIME=$(date +%s)
CUSTOM_BACKUP_FILE="${RESTORE_FILE:-}"
ORIGINAL_BACKUP_FILE="$BACKUP_DIR/homeassistant_original.tar.gz"

# -----------------------------------------------------------------------------
# 生成默认配置文件
# -----------------------------------------------------------------------------
generate_default_config() {
    log "generating default Home Assistant configuration"
    
    # 获取 MQTT 配置
    load_mqtt_conf
    
    # 生成基础配置文件
    proot-distro login "$PROOT_DISTRO" -- bash -c "cat > $HA_CONFIG_DIR/configuration.yaml << 'EOF'
# Loads default set of integrations. Do not remove.
default_config:

# Load frontend themes from the themes folder
frontend:
  themes: !include_dir_merge_named themes

# Text to speech
tts:
  - platform: google_translate

automation: !include automations.yaml
script: !include scripts.yaml
scene: !include scenes.yaml

# HTTP configuration
http:
  use_x_frame_options: false

# Logger configuration
logger:
  default: warning
  logs:
    homeassistant.core: info

# Time zone configuration
homeassistant:
  name: Home
  latitude: !secret latitude
  longitude: !secret longitude
  elevation: !secret elevation
  unit_system: metric
  time_zone: !secret time_zone
  currency: CNY
  country: CN
EOF"

    # 创建 secrets.yaml 文件
    proot-distro login "$PROOT_DISTRO" -- bash -c "cat > $HA_CONFIG_DIR/secrets.yaml << 'EOF'
# Use this file to store secrets like usernames and passwords.
# Learn more at https://www.home-assistant.io/docs/configuration/secrets/
latitude: 39.9042
longitude: 116.4074
elevation: 43
time_zone: Asia/Shanghai
EOF"

    # 创建空的自动化文件
    proot-distro login "$PROOT_DISTRO" -- bash -c "
        echo '[]' > $HA_CONFIG_DIR/automations.yaml
        echo '{}' > $HA_CONFIG_DIR/scripts.yaml
        echo '[]' > $HA_CONFIG_DIR/scenes.yaml
    "

    log "default configuration generated successfully"
}

# -----------------------------------------------------------------------------
# 检查 Home Assistant 运行状态
# -----------------------------------------------------------------------------
check_ha_status() {
    if bash "$SERVICE_DIR/status.sh" --quiet 2>/dev/null; then
        echo "running"
    else
        echo "stopped"
    fi
}

# -----------------------------------------------------------------------------
# 创建当前状态的备份
# -----------------------------------------------------------------------------
create_backup_before_restore() {
    log "creating backup of current Home Assistant configuration"
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"restoring\",\"message\":\"creating backup before restore\",\"timestamp\":$(date +%s)}"
    
    local backup_file="$BACKUP_DIR/homeassistant_before_restore_$(date +%Y%m%d-%H%M%S).tar.gz"
    
    if proot-distro login "$PROOT_DISTRO" -- bash -c "tar -czf \"$backup_file\" -C \"$(dirname $HA_CONFIG_DIR)\" \"$(basename $HA_CONFIG_DIR)\""; then
        log "backup created: $(basename "$backup_file")"
        return 0
    else
        log "warning: failed to create backup before restore"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# 执行还原操作
# -----------------------------------------------------------------------------
perform_restore() {
    local restore_file="$1"
    local method="$2"
    
    log "performing restore from: $restore_file"
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"restoring\",\"method\":\"$method\",\"file\":\"$(basename "$restore_file")\"}"
    
    # 检查文件格式并处理
    local basename=$(basename -- "$restore_file")
    local ext="${basename##*.}"
    local ext_lower=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
    local final_restore_file="$restore_file"
    local converted_from_zip=false
    
    # 如果是zip文件，需要转换为tar.gz格式
    if [[ "$ext_lower" == "zip" ]]; then
        log "detected zip file, converting to tar.gz"
        
        local temp_dir="$RESTORE_TEMP_DIR"
        local converted_file="$BACKUP_DIR/homeassistant_converted_$(date +%Y%m%d-%H%M%S).tar.gz"
        
        # 创建临时目录并解压
        rm -rf "$temp_dir" && mkdir -p "$temp_dir"
        if ! unzip -q "$restore_file" -d "$temp_dir"; then
            log "failed to extract zip file"
            mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"failed to extract zip file\",\"timestamp\":$(date +%s)}"
            return 1
        fi
        
        # 查找解压后的配置目录
        local config_dir_in_zip=""
        if [ -d "$temp_dir/.homeassistant" ]; then
            config_dir_in_zip=".homeassistant"
        elif [ -f "$temp_dir/configuration.yaml" ]; then
            # 如果直接是配置文件，创建.homeassistant目录结构
            mkdir -p "$temp_dir/.homeassistant"
            mv "$temp_dir"/*.* "$temp_dir/.homeassistant/" 2>/dev/null || true
            config_dir_in_zip=".homeassistant"
        else
            # 查找包含configuration.yaml的目录
            config_dir_in_zip=$(find "$temp_dir" -name "configuration.yaml" -type f | head -n1 | xargs dirname | sed "s|$temp_dir/||")
        fi
        
        if [ -z "$config_dir_in_zip" ]; then
            log "no valid Home Assistant config found in zip file"
            mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"invalid zip structure\",\"timestamp\":$(date +%s)}"
            rm -rf "$temp_dir"
            return 1
        fi
        
        # 创建标准的tar.gz格式
        if tar -czf "$converted_file" -C "$temp_dir" "$config_dir_in_zip"; then
            final_restore_file="$converted_file"
            converted_from_zip=true
            log "converted zip to: $(basename "$converted_file")"
        else
            log "failed to create tar.gz from zip"
            mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"failed to create tar.gz from zip\",\"timestamp\":$(date +%s)}"
            rm -rf "$temp_dir"
            return 1
        fi
        
        # 清理临时目录
        rm -rf "$temp_dir"
    fi
    
    # 执行还原
    if proot-distro login "$PROOT_DISTRO" -- bash -c "rm -rf \"$HA_CONFIG_DIR\" && mkdir -p \"$HA_CONFIG_DIR\" && tar -xzf \"$final_restore_file\" -C \"$(dirname $HA_CONFIG_DIR)\""; then
        log "restore completed successfully"
        
        # 启动服务
        bash "$SERVICE_DIR/start.sh"
        sleep 30
        
        # 验证服务状态
        if bash "$SERVICE_DIR/status.sh" --quiet; then
            local end_time=$(date +%s)
            local duration=$((end_time - START_TIME))
            local size_kb=$(du -k "$final_restore_file" | awk '{print $1}')
            
            # 构建成功消息
            if [ "$converted_from_zip" = true ]; then
                mqtt_report "isg/restore/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"success\",\"method\":\"$method\",\"original_file\":\"$(basename "$restore_file")\",\"restore_file\":\"$(basename "$final_restore_file")\",\"size_kb\":$size_kb,\"duration\":$duration,\"converted_from_zip\":true,\"timestamp\":$end_time}"
                log "restore completed: $(basename "$final_restore_file") ($size_kb KB, ${duration}s)"
                log "converted from: $(basename "$restore_file")"
            else
                mqtt_report "isg/restore/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"success\",\"method\":\"$method\",\"file\":\"$(basename "$final_restore_file")\",\"size_kb\":$size_kb,\"duration\":$duration,\"timestamp\":$end_time}"
                log "restore completed: $(basename "$final_restore_file") ($size_kb KB, ${duration}s)"
            fi
            return 0
        else
            log "restore succeeded but service did not start"
            mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"service failed to start after restore\",\"method\":\"$method\",\"timestamp\":$(date +%s)}"
            return 1
        fi
    else
        log "restore failed inside proot container"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"restore failed inside proot container\",\"timestamp\":$(date +%s)}"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# 主要逻辑开始
# -----------------------------------------------------------------------------
log "starting intelligent Home Assistant restore process"

# 获取当前 HA 运行状态
HA_STATUS=$(check_ha_status)
log "current Home Assistant status: $HA_STATUS"

# 场景1: 用户指定了备份文件
if [ -n "$CUSTOM_BACKUP_FILE" ]; then
    log "scenario 1: user specified backup file"
    
    if [ -f "$CUSTOM_BACKUP_FILE" ]; then
        log "using user specified file: $CUSTOM_BACKUP_FILE"
        
        # 如果HA正在运行，先创建备份，然后停止服务
        if [ "$HA_STATUS" = "running" ]; then
            create_backup_before_restore
            bash "$SERVICE_DIR/stop.sh"
            sleep 5
        fi
        
        # 执行还原
        if perform_restore "$CUSTOM_BACKUP_FILE" "user_specified"; then
            exit 0
        else
            exit 1
        fi
    else
        log "user specified file not found: $CUSTOM_BACKUP_FILE"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"user specified file not found\",\"file\":\"$CUSTOM_BACKUP_FILE\",\"timestamp\":$(date +%s)}"
        exit 1
    fi
fi

# 场景2: HA正在运行，没有指定备份文件
if [ "$HA_STATUS" = "running" ]; then
    log "scenario 2: Home Assistant is running, no backup file specified"
    
    # 检查是否有最新备份文件
    LATEST_BACKUP=$(ls -1t "$BACKUP_DIR"/homeassistant_backup_*.tar.gz 2>/dev/null | head -n1 || true)
    
    if [ -n "$LATEST_BACKUP" ] && [ -f "$LATEST_BACKUP" ]; then
        log "found existing backup files, creating new backup and skipping restore"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"skipped\",\"message\":\"service running and backups exist - created new backup\",\"timestamp\":$(date +%s)}"
        
        # 创建当前状态的备份
        if bash "$SERVICE_DIR/backup.sh"; then
            log "backup created successfully, restore operation skipped"
        else
            log "backup creation failed"
            mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"backup creation failed\",\"timestamp\":$(date +%s)}"
            exit 1
        fi
    else
        log "no existing backups found, creating initial backup and skipping restore"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"skipped\",\"message\":\"service running - created initial backup\",\"timestamp\":$(date +%s)}"
        
        # 创建初始备份
        if bash "$SERVICE_DIR/backup.sh"; then
            log "initial backup created successfully, restore operation skipped"
        else
            log "initial backup creation failed"
            mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"initial backup creation failed\",\"timestamp\":$(date +%s)}"
            exit 1
        fi
    fi
    exit 0
fi

# 场景3: HA已停止，没有指定备份文件
log "scenario 3: Home Assistant is stopped, no backup file specified"

# 优先级1: 查找最新的常规备份
LATEST_BACKUP=$(ls -1t "$BACKUP_DIR"/homeassistant_backup_*.tar.gz 2>/dev/null | head -n1 || true)

if [ -n "$LATEST_BACKUP" ] && [ -f "$LATEST_BACKUP" ]; then
    log "found latest backup file: $LATEST_BACKUP"
    if perform_restore "$LATEST_BACKUP" "latest_backup"; then
        exit 0
    else
        log "latest backup restore failed, trying original backup"
    fi
fi

# 优先级2: 查找 homeassistant_original.tar.gz
if [ -f "$ORIGINAL_BACKUP_FILE" ]; then
    log "found original backup file: $ORIGINAL_BACKUP_FILE"
    if perform_restore "$ORIGINAL_BACKUP_FILE" "original_backup"; then
        exit 0
    else
        log "original backup restore failed, generating default config"
    fi
else
    log "original backup file not found: $ORIGINAL_BACKUP_FILE"
fi

# 优先级3: 生成默认配置
log "no backup files available, generating default configuration"
mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"restoring\",\"method\":\"default_config\",\"timestamp\":$(date +%s)}"

# 生成默认配置
generate_default_config

# 启动服务验证配置
bash "$SERVICE_DIR/start.sh"

# 等待并验证服务状态
MAX_WAIT=180
INTERVAL=5
WAITED=0
log "waiting for Home Assistant to start with new configuration"

while [ "$WAITED" -lt "$MAX_WAIT" ]; do
    if bash "$SERVICE_DIR/status.sh" --quiet; then
        log "service is running with new configuration after ${WAITED}s"
        break
    fi
    sleep "$INTERVAL"
    WAITED=$((WAITED + INTERVAL))
done

# 最终状态验证和上报
if bash "$SERVICE_DIR/status.sh" --quiet; then
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"success\",\"method\":\"default_config\",\"duration\":$DURATION,\"startup_time\":$WAITED,\"timestamp\":$END_TIME}"
    log "default configuration generated and service started successfully in ${DURATION}s (startup: ${WAITED}s)"
else
    log "service failed to start with new configuration after ${MAX_WAIT}s"
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"service failed to start after config generation\",\"method\":\"default_config\",\"timestamp\":$(date +%s)}"
    exit 1
fi

exit 0

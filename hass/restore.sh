#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Home Assistant 还原脚本 - 优化版本
# 版本: v1.5.0
# 功能: 智能还原备份文件或生成默认配置
# 优化: 1. 移除"HA运行+存在备份"的跳过逻辑 2. 不依赖common_paths.sh
# =============================================================================

set -euo pipefail

# =============================================================================
# 独立路径配置
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
LOG_FILE="$LOG_DIR/restore.log"
TEMP_DIR="/data/data/com.termux/files/usr/tmp"

# 备份相关
BACKUP_DIR="${BACKUP_DIR:-/sdcard/isgbackup/$SERVICE_ID}"
KEEP_BACKUPS="${KEEP_BACKUPS:-3}"
INSTALL_HISTORY_FILE="$BACKUP_DIR/.install_history"
UPDATE_HISTORY_FILE="$BACKUP_DIR/.update_history"

# 容器相关
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
PROOT_ROOTFS="/data/data/com.termux/files/usr/var/lib/proot-distro/installed-rootfs/$PROOT_DISTRO"
HA_VENV_DIR="/root/homeassistant"
HA_CONFIG_DIR="/root/.homeassistant"

# 服务参数
MAX_WAIT="${MAX_WAIT:-300}"
INTERVAL="${INTERVAL:-5}"

# =============================================================================
# 独立工具函数
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

# 检查 Home Assistant 运行状态
check_ha_status() {
    if bash "$SERVICE_DIR/status.sh" --quiet 2>/dev/null; then
        echo "running"
    else
        echo "stopped"
    fi
}

# 创建当前状态的备份
create_backup_before_restore() {
    log "creating backup of current Home Assistant configuration"
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"restoring\",\"message\":\"creating backup before restore\",\"timestamp\":$(date +%s)}"
    
    local backup_file="$BACKUP_DIR/homeassistant_before_restore_$(date +%Y%m%d-%H%M%S).tar.gz"
    local temp_backup="/tmp/backup_temp_$(date +%s).tar.gz"
    local container_backup="$PROOT_ROOTFS$temp_backup"
    
    # 在容器内创建备份到临时位置
    if proot-distro login "$PROOT_DISTRO" -- bash -c "tar -czf '$temp_backup' -C '/root' '.homeassistant'"; then
        # 移动到最终位置
        mv "$container_backup" "$backup_file"
        log "backup created: $(basename "$backup_file")"
        return 0
    else
        log "warning: failed to create backup before restore"
        return 1
    fi
}

# 生成默认配置文件
generate_default_config() {
    log "generating default Home Assistant configuration"
    
    # 确保配置目录存在
    proot-distro login "$PROOT_DISTRO" -- mkdir -p "$HA_CONFIG_DIR"
    
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

# Homeassistant configuration
homeassistant:
  name: Home
  latitude: 39.9042
  longitude: 116.4074
  elevation: 43
  unit_system: metric
  time_zone: Asia/Shanghai
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

# 执行还原操作
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
        
        local temp_dir="$TEMP_DIR/restore_temp_$(date +%s)"
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
        
    elif [[ "$basename" != *.tar.gz ]]; then
        log "unsupported file format: $ext"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"unsupported file format. only .tar.gz and .zip are supported\",\"file\":\"$basename\",\"timestamp\":$(date +%s)}"
        return 1
    fi
    
    # 将备份文件复制到容器内可访问位置
    local container_restore="/tmp/restore_$(date +%s).tar.gz"
    local container_restore_host="$PROOT_ROOTFS$container_restore"
    
    log "copying backup file to container"
    cp "$final_restore_file" "$container_restore_host"
    
    # 执行还原
    if proot-distro login "$PROOT_DISTRO" -- bash -c "
        set -e
        echo 'Removing old configuration'
        rm -rf '$HA_CONFIG_DIR'
        echo 'Creating configuration directory'
        mkdir -p '$HA_CONFIG_DIR'
        echo 'Extracting backup'
        tar -xzf '$container_restore' -C '/root'
        echo 'Cleaning up temporary file'
        rm -f '$container_restore'
        echo 'Restore extraction completed'
    "; then
        log "restore extraction completed successfully"
        
        # 启动服务
        log "starting Home Assistant service"
        bash "$SERVICE_DIR/start.sh"
        
        # 等待服务启动
        local waited=0
        while [ "$waited" -lt "$MAX_WAIT" ]; do
            if bash "$SERVICE_DIR/status.sh" --quiet; then
                break
            fi
            sleep "$INTERVAL"
            waited=$((waited + INTERVAL))
        done
        
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
            log "restore succeeded but service failed to start"
            mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"service failed to start after restore\",\"method\":\"$method\",\"timestamp\":$(date +%s)}"
            return 1
        fi
    else
        log "restore failed during extraction"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"restore failed during extraction\",\"timestamp\":$(date +%s)}"
        # 清理容器内的临时文件
        proot-distro login "$PROOT_DISTRO" -- rm -f "$container_restore" 2>/dev/null || true
        return 1
    fi
}

# =============================================================================
# 主程序开始
# =============================================================================

START_TIME=$(date +%s)
CUSTOM_BACKUP_FILE="${RESTORE_FILE:-}"

# 初始化
ensure_directories

log "starting Home Assistant restore process"

# 获取当前 HA 运行状态
HA_STATUS=$(check_ha_status)
log "current Home Assistant status: $HA_STATUS"

# =============================================================================
# 场景1: 用户指定了备份文件
# =============================================================================
if [ -n "$CUSTOM_BACKUP_FILE" ]; then
    log "scenario: user specified backup file"
    
    if [ -f "$CUSTOM_BACKUP_FILE" ]; then
        log "using user specified file: $CUSTOM_BACKUP_FILE"
        
        # 如果HA正在运行，先创建备份，然后停止服务
        if [ "$HA_STATUS" = "running" ]; then
            log "Home Assistant is running, creating backup before restore"
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

# =============================================================================
# 场景2: 自动查找备份文件进行还原
# =============================================================================
log "scenario: automatic backup search and restore"

# 如果HA正在运行，先停止服务并创建备份
if [ "$HA_STATUS" = "running" ]; then
    log "Home Assistant is running, will stop service for restore"
    create_backup_before_restore
    bash "$SERVICE_DIR/stop.sh"
    sleep 5
fi

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
ORIGINAL_BACKUP_FILE="$BACKUP_DIR/homeassistant_original.tar.gz"
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

# =============================================================================
# 场景3: 生成默认配置
# =============================================================================
log "scenario: no backup files available, generating default configuration"
mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"restoring\",\"method\":\"default_config\",\"timestamp\":$(date +%s)}"

# 生成默认配置
generate_default_config

# 启动服务验证配置
log "starting Home Assistant with new configuration"
bash "$SERVICE_DIR/start.sh"

# 等待并验证服务状态
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

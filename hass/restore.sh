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

# -----------------------------------------------------------------------------
# 处理无备份文件的情况 - 生成默认配置
# -----------------------------------------------------------------------------
if [ -z "$RESTORE_FILE" ]; then
    log "no backup file found, will generate default configuration"
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"restoring\",\"method\":\"default_config\",\"timestamp\":$(date +%s)}"
    
    # 停止服务
    log "stopping Home Assistant to ensure clean state"
    bash "$SERVICE_DIR/stop.sh" || true
    sleep 5
    
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
fi

# -----------------------------------------------------------------------------
# 处理备份文件还原
# -----------------------------------------------------------------------------
log "starting restore from: $RESTORE_FILE"

# 检查文件格式
BASENAME=$(basename -- "$RESTORE_FILE")
EXT="${BASENAME##*.}"
EXT_LOWER=$(echo "$EXT" | tr '[:upper:]' '[:lower:]')
FINAL_RESTORE_FILE="$RESTORE_FILE"
CONVERTED_FROM_ZIP=false

# 如果是zip文件，需要转换为tar.gz格式
if [[ "$EXT_LOWER" == "zip" ]]; then
    log "detected zip file, converting to tar.gz"
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"restoring\",\"method\":\"$METHOD\",\"file\":\"$RESTORE_FILE\",\"converting_zip\":true}"
    
    TEMP_DIR="$RESTORE_TEMP_DIR"
    CONVERTED_FILE="$BACKUP_DIR/homeassistant_converted_$(date +%Y%m%d-%H%M%S).tar.gz"
    
    # 创建临时目录并解压
    rm -rf "$TEMP_DIR" && mkdir -p "$TEMP_DIR"
    if ! unzip -q "$RESTORE_FILE" -d "$TEMP_DIR"; then
        log "failed to extract zip file"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"failed to extract zip file\",\"timestamp\":$(date +%s)}"
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    
    # 查找解压后的配置目录
    CONFIG_DIR_IN_ZIP=""
    if [ -d "$TEMP_DIR/.homeassistant" ]; then
        CONFIG_DIR_IN_ZIP=".homeassistant"
    elif [ -f "$TEMP_DIR/configuration.yaml" ]; then
        # 如果直接是配置文件，创建.homeassistant目录结构
        mkdir -p "$TEMP_DIR/.homeassistant"
        mv "$TEMP_DIR"/*.* "$TEMP_DIR/.homeassistant/" 2>/dev/null || true
        CONFIG_DIR_IN_ZIP=".homeassistant"
    else
        # 查找包含configuration.yaml的目录
        CONFIG_DIR_IN_ZIP=$(find "$TEMP_DIR" -name "configuration.yaml" -type f | head -n1 | xargs dirname | sed "s|$TEMP_DIR/||")
    fi
    
    if [ -z "$CONFIG_DIR_IN_ZIP" ]; then
        log "no valid Home Assistant config found in zip file"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"invalid zip structure\",\"timestamp\":$(date +%s)}"
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    
    # 创建标准的tar.gz格式
    if tar -czf "$CONVERTED_FILE" -C "$TEMP_DIR" "$CONFIG_DIR_IN_ZIP"; then
        FINAL_RESTORE_FILE="$CONVERTED_FILE"
        CONVERTED_FROM_ZIP=true
        log "converted zip to: $(basename "$CONVERTED_FILE")"
    else
        log "failed to create tar.gz from zip"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"failed to create tar.gz from zip\",\"timestamp\":$(date +%s)}"
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    
    # 清理临时目录
    rm -rf "$TEMP_DIR"
    
elif [[ "$BASENAME" != *.tar.gz ]]; then
    log "unsupported file format: $EXT"
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"unsupported file format. only .tar.gz and .zip are supported\",\"file\":\"$BASENAME\",\"timestamp\":$(date +%s)}"
    exit 1
fi

# 上报开始还原
if [ "$CONVERTED_FROM_ZIP" = true ]; then
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"restoring\",\"method\":\"$METHOD\",\"file\":\"$RESTORE_FILE\",\"converting_zip\":true}"
else
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"restoring\",\"method\":\"$METHOD\",\"file\":\"$FINAL_RESTORE_FILE\"}"
fi

# -----------------------------------------------------------------------------
# 执行恢复
# -----------------------------------------------------------------------------
if proot-distro login "$PROOT_DISTRO" -- bash -c "rm -rf \"$HA_CONFIG_DIR\" && mkdir -p \"$HA_CONFIG_DIR\" && tar -xzf \"$FINAL_RESTORE_FILE\" -C \"$(dirname $HA_CONFIG_DIR)\""; then
    log "restore completed, restarting service"
    bash "$SERVICE_DIR/stop.sh"
    sleep 5
    bash "$SERVICE_DIR/start.sh"
    sleep 30
    
    if bash "$SERVICE_DIR/status.sh" --quiet; then
        END_TIME=$(date +%s)
        DURATION=$((END_TIME - START_TIME))
        SIZE_KB=$(du -k "$FINAL_RESTORE_FILE" | awk '{print $1}')
        
        # 构建成功消息
        if [ "$CONVERTED_FROM_ZIP" = true ]; then
            mqtt_report "isg/restore/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"success\",\"method\":\"$METHOD\",\"original_file\":\"$(basename "$RESTORE_FILE")\",\"restore_file\":\"$(basename "$FINAL_RESTORE_FILE")\",\"size_kb\":$SIZE_KB,\"duration\":$DURATION,\"converted_from_zip\":true,\"timestamp\":$END_TIME}"
            log "restore + restart complete: $(basename "$FINAL_RESTORE_FILE") ($SIZE_KB KB, ${DURATION}s)"
            log "converted from: $(basename "$RESTORE_FILE")"
        else
            mqtt_report "isg/restore/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"success\",\"method\":\"$METHOD\",\"file\":\"$(basename "$FINAL_RESTORE_FILE")\",\"size_kb\":$SIZE_KB,\"duration\":$DURATION,\"timestamp\":$END_TIME}"
            log "restore + restart complete: $(basename "$FINAL_RESTORE_FILE") ($SIZE_KB KB, ${DURATION}s)"
        fi
    else
        log "restore succeeded but service did not start"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"service failed to start after restore\",\"method\":\"$METHOD\",\"timestamp\":$(date +%s)}"
        exit 1
    fi
else
    mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"restore failed inside proot container\",\"timestamp\":$(date +%s)}"
    log "restore failed inside proot"
    exit 1
fi

exit 0

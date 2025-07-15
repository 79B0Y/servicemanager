#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Node-RED 还原脚本
# 版本: v1.0.0
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

# 确保数据目录存在
proot-distro login "$PROOT_DISTRO" -- bash -c "mkdir -p $NODE_RED_DATA_DIR"

START_TIME=$(date +%s)
CUSTOM_BACKUP_FILE="${RESTORE_FILE:-}"

# -----------------------------------------------------------------------------
# 生成默认配置文件
# -----------------------------------------------------------------------------
generate_default_config() {
    log "generating default node-red configuration"
    
    # 生成默认的 flows.json 文件到备份目录
    cat > "$DEFAULT_CONFIG_FILE" << 'EOF'
[
    {
        "id": "flow1",
        "label": "Flow 1",
        "nodes": [
            {
                "id": "node1",
                "type": "inject",
                "z": "flow1",
                "name": "Welcome",
                "props": [
                    {
                        "p": "payload"
                    }
                ],
                "repeat": "",
                "crontab": "",
                "once": false,
                "onceDelay": 0.1,
                "topic": "",
                "payload": "Welcome to Node-RED!",
                "payloadType": "str",
                "x": 110,
                "y": 100,
                "wires": [
                    [
                        "node2"
                    ]
                ]
            },
            {
                "id": "node2",
                "type": "debug",
                "z": "flow1",
                "name": "Debug Output",
                "active": true,
                "tosidebar": true,
                "console": false,
                "tostatus": false,
                "complete": "payload",
                "targetType": "msg",
                "statusVal": "",
                "statusType": "auto",
                "x": 320,
                "y": 100,
                "wires": []
            }
        ]
    }
]
EOF
    
    # 复制到容器内
    log "copying default flows to container"
    if ! proot-distro login "$PROOT_DISTRO" -- bash -c "cp '$DEFAULT_CONFIG_FILE' $NODE_RED_DATA_DIR/flows.json"; then
        log "failed to copy default flows to container"
        return 1
    fi
    
    # 创建基本的 settings.js（如果不存在）
    proot-distro login "$PROOT_DISTRO" -- bash -c "
if [ ! -f $NODE_RED_DATA_DIR/settings.js ]; then
    cat > $NODE_RED_DATA_DIR/settings.js << 'SETTINGS_EOF'
module.exports = {
    uiPort: process.env.PORT || 1880,
    uiHost: \"0.0.0.0\",
    httpAdminRoot: false,
    httpNodeRoot: \"/\",
    functionGlobalContext: {},
    exportGlobalContextKeys: false,
    logging: {
        console: {
            level: \"info\",
            metrics: false,
            audit: false
        }
    },
    editorTheme: {
        projects: {
            enabled: false
        }
    }
}
SETTINGS_EOF
fi
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
    RESTORE_FILE=$(ls -1t "$BACKUP_DIR"/node-red_backup_*.tar.gz 2>/dev/null | head -n1 || true)
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
    log "stopping node-red to prepare for configuration"
    bash "$SERVICE_DIR/stop.sh" || true
    sleep 2
    
    # 生成默认配置
    generate_default_config
    
    # 启动服务验证配置
    bash "$SERVICE_DIR/start.sh"
    
    # 等待并验证服务状态
    MAX_WAIT=120
    INTERVAL=5
    WAITED=0
    log "waiting for node-red to start with new configuration"
    
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
    CONVERTED_FILE="$BACKUP_DIR/node-red_converted_$(date +%Y%m%d-%H%M%S).tar.gz"
    
    # 创建临时目录并解压
    rm -rf "$TEMP_DIR" && mkdir -p "$TEMP_DIR"
    if ! unzip -q "$RESTORE_FILE" -d "$TEMP_DIR"; then
        log "failed to extract zip file"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"failed to extract zip file\",\"timestamp\":$(date +%s)}"
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    
    # 查找解压后的数据目录
    DATA_DIR_IN_ZIP=""
    if [ -d "$TEMP_DIR/.node-red" ]; then
        DATA_DIR_IN_ZIP=".node-red"
    elif [ -d "$TEMP_DIR/node-red" ]; then
        DATA_DIR_IN_ZIP="node-red"
    elif [ -f "$TEMP_DIR/flows.json" ]; then
        # 如果直接是配置文件，创建.node-red目录结构
        mkdir -p "$TEMP_DIR/.node-red"
        mv "$TEMP_DIR"/*.* "$TEMP_DIR/.node-red/" 2>/dev/null || true
        DATA_DIR_IN_ZIP=".node-red"
    else
        # 查找包含flows.json的目录
        DATA_DIR_IN_ZIP=$(find "$TEMP_DIR" -name "flows.json" -type f | head -n1 | xargs dirname | sed "s|$TEMP_DIR/||")
    fi
    
    if [ -z "$DATA_DIR_IN_ZIP" ]; then
        log "no valid node-red data found in zip file"
        mqtt_report "isg/restore/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"invalid zip structure\",\"timestamp\":$(date +%s)}"
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    
    # 创建标准的tar.gz格式
    if tar -czf "$CONVERTED_FILE" -C "$TEMP_DIR" "$DATA_DIR_IN_ZIP"; then
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
if proot-distro login "$PROOT_DISTRO" -- bash -c "rm -rf \"$NODE_RED_DATA_DIR\" && mkdir -p \"$NODE_RED_DATA_DIR\" && tar -xzf \"$FINAL_RESTORE_FILE\" -C \"$(dirname $NODE_RED_DATA_DIR)\""; then
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

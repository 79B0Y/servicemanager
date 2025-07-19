#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Z-Wave JS UI 备份脚本
# 版本: v1.0.0
# 功能: 备份 Z-Wave JS UI 配置和数据
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# 路径和变量定义
# -----------------------------------------------------------------------------
SERVICE_ID="zwave-js-ui"
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"

CONFIG_FILE="$BASE_DIR/configuration.yaml"
ZWAVE_INSTALL_DIR="/root/.local/share/pnpm/global/5/node_modules/zwave-js-ui"
ZWAVE_STORE_DIR="$ZWAVE_INSTALL_DIR/store"

LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/backup.log"
BACKUP_DIR="/sdcard/isgbackup/$SERVICE_ID"
KEEP_BACKUPS=3

ZWAVE_PORT="8091"

# -----------------------------------------------------------------------------
# 辅助函数
# -----------------------------------------------------------------------------
ensure_directories() {
    mkdir -p "$LOG_DIR"
    mkdir -p "$BACKUP_DIR"
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

get_zwave_pid() {
    local port_pid=$(netstat -tnlp 2>/dev/null | grep ":$ZWAVE_PORT " | awk '{print $7}' | cut -d'/' -f1 | head -n1)
    
    if [ -n "$port_pid" ] && [ "$port_pid" != "-" ]; then
        local cwd=$(ls -l /proc/$port_pid/cwd 2>/dev/null | grep -o 'zwave-js-ui' || true)
        if [ -n "$cwd" ]; then
            echo "$port_pid"
            return 0
        fi
    fi
    return 1
}

mqtt_report() {
    local topic="$1"
    local payload="$2"
    
    # 检查 zwave-js-ui 是否运行，如果没有运行则只记录日志不发送
    if ! get_zwave_pid > /dev/null 2>&1; then
        echo "[$(date '+%F %T')] [MQTT-OFFLINE] $topic -> $payload" >> "$LOG_FILE"
        return 0
    fi
    
    load_mqtt_conf
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT_CONFIG" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload" 2>/dev/null || true
    echo "[$(date '+%F %T')] [MQTT] $topic -> $payload" >> "$LOG_FILE"
}

# -----------------------------------------------------------------------------
# 主备份流程
# -----------------------------------------------------------------------------
ensure_directories

TS=$(date +%Y%m%d-%H%M%S)
DST="$BACKUP_DIR/zwave-js-ui_backup_${TS}.tar.gz"
START_TIME=$(date +%s)

log "开始 zwave-js-ui 备份流程"
mqtt_report "isg/backup/$SERVICE_ID/status" "{\"status\":\"backuping\",\"message\":\"starting backup process\",\"timestamp\":$(date +%s)}"

# -----------------------------------------------------------------------------
# 检查服务是否在运行（备份时强制要求服务运行）
# -----------------------------------------------------------------------------
if ! bash "$SERVICE_DIR/status.sh" --quiet; then
    log "zwave-js-ui 未运行，跳过备份"
    mqtt_report "isg/backup/$SERVICE_ID/status" "{\"status\":\"skipped\",\"message\":\"service not running - backup skipped\",\"timestamp\":$(date +%s)}"
    exit 0
fi

log "zwave-js-ui 正在运行，继续备份"

# -----------------------------------------------------------------------------
# 检查存储目录是否存在
# -----------------------------------------------------------------------------
if ! proot-distro login "$PROOT_DISTRO" -- test -d "$ZWAVE_STORE_DIR"; then
    log "存储目录不存在: $ZWAVE_STORE_DIR"
    mqtt_report "isg/backup/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"store directory not found\",\"timestamp\":$(date +%s)}"
    exit 1
fi

# -----------------------------------------------------------------------------
# 收集要备份的内容
# -----------------------------------------------------------------------------
log "收集备份内容"
mqtt_report "isg/backup/$SERVICE_ID/status" "{\"status\":\"backuping\",\"message\":\"collecting backup content\",\"timestamp\":$(date +%s)}"

# 使用 Termux 专用的临时目录
TEMP_BACKUP_DIR="/data/data/com.termux/files/usr/tmp/zwave_backup_$$"
mkdir -p "$TEMP_BACKUP_DIR"

# 创建备份清单文件
BACKUP_MANIFEST="$TEMP_BACKUP_DIR/backup_manifest.txt"
echo "# Z-Wave JS UI Backup Manifest" > "$BACKUP_MANIFEST"
echo "# Created: $(date)" >> "$BACKUP_MANIFEST"
echo "# Service: zwave-js-ui" >> "$BACKUP_MANIFEST"

# 获取版本信息
ZWAVE_VERSION=$(proot-distro login "$PROOT_DISTRO" -- bash -c "
    export SHELL=/data/data/com.termux/files/usr/bin/bash
    export PNPM_HOME=/root/.local/share/pnpm
    export PATH=\$PNPM_HOME:\$PATH
    source ~/.bashrc 2>/dev/null || true
    
    if [ -f '$ZWAVE_INSTALL_DIR/package.json' ]; then
        grep -m1 '\"version\"' '$ZWAVE_INSTALL_DIR/package.json' | cut -d'\"' -f4
    else
        echo 'unknown'
    fi
" 2>/dev/null || echo "unknown")

echo "# Version: $ZWAVE_VERSION" >> "$BACKUP_MANIFEST"
echo "" >> "$BACKUP_MANIFEST"

# 备份存储目录（包含配置文件和数据）
log "备份存储目录: $ZWAVE_STORE_DIR"
if proot-distro login "$PROOT_DISTRO" -- test -d "$ZWAVE_STORE_DIR"; then
    # 将容器内的store目录复制到Termux临时目录
    proot-distro login "$PROOT_DISTRO" -- bash -c "
        if [ -d '$ZWAVE_STORE_DIR' ]; then
            tar -czf '$TEMP_BACKUP_DIR/store.tar.gz' -C '$(dirname $ZWAVE_STORE_DIR)' '$(basename $ZWAVE_STORE_DIR)'
            echo 'Store directory backed up successfully'
        else
            echo 'Store directory not found'
            exit 1
        fi
    "
    
    if [ -f "$TEMP_BACKUP_DIR/store.tar.gz" ]; then
        cd "$TEMP_BACKUP_DIR" && tar -xzf store.tar.gz && rm store.tar.gz
        echo "store/" >> "$BACKUP_MANIFEST"
        
        # 统计存储目录大小
        if [ -d "$TEMP_BACKUP_DIR/store" ]; then
            STORE_SIZE=$(du -sh "$TEMP_BACKUP_DIR/store" 2>/dev/null | awk '{print $1}' || echo "unknown")
            echo "Store directory size: $STORE_SIZE" >> "$BACKUP_MANIFEST"
            
            # 记录重要配置文件
            if [ -f "$TEMP_BACKUP_DIR/store/settings.json" ]; then
                echo "Configuration file: settings.json" >> "$BACKUP_MANIFEST"
                # 提取一些关键配置信息
                ZWAVE_PORT_CONFIG=$(grep -o '"port":"[^"]*"' "$TEMP_BACKUP_DIR/store/settings.json" 2>/dev/null | cut -d'"' -f4 || echo "unknown")
                MQTT_ENABLED=$(grep -o '"enabled":[^,}]*' "$TEMP_BACKUP_DIR/store/settings.json" 2>/dev/null | grep -o '[^:]*$' || echo "unknown")
                echo "Z-Wave Port: $ZWAVE_PORT_CONFIG" >> "$BACKUP_MANIFEST"
                echo "MQTT Enabled: $MQTT_ENABLED" >> "$BACKUP_MANIFEST"
            fi
        fi
    else
        log "存储目录备份失败"
        rm -rf "$TEMP_BACKUP_DIR"
        mqtt_report "isg/backup/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"store directory backup failed\",\"timestamp\":$(date +%s)}"
        exit 1
    fi
else
    log "警告: 存储目录不存在 $ZWAVE_STORE_DIR"
    echo "# Warning: Store directory not found" >> "$BACKUP_MANIFEST"
fi

# 收集运行状态信息
log "收集运行状态信息"
STATUS_FILE="$TEMP_BACKUP_DIR/runtime_status.json"
bash "$SERVICE_DIR/status.sh" --json > "$STATUS_FILE" 2>/dev/null || echo '{"error":"status unavailable"}' > "$STATUS_FILE"
echo "runtime_status.json" >> "$BACKUP_MANIFEST"

# 收集进程信息
PROCESS_INFO="$TEMP_BACKUP_DIR/process_info.txt"
echo "# Process Information at backup time" > "$PROCESS_INFO"
echo "# Date: $(date)" >> "$PROCESS_INFO"
ZWAVE_PID=$(get_zwave_pid || echo "")
if [ -n "$ZWAVE_PID" ]; then
    echo "PID: $ZWAVE_PID" >> "$PROCESS_INFO"
    echo "Command: $(ps -p $ZWAVE_PID -o args= 2>/dev/null || echo 'N/A')" >> "$PROCESS_INFO"
    echo "Runtime: $(ps -p $ZWAVE_PID -o etime= 2>/dev/null || echo 'N/A')" >> "$PROCESS_INFO"
fi
echo "Port status:" >> "$PROCESS_INFO"
netstat -tulnp 2>/dev/null | grep ":$ZWAVE_PORT " >> "$PROCESS_INFO" || echo "Port not listening" >> "$PROCESS_INFO"
echo "process_info.txt" >> "$BACKUP_MANIFEST"

# -----------------------------------------------------------------------------
# 创建压缩包
# -----------------------------------------------------------------------------
log "创建压缩包: $DST"
mqtt_report "isg/backup/$SERVICE_ID/status" "{\"status\":\"backuping\",\"message\":\"creating archive\",\"timestamp\":$(date +%s)}"

if tar -czf "$DST" -C "$TEMP_BACKUP_DIR" .; then
    END_TIME=$(date +%s)
    SIZE_KB=$(du -k "$DST" | awk '{print $1}')
    DURATION=$((END_TIME - START_TIME))
    
    log "备份完成: $DST ($SIZE_KB KB, ${DURATION}s)"
    mqtt_report "isg/backup/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"success\",\"file\":\"$(basename "$DST")\",\"size_kb\":$SIZE_KB,\"duration\":$DURATION,\"message\":\"backup completed successfully\",\"timestamp\":$END_TIME}"
else
    log "创建压缩包失败"
    mqtt_report "isg/backup/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"archive creation failed\",\"timestamp\":$(date +%s)}"
    rm -rf "$TEMP_BACKUP_DIR"
    exit 1
fi

# 清理临时目录
rm -rf "$TEMP_BACKUP_DIR"

# -----------------------------------------------------------------------------
# 清理旧备份 - 保留最近的指定数量
# -----------------------------------------------------------------------------
log "清理旧备份（保留最新 $KEEP_BACKUPS 个）"
OLD_BACKUPS=$(ls -1t "$BACKUP_DIR"/zwave-js-ui_backup_*.tar.gz 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)) || true)

if [ -n "$OLD_BACKUPS" ]; then
    echo "$OLD_BACKUPS" | while read -r old_file; do
        if [ -f "$old_file" ]; then
            log "删除旧备份: $(basename "$old_file")"
            rm -f "$old_file"
        fi
    done
    REMOVED_COUNT=$(echo "$OLD_BACKUPS" | wc -l)
    log "删除了 $REMOVED_COUNT 个旧备份"
else
    log "没有需要删除的旧备份"
fi

# 显示当前备份文件列表
CURRENT_BACKUPS=$(ls -1t "$BACKUP_DIR"/zwave-js-ui_backup_*.tar.gz 2>/dev/null | wc -l || echo 0)
log "当前备份文件总数: $CURRENT_BACKUPS"

# -----------------------------------------------------------------------------
# 备份内容摘要
# -----------------------------------------------------------------------------
log "备份内容摘要:"
log "  - 存储目录: $([ -d "$ZWAVE_STORE_DIR" ] && echo "已备份" || echo "不存在")"
log "  - 运行状态: 已备份"
log "  - 进程信息: 已备份"
log "  - 备份大小: $SIZE_KB KB"
log "  - 备份位置: $DST"
log "  - 版本信息: $ZWAVE_VERSION"

exit 0
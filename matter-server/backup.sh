#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Matter Server 备份脚本 - 修复版本
# 版本: v1.2.0
# 功能: 备份 Matter Server 数据和配置
# 修复: 按基础要求备份 /root/.matter_server/ 目录
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# 路径和变量定义
# -----------------------------------------------------------------------------
SERVICE_ID="matter-server"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"
TERMUX_TMP_DIR="/data/data/com.termux/files/usr/tmp"

CONFIG_FILE="$BASE_DIR/configuration.yaml"

LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/backup.log"
BACKUP_DIR="/sdcard/isgbackup/$SERVICE_ID"
KEEP_BACKUPS=3

PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
# 修复: 按基础要求使用 /root/.matter_server/ 目录
MATTER_DATA_DIR="/root/.matter_server"
MATTER_VENV_DIR="/opt/matter-server/venv"
MATTER_PORT="5580"

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

get_matter_pid() {
    local port_pid=$(netstat -tnlp 2>/dev/null | grep ":$MATTER_PORT " | awk '{print $7}' | cut -d'/' -f1 | head -n1)
    
    if [ -n "$port_pid" ] && [ "$port_pid" != "-" ]; then
        local cmdline=$(cat /proc/$port_pid/cmdline 2>/dev/null | grep -o 'matter-server\|python.*matter' || true)
        if [ -n "$cmdline" ]; then
            echo "$port_pid"
            return 0
        fi
    fi
    return 1
}

# 修复: 使用基础要求里的标准版本获取方法
get_current_version() {
    proot-distro login "$PROOT_DISTRO" -- bash -c '
        if [ -f "'"$MATTER_VENV_DIR"'/bin/activate" ]; then
            source "'"$MATTER_VENV_DIR"'/bin/activate"
            pip show python-matter-server 2>/dev/null | awk -F": " "/^Version/ {print \$2}" || echo "unknown"
        else
            echo "unknown"
        fi
    ' 2>/dev/null || echo "unknown"
}

mqtt_report() {
    local topic="$1"
    local payload="$2"
    
    # 检查 MQTT broker 是否可用
    if ! nc -z 127.0.0.1 1883 2>/dev/null; then
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
DST="$BACKUP_DIR/matter-server_backup_${TS}.tar.gz"
START_TIME=$(date +%s)

log "开始 Matter Server 备份流程"
mqtt_report "isg/backup/$SERVICE_ID/status" "{\"status\":\"backuping\",\"message\":\"starting backup process\",\"timestamp\":$(date +%s)}"

# -----------------------------------------------------------------------------
# 检查服务是否在运行（备份时强制要求服务运行）
# -----------------------------------------------------------------------------
if ! bash "$SERVICE_DIR/status.sh" --quiet; then
    log "Matter Server 未运行，跳过备份"
    mqtt_report "isg/backup/$SERVICE_ID/status" "{\"status\":\"skipped\",\"message\":\"service not running - backup skipped\",\"timestamp\":$(date +%s)}"
    exit 0
fi

log "Matter Server 正在运行，继续备份"

# -----------------------------------------------------------------------------
# 收集要备份的内容
# -----------------------------------------------------------------------------
log "收集备份内容"
mqtt_report "isg/backup/$SERVICE_ID/status" "{\"status\":\"backuping\",\"message\":\"collecting backup content\",\"timestamp\":$(date +%s)}"

# 使用 Termux 专用的临时目录
TEMP_BACKUP_DIR="$TERMUX_TMP_DIR/matter-server_backup_$$"
mkdir -p "$TEMP_BACKUP_DIR"

# 创建备份清单文件
BACKUP_MANIFEST="$TEMP_BACKUP_DIR/backup_manifest.txt"
echo "# Matter Server Backup Manifest" > "$BACKUP_MANIFEST"
echo "# Created: $(date)" >> "$BACKUP_MANIFEST"
echo "# Service: matter-server" >> "$BACKUP_MANIFEST"
echo "# Port: $MATTER_PORT" >> "$BACKUP_MANIFEST"
echo "# Data Source: $MATTER_DATA_DIR" >> "$BACKUP_MANIFEST"
echo "" >> "$BACKUP_MANIFEST"

# 修复: 备份 /root/.matter_server/ 目录下所有数据
if proot-distro login "$PROOT_DISTRO" -- test -d "$MATTER_DATA_DIR"; then
    log "备份 Matter Server 数据目录: $MATTER_DATA_DIR"
    
    # 从容器内复制整个 .matter_server 目录
    proot-distro login "$PROOT_DISTRO" -- bash -c "
        if [ -d '$MATTER_DATA_DIR' ]; then
            cd '$(dirname $MATTER_DATA_DIR)'
            tar -czf '$TEMP_BACKUP_DIR/matter-server-data.tar.gz' '$(basename $MATTER_DATA_DIR)'
            echo 'matter-server-data.tar.gz' >> '$BACKUP_MANIFEST'
        fi
    "
    
    # 统计数据目录大小
    DATA_SIZE=$(proot-distro login "$PROOT_DISTRO" -- bash -c "du -sh '$MATTER_DATA_DIR' 2>/dev/null | awk '{print \$1}'" || echo "unknown")
    echo "Data directory size: $DATA_SIZE" >> "$BACKUP_MANIFEST"
    
    # 列出备份内容
    log "列出备份内容"
    proot-distro login "$PROOT_DISTRO" -- bash -c "
        echo '# Backup Contents:' >> '$BACKUP_MANIFEST'
        if [ -d '$MATTER_DATA_DIR' ]; then
            find '$MATTER_DATA_DIR' -type f 2>/dev/null | head -20 >> '$BACKUP_MANIFEST' || true
            file_count=\$(find '$MATTER_DATA_DIR' -type f 2>/dev/null | wc -l)
            echo \"# Total files: \$file_count\" >> '$BACKUP_MANIFEST'
        fi
    "
else
    log "警告: Matter Server 数据目录不存在 $MATTER_DATA_DIR"
    echo "# Warning: Data directory not found: $MATTER_DATA_DIR" >> "$BACKUP_MANIFEST"
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
MATTER_PID=$(get_matter_pid || echo "")
if [ -n "$MATTER_PID" ]; then
    echo "PID: $MATTER_PID" >> "$PROCESS_INFO"
    echo "Command: $(ps -p $MATTER_PID -o args= 2>/dev/null || echo 'N/A')" >> "$PROCESS_INFO"
    echo "Runtime: $(ps -p $MATTER_PID -o etime= 2>/dev/null || echo 'N/A')" >> "$PROCESS_INFO"
fi
echo "Port status:" >> "$PROCESS_INFO"
netstat -tulnp 2>/dev/null | grep ":$MATTER_PORT " >> "$PROCESS_INFO" || echo "Port not listening" >> "$PROCESS_INFO"
echo "process_info.txt" >> "$BACKUP_MANIFEST"

# 收集 Matter Server 版本信息
VERSION_INFO="$TEMP_BACKUP_DIR/version_info.txt"
echo "# Matter Server Version Information" > "$VERSION_INFO"
echo "# Date: $(date)" >> "$VERSION_INFO"
CURRENT_VERSION=$(get_current_version)
echo "Matter Server Version: $CURRENT_VERSION" >> "$VERSION_INFO"
echo "Backup Script Version: 1.2.0" >> "$VERSION_INFO"
echo "version_info.txt" >> "$BACKUP_MANIFEST"

# -----------------------------------------------------------------------------
# 创建最终压缩包
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
OLD_BACKUPS=$(ls -1t "$BACKUP_DIR"/matter-server_backup_*.tar.gz 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)) || true)

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
CURRENT_BACKUPS=$(ls -1t "$BACKUP_DIR"/matter-server_backup_*.tar.gz 2>/dev/null | wc -l || echo 0)
log "当前备份文件总数: $CURRENT_BACKUPS"

# -----------------------------------------------------------------------------
# 备份内容摘要
# -----------------------------------------------------------------------------
log "备份内容摘要:"
log "  - 数据目录: $(proot-distro login "$PROOT_DISTRO" -- test -d "$MATTER_DATA_DIR" && echo "已备份 ($MATTER_DATA_DIR)" || echo "不存在")"
log "  - 运行状态: 已备份"
log "  - 进程信息: 已备份"
log "  - 版本信息: 已备份 ($CURRENT_VERSION)"
log "  - 备份大小: $SIZE_KB KB"
log "  - 备份位置: $DST"

exit 0

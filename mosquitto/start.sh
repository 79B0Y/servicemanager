#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Mosquitto 启动脚本 - 独立启动及验证登录、上报成功（从 configuration.yaml 读取 MQTT 配置）
# 版本: v1.2.0
# =============================================================================

set -euo pipefail

# ---------------------- 基本参数与路径 ----------------------
SERVICE_ID="mosquitto"
BASE_DIR="/data/data/com.termux/files/home/servicemanager/$SERVICE_ID"
SERVICE_CONTROL_DIR="/data/data/com.termux/files/usr/var/service/$SERVICE_ID"
CONTROL_FILE="$SERVICE_CONTROL_DIR/supervise/control"
DOWN_FILE="$SERVICE_CONTROL_DIR/down"

TERMUX_VAR_DIR="/data/data/com.termux/files/usr/var"
TERMUX_ETC_DIR="/data/data/com.termux/files/usr/etc"
CONFIG_FILE="/data/data/com.termux/files/home/servicemanager/configuration.yaml"

LOG_DIR="$BASE_DIR/logs"
LOG_FILE="$LOG_DIR/start.log"

mkdir -p "$LOG_DIR"
log() { echo "[$(date '+%F %T')] [INFO] $*" | tee -a "$LOG_FILE"; }

log "开始启动 Mosquitto 服务..."

# ---------------------- 读取 MQTT 配置 ----------------------
if [ ! -f "$CONFIG_FILE" ]; then
    log "配置文件不存在: $CONFIG_FILE"
    exit 1
fi

MQTT_HOST=$(grep -Po '^mqtt:[[:space:]]*\n[[:space:]]*host:[[:space:]]*\K.*' "$CONFIG_FILE")
MQTT_PORT=$(grep -Po '^[[:space:]]*port:[[:space:]]*\K.*' "$CONFIG_FILE")
MQTT_USER=$(grep -Po '^[[:space:]]*username:[[:space:]]*\K.*' "$CONFIG_FILE")
MQTT_PASS=$(grep -Po '^[[:space:]]*password:[[:space:]]*\K.*' "$CONFIG_FILE")

MQTT_HOST="${MQTT_HOST:-127.0.0.1}"
MQTT_PORT="${MQTT_PORT:-1883}"

log "MQTT 配置读取完成: host=$MQTT_HOST port=$MQTT_PORT user=$MQTT_USER"

# ---------------------- 启动 Mosquitto 服务 ----------------------
if [ -f "$DOWN_FILE" ]; then
    rm -f "$DOWN_FILE"
    log "移除 down 文件，准备启动 Mosquitto"
fi

if [ -e "$CONTROL_FILE" ]; then
    echo u > "$CONTROL_FILE"
    log "发送 'u' 指令到 $CONTROL_FILE 触发服务启动"
else
    log "控制文件不存在，无法启动服务: $CONTROL_FILE"
    exit 1
fi

sleep 3

if netstat -tulnp 2>/dev/null | grep -q "0.0.0.0:$MQTT_PORT"; then
    log "Mosquitto 已成功监听 0.0.0.0:$MQTT_PORT"
else
    log "Mosquitto 未监听 $MQTT_PORT，启动失败"
    exit 1
fi

# 验证 MQTT 用户登录
if mosquitto_sub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "test/login" -C 1 -W 3; then
    log "MQTT 登录验证成功: 用户 $MQTT_USER"
else
    log "MQTT 登录验证失败: 用户 $MQTT_USER"
    exit 1
fi

# 上报启动成功状态
TIMESTAMP=$(date +%s)
TOPIC="isg/run/$SERVICE_ID/status"
PAYLOAD="{\"service\":\"$SERVICE_ID\",\"status\":\"success\",\"message\":\"mosquitto started and login verified\",\"timestamp\":$TIMESTAMP}"

mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$TOPIC" -m "$PAYLOAD"
log "已上报 MQTT 启动成功状态: $TOPIC"

log "Mosquitto 启动与验证完成"
exit 0

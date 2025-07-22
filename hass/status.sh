#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Home Assistant 状态查询脚本 (集成路径与 MQTT 配置)
# 版本: v1.5.0
# =============================================================================

set -euo pipefail

# =============================================================================
# 基础路径与配置
# =============================================================================
SERVICE_ID="hass"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"
TERMUX_VAR_DIR="/data/data/com.termux/files/usr/var"
TERMUX_TMP_DIR="/data/data/com.termux/files/usr/tmp"

CONFIG_FILE="$BASE_DIR/configuration.yaml"
LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/status.log"

HA_VENV_DIR="/root/homeassistant"
HA_CONFIG_DIR="/root/.homeassistant"
HA_BINARY="$HA_VENV_DIR/bin/hass"
HA_PORT="8123"
HTTP_TIMEOUT=10

# =============================================================================
# 工具函数
# =============================================================================
ensure_directories() {
    mkdir -p "$LOG_DIR"
}

log() {
    echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"
}

load_mqtt_conf() {
    MQTT_HOST=$(grep -Po '^[[:space:]]*host:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1 || echo "127.0.0.1")
    MQTT_PORT=$(grep -Po '^[[:space:]]*port:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1 || echo "1883")
    MQTT_USER=$(grep -Po '^[[:space:]]*username:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1 || echo "admin")
    MQTT_PASS=$(grep -Po '^[[:space:]]*password:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1 || echo "admin")
}

mqtt_report() {
    local topic="$1"
    local payload="$2"
    load_mqtt_conf
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload" || true
    echo "[$(date '+%F %T')] [MQTT] $topic -> $payload" >> "$LOG_FILE"
}

get_ha_pid() {
    local pid=$(pgrep -f '[h]omeassistant' | head -n1)
    if [ -n "$pid" ] && netstat -tnlp 2>/dev/null | grep -q ":$HA_PORT.*$pid/"; then
        echo "$pid"
    else
        return 1
    fi
}

check_ha_port() {
    nc -z 127.0.0.1 "$HA_PORT" >/dev/null 2>&1
}

# =============================================================================
# 主流程
# =============================================================================
ensure_directories
PID=$(get_ha_pid || true)
RUNTIME=""
HTTP_AVAILABLE="false"
INSTALL_STATUS="false"

if [ -n "$PID" ]; then
    RUNTIME=$(ps -o etime= -p "$PID" | xargs)
    if check_ha_port; then
        HTTP_AVAILABLE="true"
        STATUS="running"
        EXIT=0
    else
        STATUS="starting"
        EXIT=2
    fi
else
    STATUS="stopped"
    EXIT=1
fi

# 检查安装状态
if proot-distro login ubuntu -- bash -c "test -f '$HA_BINARY'" 2>/dev/null; then
    INSTALL_STATUS="true"
fi

TS=$(date +%s)
if [ "$STATUS" = "running" ]; then
    mqtt_report "isg/status/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"running\",\"pid\":$PID,\"runtime\":\"$RUNTIME\",\"http_available\":true,\"install\":$INSTALL_STATUS,\"timestamp\":$TS}"
    log "Home Assistant 正在运行 (PID=$PID, 运行时间=$RUNTIME, HTTP正常)"
elif [ "$STATUS" = "starting" ]; then
    mqtt_report "isg/status/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"starting\",\"pid\":$PID,\"runtime\":\"$RUNTIME\",\"http_available\":false,\"install\":$INSTALL_STATUS,\"timestamp\":$TS}"
    log "Home Assistant 启动中 (PID=$PID, HTTP未就绪)"
else
    mqtt_report "isg/status/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"stopped\",\"install\":$INSTALL_STATUS,\"message\":\"service not running\",\"timestamp\":$TS}"
    log "Home Assistant 未运行"
fi

# 支持参数输出
case "${1:-}" in
    --json)
        echo "{\"status\":\"$STATUS\",\"pid\":\"$PID\",\"runtime\":\"$RUNTIME\",\"http_available\":$HTTP_AVAILABLE,\"install\":$INSTALL_STATUS}"
        exit $EXIT
        ;;
    --quiet)
        exit $EXIT
        ;;
    --simple)
        echo "$STATUS"
        exit $EXIT
        ;;
    *)
        ;;
esac

exit $EXIT

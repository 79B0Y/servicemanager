#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

SERVICE_ID="hass"
SERVICE_DIR="/data/data/com.termux/files/home/servicemanager/$SERVICE_ID"
CONFIG_FILE="/data/data/com.termux/files/home/servicemanager/configuration.yaml"
LOG_FILE="$SERVICE_DIR/logs/install.log"
HASS_VERSION="${TARGET_VERSION:-2025.5.3}"
PROOT_DISTRO="ubuntu"
START_TIME=$(date +%s)

mkdir -p "$(dirname "$LOG_FILE")"

load_mqtt_conf() {
  MQTT_HOST=$(grep -Po '^[[:space:]]*host:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1)
  MQTT_PORT=$(grep -Po '^[[:space:]]*port:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1)
  MQTT_USER=$(grep -Po '^[[:space:]]*username:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1)
  MQTT_PASS=$(grep -Po '^[[:space:]]*password:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1)
}

mqtt_report() {
  local topic="$1"
  local payload="$2"
  load_mqtt_conf
  mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload" || {
    echo "[MQTT ERROR] $topic -> $payload" >> "$LOG_FILE"
  }
  echo "[MQTT] $topic -> $payload" >> "$LOG_FILE"
}

log() {
  echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"
}

# 定义 in_proot 函数供主脚本使用
in_proot() {
  proot-distro login "$PROOT_DISTRO" -- bash -c "$1"
}

log "📦 Starting Home Assistant install..."
mqtt_report "isg/install/$SERVICE_ID/status" '{"status":"installing"}'

proot-distro login "$PROOT_DISTRO" << EOF

[ -d /root/homeassistant ] && rm -rf /root/homeassistant /root/.homeassistant

log_step() {
  echo -e "\n[STEP] \$1"
}

run_or_fail() {
  local step="\$1"
  local cmd="\$2"
  log_step "\$step"
  eval "\$cmd" || { echo "[ERROR] \$step 失败"; exit 1; }
}

run_or_fail "更新 apt 索引并安装系统依赖 (ffmpeg libturbojpeg)" "apt update && apt install -y ffmpeg libturbojpeg"
run_or_fail "创建 Python 虚拟环境 /root/homeassistant" "python3 -m venv /root/homeassistant"

log_step "安装 Python 库 (numpy mutagen pillow 等)"
PY_SETUP='source /root/homeassistant/bin/activate && \
  pip install --upgrade pip && \
  pip install numpy mutagen pillow aiohttp_fast_zlib && \
  pip install aiohttp==3.10.8 attrs==23.2.0 && \
  pip install PyTurboJPEG'
run_or_fail "安装基础依赖" "\$PY_SETUP"

log_step "安装 Home Assistant $HASS_VERSION"
run_or_fail "pip 安装 Home Assistant" "source /root/homeassistant/bin/activate && pip install homeassistant==$HASS_VERSION"

log_step "首次启动 Home Assistant，生成配置目录"
source /root/homeassistant/bin/activate
hass & echo \$! > /tmp/hass_pid
EOF

HASS_PID=$(in_proot "cat /tmp/hass_pid")
MAX_TRIES=90
COUNT=0
while (( COUNT < MAX_TRIES )); do
  if nc -z 127.0.0.1 8123 2>/dev/null; then
    echo "[INFO] Home Assistant Web 已就绪"
    break
  fi
  COUNT=$((COUNT+1))
  sleep 60
  echo "[WAIT] HA not ready yet ($COUNT/90)"
done

if (( COUNT >= MAX_TRIES )); then
  echo "[ERROR] 初始化超时"
  in_proot "kill $HASS_PID || true"
  mqtt_report "isg/install/$SERVICE_ID/status" '{"status":"failed","message":"init_timeout"}'
  exit 1
fi

log "🛑 终止首次启动进程并安装 zlib-ng / isal"
in_proot "kill $HASS_PID"
in_proot "source /root/homeassistant/bin/activate && pip install --force-reinstall zlib-ng isal --no-binary :all:"

log "⚙️ 配置 logger 为 critical & 允许 iframe"
in_proot "grep -q '^logger:' /root/.homeassistant/configuration.yaml || \
  echo -e '\nlogger:\n  default: critical' >> /root/.homeassistant/configuration.yaml"
in_proot "grep -q 'use_x_frame_options:' /root/.homeassistant/configuration.yaml || \
  echo -e '\nhttp:\n  use_x_frame_options: false' >> /root/.homeassistant/configuration.yaml"

VERSION_STR=$(in_proot "source /root/homeassistant/bin/activate && hass --version")
log "✅ 安装完成，Home Assistant 版本: $VERSION_STR"

# 启动服务
bash "$SERVICE_DIR/start.sh"

MAX_WAIT=600
INTERVAL=5
ELAPSED=0
log "⏳ Waiting for Home Assistant to be running..."

while [ $ELAPSED -lt $MAX_WAIT ]; do
  if bash "$SERVICE_DIR/status.sh" --quiet; then
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    mqtt_report "isg/install/$SERVICE_ID/status" "$(cat <<EOF
{
  "service": "home_assistant",
  "status": "success",
  "version": "$HASS_VERSION",
  "log": "$LOG_FILE",
  "timestamp": $END_TIME
}
EOF
)"
    echo "$HASS_VERSION" > "$SERVICE_DIR/VERSION"
    log "✅ Installed Home Assistant version $HASS_VERSION and service running in ${DURATION}s"
    exit 0
  fi
  sleep $INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))
done

mqtt_report "isg/install/$SERVICE_ID/status" '{"status":"failed","message":"HA service did not start in time."}'
log "❌ HA did not reach running state within ${MAX_WAIT}s"
exit 1

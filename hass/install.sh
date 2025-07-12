#!/data/data/com.termux/files/usr/bin/bash
# Auto‑generated combined installer — Home Assistant section taken verbatim from init.sh.
# Only the version number is parameterised via $HASS_VERSION; everything else is untouched.
# Key install steps are logged to $LOG_FILE and echoed via mqtt_report for external observers.

set -euo pipefail

SERVICE_ID="hass"
SERVICE_DIR="/data/data/com.termux/files/home/servicemanager/${SERVICE_ID}"
CONFIG_FILE="/data/data/com.termux/files/home/servicemanager/configuration.yaml"
LOG_FILE="${SERVICE_DIR}/logs/install.log"
HASS_VERSION="${TARGET_VERSION:-2025.5.3}"
PROOT_DISTRO="ubuntu"
START_TIME=$(date +%s)

mkdir -p "$(dirname "$LOG_FILE")"

# ---------- helper functions -------------------------------------------------
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

# -----------------------------------------------------------------------------
log "📦 Starting Home Assistant install..."
mqtt_report "isg/install/$SERVICE_ID/status" '{"status":"installing", "step":"start"}'

# 0. basic system dependencies inside ubuntu (kept from original script)
proot-distro login "$PROOT_DISTRO" << 'EOF'
[ -d /root/homeassistant ] && rm -rf /root/homeassistant /root/.homeassistant

log_step() {
  echo -e "\n[STEP] $1"
}

run_or_fail() {
  local step="$1"
  local cmd="$2"
  log_step "$step"
  eval "$cmd" || { echo "[ERROR] $step 失败"; exit 1; }
}

run_or_fail "更新 apt 索引并安装系统依赖 (ffmpeg libturbojpeg)" \
           "apt update && apt install -y ffmpeg libturbojpeg"
EOF
mqtt_report "isg/install/$SERVICE_ID/status" '{"status":"installing", "step":"install_dependencies"}'

# -----------------------------------------------------------------------------
#                Home Assistant installation (from init.sh §8)
# -----------------------------------------------------------------------------
mqtt_report "isg/install/$SERVICE_ID/status" '{"status":"installing", "step":"install_homeassistant"}'

proot-distro login "$PROOT_DISTRO" << EOF
LOG_FILE="$LOG_FILE"
HASS_VERSION="$HASS_VERSION"
export TZ=\$(getprop persist.sys.timezone)

log_step() {
  local step="\$1"; local msg="\$2"; local info="\$3"
  local now="\$(date '+%Y-%m-%d %H:%M:%S')"
  printf "\n[%s] [PROOT] ==== STEP %s %s {%s}\n" "\$now" "\$step" "\$msg" "\$info" | tee -a "\$LOG_FILE"
}

log_info() {
  local msg="\$1"; local now="\$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[\$now][PROOT] \$msg" | tee -a "\$LOG_FILE"
}

run_or_fail() {
  local step="\$1"; local cmd="\$2"; local info="\$3"
  log_step "\$step" "\$cmd" "\$info"
  eval "\$cmd"
  local code=
  if [ \$code -ne 0 ]; then
    log_step "\$step" "[ERROR] \$cmd failed" "\$info"
    exit \$code
  fi
}

log_step "8.1" "Install ffmpeg libturbojpeg. May take time." "8/16,58,64"
run_or_fail "8.1" "apt install -y ffmpeg libturbojpeg" "8/16,58,64"

log_step "8.2" "Create and enter Python venv" "8/16,57,65"
cd ~
run_or_fail "8.2" "python3 -m venv homeassistant" "8/16,57,65"
source homeassistant/bin/activate

log_step "8.3" "Install prerequisite libs" "8/16,57,66"
pip install --upgrade pip
pip install numpy mutagen pillow aiohttp_fast_zlib
pip install aiohttp==3.10.8 attrs==23.2.0
pip install PyTurboJPEG

log_step "8.4" "pip install homeassistant" "8/16,56,67"
mkdir -p ~/homeassistant
cd ~/homeassistant
run_or_fail "8.4" "pip install homeassistant==\$HASS_VERSION" "8/16,56,67"

log_step "8.5" "Start Home Assistant and wait init complete" "8/16,45,73"
hass > /root/hass.log 2>&1 &
echo \$! > /root/hass.pid
EOF

HASS_PID=$(proot-distro login "$PROOT_DISTRO" -- bash -c 'cat /root/hass.pid')

# Wait for HA to be ready
COUNT=0
MAX_TRIES=90
while [ \$COUNT -lt \$MAX_TRIES ]; do
  if nc -z 127.0.0.1 8123; then
    log "Home Assistant Web 已就绪"
    break
  fi
  COUNT=\$((COUNT + 1))
  sleep 10
  log "[WAIT] HA not ready yet (\$COUNT/\$MAX_TRIES)"
done

if [ \$COUNT -ge \$MAX_TRIES ]; then
  proot-distro login "$PROOT_DISTRO" -- bash -c "kill \$HASS_PID || true"
  mqtt_report "isg/install/$SERVICE_ID/status" '{"status":"failed", "message":"init_timeout"}'
  exit 1
fi

mqtt_report "isg/install/$SERVICE_ID/status" '{"status":"installing", "step":"init_done"}'
log "🛠  Home Assistant core installation finished"

proot-distro login "$PROOT_DISTRO" << EOF
source /root/homeassistant/bin/activate
kill \$(cat /root/hass.pid)
pip install --force-reinstall zlib-ng isal --no-binary :all:
grep -q '^logger:' /root/.homeassistant/configuration.yaml || echo -e '\nlogger:\n  default: critical' >> /root/.homeassistant/configuration.yaml
grep -q 'use_x_frame_options:' /root/.homeassistant/configuration.yaml || echo -e '\nhttp:\n  use_x_frame_options: false' >> /root/.homeassistant/configuration.yaml
EOF

# -----------------------------------------------------------------------------
VERSION_STR=$(proot-distro login "$PROOT_DISTRO" -- bash -c 'source /root/homeassistant/bin/activate && hass --version')
log "✅ Installation complete, Home Assistant version: $VERSION_STR"

bash "$SERVICE_DIR/start.sh"

MAX_WAIT=600
INTERVAL=5
ELAPSED=0
log "⏳ Waiting for Home Assistant to be running..."

while [ \$ELAPSED -lt \$MAX_WAIT ]; do
  if bash "$SERVICE_DIR/status.sh" --quiet; then
    END_TIME=$(date +%s)
    DURATION=\$((END_TIME - START_TIME))
    mqtt_report "isg/install/$SERVICE_ID/status" "$(cat <<JSON
{
  \"service\": \"home_assistant\",
  \"status\": \"success\",
  \"version\": \"$HASS_VERSION\",
  \"log\": \"$LOG_FILE\",
  \"timestamp\": $END_TIME
}
JSON
)"
    echo "$HASS_VERSION" > "$SERVICE_DIR/VERSION"
    log "✅ Home Assistant $HASS_VERSION is running (took \${DURATION}s)"
    exit 0
  fi
  sleep \$INTERVAL
  ELAPSED=\$((ELAPSED + INTERVAL))
done

mqtt_report "isg/install/$SERVICE_ID/status" '{"status":"failed", "message":"HA service did not start in time."}'
log "❌ Home Assistant did not reach running state within \${MAX_WAIT}s"
exit 1

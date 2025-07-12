#!/data/data/com.termux/files/usr/bin/bash
# Auto‑generated combined installer — Home Assistant section taken verbatim from init.sh.
# Only the version number is parameterised via $HASS_VERSION, everything else is untouched.
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

# Convenience wrapper for single‑command proot calls
in_proot() {
  proot-distro login "$PROOT_DISTRO" -- bash -c "$1"
}

# -----------------------------------------------------------------------------
log "📦 Starting Home Assistant install..."
mqtt_report "isg/install/$SERVICE_ID/status" '{"status":"installing", "step":"start"}'

# 0. basic system dependencies inside ubuntu (kept from original script)
proot-distro login "$PROOT_DISTRO" << EOF
[ -d /root/homeassistant ] && rm -rf /root/homeassistant /root/.homeassistant

log_step() {
  local step="$1"; local msg="$2"; local info="$3"
  local now="$(date '+%Y-%m-%d %H:%M:%S')"
  printf "\n[%s] ==== STEP %s %s {%s}\n" "$now" "$step" "$msg" "$info"
}

run_or_fail() {
  local step="$1"; local cmd="$2"; local info="$3"
  log_step "$step" "$cmd" "$info"
  eval "$cmd" || { echo "[ERROR] $step 失败"; exit 1; }
}

run_or_fail "1" "apt update && apt install -y ffmpeg libturbojpeg" "install deps"
EOF
mqtt_report "isg/install/$SERVICE_ID/status" '{"status":"installing", "step":"install_dependencies"}'

# -----------------------------------------------------------------------------
#                Home Assistant installation (from init.sh §8)
# -----------------------------------------------------------------------------
mqtt_report "isg/install/$SERVICE_ID/status" '{"status":"installing", "step":"install_homeassistant"}'

proot-distro login "$PROOT_DISTRO" << EOF
# NOTE: Everything below is copied verbatim from init.sh (section 8.*), except
#       the version number which now comes from \$HASS_VERSION and the LOG_FILE
#       path inherited from the outer script.

LOG_FILE="$LOG_FILE"                      # write to servicemanager log folder
HASS_VERSION="$HASS_VERSION"             # injected version variable
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
  eval "\$cmd"
  local code=\$?
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
turbolibversion=\$(pip list | grep 'PyTurboJPEG' | awk '{printf "%s %s ", \$1, \$2}' | sed 's/ \$//')
log_step "8.3" "PyTurboJPEG installed: \$turbolibversion" "8/16,46,74"

log_step "8.4" "pip install homeassistant" "8/16,56,67"
mkdir -p ~/homeassistant
cd ~/homeassistant
run_or_fail "8.4" "pip install homeassistant==\$HASS_VERSION" "8/16,56,67"
log_info "homeassistant version: \$(hass --version)"

log_step "8.5" "Start Home Assistant and wait init complete" "8/16,45,73"
hass &
HASS_PID=$!
log_info "Home Assistant starting with pid:\$HASS_PID"

MAX_TRIES=90
COUNT=0
while [ \$COUNT -lt \$MAX_TRIES ]; do
  log_info "Check Home Assistant status \$((COUNT + 1)) of \$MAX_TRIES..."
  if curl -s --head --request GET "http://127.0.0.1:8123" | grep -q -E "200 OK|302 Found"; then
    log_info "Home Assistant is up now"
    break
  fi
  COUNT=\$((COUNT + 1))
  sleep 60
done

if [ \$COUNT -ge \$MAX_TRIES ]; then
  log_info "[ERROR] Home Assistant did not become available after \$MAX_TRIES attempts. Exiting"
  exit 1
fi

log_step "8.6" "Terminate Home Assistant and install zlib-ng and isal (no-binary)" "8/16,40,77"
kill \$HASS_PID
pip install zlib-ng isal --no-binary :all:
libversion=\$(pip list | grep -E 'zlib-ng|isal' | awk '{printf "%s %s ", \$1, \$2}' | sed 's/ \$//')
log_step "8.6" "zlib-ng & isal installed: \$libversion" "8/16,40,77"

grep -q '^logger:' /root/.homeassistant/configuration.yaml || echo -e '\nlogger:\n  default: critical' >> /root/.homeassistant/configuration.yaml
grep -q 'use_x_frame_options:' /root/.homeassistant/configuration.yaml || echo -e '\nhttp:\n  use_x_frame_options: false' >> /root/.homeassistant/configuration.yaml

log_step "8.99" "Setup HomeAssistant done, version: \$(hass --version)" "8/16,40,77"
EOF

mqtt_report "isg/install/$SERVICE_ID/status" '{"status":"installing", "step":"init_done"}'
log "🛠  Home Assistant core installation finished"

# -----------------------------------------------------------------------------
#                Post‑install  —— start the service via service scripts
# -----------------------------------------------------------------------------
VERSION_STR=$(in_proot "source /root/homeassistant/bin/activate && hass --version")
log "✅ Installation complete, Home Assistant version: $VERSION_STR"

# start service via existing service manager
bash "$SERVICE_DIR/start.sh"

# wait until the service is fully running
MAX_WAIT=600
INTERVAL=5
ELAPSED=0
log "⏳ Waiting for Home Assistant to be running..."

while [ \$ELAPSED -lt \$MAX_WAIT ]; do
  if bash "$SERVICE_DIR/status.sh" --quiet; then
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
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
    log "✅ Home Assistant $HASS_VERSION is running (took ${DURATION}s)"
    exit 0
  fi
  sleep \$INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))
done

mqtt_report "isg/install/$SERVICE_ID/status" '{"status":"failed", "message":"HA service did not start in time."}'
log "❌ Home Assistant did not reach running state within ${MAX_WAIT}s"
exit 1

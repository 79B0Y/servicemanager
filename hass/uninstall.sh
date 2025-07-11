#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

SERVICE_ID="hass"
PROOT_DISTRO="ubuntu"
SERVICE_DIR="/data/data/com.termux/files/home/servicemanager/$SERVICE_ID"
CONFIG_FILE="/data/data/com.termux/files/home/servicemanager/configuration.yaml"
LOG_FILE="$SERVICE_DIR/logs/uninstall.log"
DISABLED_FLAG="$SERVICE_DIR/.disabled"

mkdir -p "$(dirname "$LOG_FILE")"

load_mqtt_conf() {
  MQTT_HOST=$(grep -Po '^[[:space:]]*host:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1)
  MQTT_PORT=$(grep -Po '^[[:space:]]*port:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1)
  MQTT_USER=$(grep -Po '^[[:space:]]*username:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1)
  MQTT_PASS=$(grep -Po '^[[:space:]]*password:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1)
}

mqtt_report() {
  local topic="$1" payload="$2"
  load_mqtt_conf
  mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload" || true
  echo "[MQTT] $topic -> $payload" >> "$LOG_FILE"
}

log() {
  echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"
}

log "🧹 Uninstalling Home Assistant..."
mqtt_report "isg/install/$SERVICE_ID/status" '{"status":"uninstalling"}'

bash "$SERVICE_DIR/stop.sh" || true

proot-distro login "$PROOT_DISTRO" << 'EOF'
log_step() {
  echo -e "\n[STEP] \$1"
}

log_step "🔸 Killing Home Assistant if running"
HASS_PID=\$(pgrep -f "homeassistant/bin/python3 .*hass") && kill "\$HASS_PID" || echo "[INFO] No HA process running"

log_step "🔸 Uninstalling Home Assistant via pip"
source /root/homeassistant/bin/activate && pip uninstall -y homeassistant || echo "[INFO] Not installed"

log_step "🔸 Removing virtualenv /root/homeassistant"
rm -rf /root/homeassistant

log_step "🔸 Removing config /root/.homeassistant"
rm -rf /root/.homeassistant

log_step "✅ Uninstall complete"
EOF

log "🔒 Creating .disabled flag"
touch "$DISABLED_FLAG"

log "📢 MQTT reporting uninstall success"
mqtt_report "isg/install/$SERVICE_ID/status" '{"status":"uninstalled","message":"Home Assistant completely removed."}'

exit 0

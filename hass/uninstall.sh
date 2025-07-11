#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

SERVICE_ID="hass"
SERVICE_DIR="/data/data/com.termux/files/home/servicemanager/$SERVICE_ID"
LOG_FILE="$SERVICE_DIR/logs/uninstall.log"
DISABLED_FLAG="$SERVICE_DIR/.disabled"
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"

mkdir -p "$(dirname "$LOG_FILE")"

mqtt_report() {
  local topic="$1"
  local payload="$2"
  mosquitto_pub -F "$SERVICE_DIR/configuration.yaml" -t "$topic" -m "$payload" || true
  echo "[MQTT] $topic -> $payload" >> "$LOG_FILE"
}

log() {
  echo "[$(date +%F %T)] $*" | tee -a "$LOG_FILE"
}

log "🧹 Begin uninstall of Home Assistant"
mqtt_report "isg/install/$SERVICE_ID/status" '{"status":"uninstalling"}'

# 1. 停止服务
bash "$SERVICE_DIR/stop.sh" || log "⚠️ stop.sh returned non‑zero, continuing with uninstall."

# 2. 进入容器并卸载
if ! proot-distro login "$PROOT_DISTRO" -- bash -c "\
  set -e ; \
  if [ -d /root/homeassistant ]; then \
    source /root/homeassistant/bin/activate && pip uninstall -y homeassistant || true ; \
    rm -rf /root/homeassistant ; \
  fi ; \
  rm -rf /root/.homeassistant ; \
"; then
  mqtt_report "isg/install/$SERVICE_ID/status" '{"status":"failed","message":"Uninstall failed inside container."}'
  log "❌ Uninstall failed inside container."
  exit 1
fi

# 3. 创建 .disabled，防止自动重装/重启
touch "$DISABLED_FLAG"

mqtt_report "isg/install/$SERVICE_ID/status" "$(cat <<EOS
{
  \"service\": \"$SERVICE_ID\",
  \"status\": \"uninstalled\",
  \"message\": \"Home Assistant completely removed.\",
  \"log\": \"$LOG_FILE\",
  \"timestamp\": $(date +%s)
}
EOS
)"

log "✅ Uninstall complete. .disabled flag set."
exit 0

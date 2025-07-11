#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

SERVICE_ID="hass"
SERVICE_DIR="/data/data/com.termux/files/home/servicemanager/$SERVICE_ID"
LOG_FILE="$SERVICE_DIR/logs/update.log"
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
TARGET_VERSION="${1:-${TARGET_VERSION:-2025.7.1}}"

mkdir -p "$(dirname "$LOG_FILE")"

mqtt_report() {
  local topic="$1"; shift
  local payload="$1"
  mosquitto_pub -F "$SERVICE_DIR/configuration.yaml" -t "$topic" -m "$payload" || true
  echo "[MQTT] $topic -> $payload" >> "$LOG_FILE"
}

log() {
  echo "[$(date +%F %T)] $*" | tee -a "$LOG_FILE"
}

log "🆙 Upgrade Home Assistant to $TARGET_VERSION"
mqtt_report "isg/update/$SERVICE_ID/status" '{"status":"updating"}'

# 1) 备份
bash "$SERVICE_DIR/backup.sh" || log "⚠️ backup.sh failed; continuing upgrade."

# 2) 在容器中升级 Home Assistant
if ! proot-distro login "$PROOT_DISTRO" <<EOF
set -e
log_step() { echo -e "\n[STEP] \$1"; }

log_step "激活虚拟环境"
source /root/homeassistant/bin/activate

log_step "升级 ensurepip（确保 pip 可用）"
python -m ensurepip --upgrade

log_step "升级 pip"
pip install --upgrade pip

log_step "升级 Home Assistant 到 $TARGET_VERSION"
pip install --upgrade homeassistant==$TARGET_VERSION

log_step "验证版本"
hass --version | grep -q "$TARGET_VERSION"

log_step "✅ 升级完成"
EOF
then
  mqtt_report "isg/update/$SERVICE_ID/status" '{"status":"failed","message":"Upgrade failed inside container."}'
  log "❌ Upgrade failed."
  exit 1
fi

mqtt_report "isg/update/$SERVICE_ID/status" "$(cat <<JSON
{
  \"service\": \"$SERVICE_ID\",
  \"status\": \"success\",
  \"version\": \"$TARGET_VERSION\",
  \"log\": \"$LOG_FILE\",
  \"timestamp\": $(date +%s)
}
JSON
)"

log "✅ Upgrade succeeded. Restarting service..."
# 3) 重启服务ash "$SERVICE_DIR/stop.sh" || true
bash "$SERVICE_DIR/start.sh"

exit 0

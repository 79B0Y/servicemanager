#!/data/data/com.termux/files/usr/bin/bash

# restore.sh - Restore Home Assistant configuration from latest or given backup
# Path: /data/data/com.termux/files/home/servicemanager/hass/restore.sh

SERVICE_ID="hass"
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
BACKUP_DIR="/sdcard/isgbackup/$SERVICE_ID"
CONFIG_PATH="/data/data/com.termux/files/home/servicemanager/configuration.yaml"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_FILE="$BACKUP_DIR/restore_${TIMESTAMP}.log"
MQTT_TOPIC="isg/restore/$SERVICE_ID/status"

mkdir -p "$BACKUP_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

# Load MQTT config
if ! python3 -c "import yaml" 2>/dev/null; then
  echo "[WARN] PyYAML not installed, using default MQTT config"
  MQTT_HOST="127.0.0.1"
  MQTT_PORT=1883
  MQTT_USERNAME=""
  MQTT_PASSWORD=""
else
  eval $(python3 -c "
import yaml
with open('$CONFIG_PATH') as f:
    mqtt = yaml.safe_load(f).get('mqtt', {})
    for k in ('host', 'port', 'username', 'password'):
        v = mqtt.get(k, '')
        print(f'MQTT_{k.upper()}=\"{v}\"')")
fi

mqtt_report() {
  local status=$1
  local extra=$2
  mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USERNAME" -P "$MQTT_PASSWORD" \
    -t "$MQTT_TOPIC" -m "{\"service\":\"$SERVICE_ID\",\"status\":\"$status\",$extra\"timestamp\":$(date +%s)}" -r -q 1 >/dev/null 2>&1
}

mqtt_report restoring ""

# Stop service
bash ./stop.sh

# Determine backup file
INPUT_BACKUP="$1"
if [[ -n "$INPUT_BACKUP" && -f "$BACKUP_DIR/$INPUT_BACKUP" ]]; then
  FILE="$BACKUP_DIR/$INPUT_BACKUP"
elif FILE=$(ls -t "$BACKUP_DIR"/homeassistant_backup_*.tar.gz 2>/dev/null | head -n1); then
  echo "[INFO] Using latest backup: $FILE"
elif [[ -f "$BACKUP_DIR/homeassistant_original.tar.gz" ]]; then
  FILE="$BACKUP_DIR/homeassistant_original.tar.gz"
  echo "[INFO] Using original image backup: $FILE"
else
  echo "[ERROR] No backup file found"
  mqtt_report failed "\"error\":\"no_backup\",\"message\":\"No backup file available to restore.\",\"log\":\"$LOG_FILE\"," 
  exit 1
fi

# Extract
echo "[INFO] Restoring configuration..."
proot-distro login "$PROOT_DISTRO" -- bash -c "\
  rm -rf /root/.homeassistant && \
  mkdir -p /root/.homeassistant && \
  tar -xzf '$FILE' -C /root"

if [[ $? -ne 0 ]]; then
  echo "[ERROR] Restore failed"
  mqtt_report failed "\"error\":\"tar_failed\",\"message\":\"Failed to extract backup file.\",\"log\":\"$LOG_FILE\"," 
  exit 1
fi

# Start service
bash ./start.sh

mqtt_report success "\"file\":\"$FILE\",\"log\":\"$LOG_FILE\","

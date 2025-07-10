#!/data/data/com.termux/files/usr/bin/bash

# backup.sh - Backup Home Assistant configuration and report status via MQTT
# Path: /data/data/com.termux/files/home/servicemanager/hass/backup.sh

SERVICE_ID="hass"
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
HA_DIR="/root/.homeassistant"
BACKUP_DIR="/sdcard/isgbackup/$SERVICE_ID"
LOG_DIR="$BACKUP_DIR/logs"
KEEP_BACKUPS="${KEEP_BACKUPS:-3}"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/backup.log"
MAX_LINES=100
CONFIG_PATH="/data/data/com.termux/files/home/servicemanager/configuration.yaml"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_FILE="$BACKUP_DIR/homeassistant_backup_${TIMESTAMP}.tar.gz"
MQTT_TOPIC="isg/backup/$SERVICE_ID/status"

exec > >(tee -a "$LOG_FILE") 2>&1
tail -n $MAX_LINES "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"

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

bash ./status.sh --quiet
if [[ $? -ne 0 ]]; then
  echo "[WARN] Service not running. Skipping backup."
  mqtt_report failed "\"error\":\"not_running\",\"message\":\"Home Assistant is not running. Cannot perform backup.\",\"log\":\"$LOG_FILE\"," 
  exit 1
fi

mqtt_report backuping ""
echo "[INFO] Compressing $HA_DIR..."

proot-distro login "$PROOT_DISTRO" -- \
  tar -czf "$BACKUP_FILE" -C /root .homeassistant

if [[ $? -eq 0 ]]; then
  SIZE_KB=$(du -k "$BACKUP_FILE" | cut -f1)
  echo "[OK] Backup completed, size ${SIZE_KB}KB"
  mqtt_report success "\"file\":\"$BACKUP_FILE\",\"size_kb\":$SIZE_KB,\"log\":\"$LOG_FILE\"," 
else
  echo "[ERROR] Backup failed"
  mqtt_report failed "\"error\":\"tar_failed\",\"message\":\"Failed to compress configuration directory.\",\"log\":\"$LOG_FILE\"," 
  exit 1
fi

cd "$BACKUP_DIR"
ls -1t homeassistant_backup_*.tar.gz | tail -n +$((KEEP_BACKUPS + 1)) | xargs -r rm -f
ls -1t logs/backup.log | tail -n +1 | xargs -r true

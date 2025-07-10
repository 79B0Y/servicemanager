#!/data/data/com.termux/files/usr/bin/bash

# backup.sh - 备份 Home Assistant 配置并通过 MQTT 上报状态
# 路径: /data/data/com.termux/files/home/servicemanager/hass/backup.sh

SERVICE_ID="hass"
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
HA_DIR="/root/.homeassistant"
BACKUP_DIR="/sdcard/isgbackup/$SERVICE_ID"
KEEP_BACKUPS="${KEEP_BACKUPS:-3}"
CONFIG_PATH="/data/data/com.termux/files/home/servicemanager/configuration.yaml"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_FILE="$BACKUP_DIR/homeassistant_backup_${TIMESTAMP}.tar.gz"
LOG_FILE="$BACKUP_DIR/backup_${TIMESTAMP}.log"
MQTT_TOPIC="isg/backup/$SERVICE_ID/status"

mkdir -p "$BACKUP_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

# 加载 MQTT 配置（兼容未安装 PyYAML）
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

# 检查运行状态
bash ./status.sh --quiet
if [[ $? -ne 0 ]]; then
  echo "[WARN] Service not running, skipping backup"
  mqtt_report failed "\"error\":\"not_running\",\"message\":\"Home Assistant is not running. Cannot perform backup.\",\"log\":\"$LOG_FILE\"," 
  exit 1
fi

mqtt_report backuping ""
echo "[INFO] Compressing $HA_DIR..."

proot-distro login "$PROOT_DISTRO" -- \
  tar -czf "/sdcard/isgbackup/$SERVICE_ID/homeassistant_backup_${TIMESTAMP}.tar.gz" -C /root .homeassistant

if [[ $? -eq 0 ]]; then
  SIZE_KB=$(du -k "$BACKUP_FILE" | cut -f1)
  echo "[OK] Backup completed, size ${SIZE_KB}KB"
  mqtt_report success "\"file\":\"$BACKUP_FILE\",\"size_kb\":$SIZE_KB,\"log\":\"$LOG_FILE\"," 
else
  echo "[ERROR] Backup failed"
  mqtt_report failed "\"error\":\"tar_failed\",\"message\":\"Failed to compress configuration directory.\",\"log\":\"$LOG_FILE\"," 
  exit 1
fi

# 自动清理旧备份
cd "$BACKUP_DIR"
ls -1t homeassistant_backup_*.tar.gz | tail -n +$((KEEP_BACKUPS + 1)) | xargs -r rm -f
ls -1t backup_*.log | tail -n +$((KEEP_BACKUPS + 1)) | xargs -r rm -f

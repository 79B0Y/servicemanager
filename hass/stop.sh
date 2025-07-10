#!/data/data/com.termux/files/usr/bin/bash

# stop.sh - 停止 Home Assistant 并通过 MQTT 上报状态
# 路径: /data/data/com.termux/files/home/servicemanager/hass/stop.sh

SERVICE_ID="hass"
LSVDIR="/data/data/com.termux/files/usr/var/service"
CONFIG_PATH="/data/data/com.termux/files/home/servicemanager/configuration.yaml"
BACKUP_DIR="/sdcard/isgbackup/$SERVICE_ID"
LOG_FILE="$BACKUP_DIR/stop_$(date +%Y%m%d-%H%M%S).log"
STOP_LOG="$BACKUP_DIR/hass_stoptime.log"
MQTT_TOPIC="isg/run/$SERVICE_ID/status"
MAX_TRIES=30

mkdir -p "$BACKUP_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "[INFO] 停止 Home Assistant..."

# 加载 MQTT 配置
eval $(python3 -c "
import yaml
with open('$CONFIG_PATH') as f:
  mqtt = yaml.safe_load(f).get('mqtt', {})
  print(f'MQTT_HOST={mqtt.get('host','127.0.0.1')}')
  print(f'MQTT_PORT={mqtt.get('port',1883)}')
  print(f'MQTT_USER={mqtt.get('username','')}')
  print(f'MQTT_PASS={mqtt.get('password','')}')
")

mqtt_report() {
  local status=$1
  local payload="{\"status\":\"$status\"}"
  mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" \
    -t "$MQTT_TOPIC" -m "$payload" -r -q 1 >/dev/null 2>&1
}

mqtt_report stoping

echo d > "$LSVDIR/$SERVICE_ID/supervise/control"
echo "[INFO] 已发送停止信号，等待状态确认..."

for ((i=0; i<MAX_TRIES; i++)); do
  sleep 10
  if ! bash ./status.sh --quiet >/dev/null; then
    mqtt_report stopped
    echo "[OK] Home Assistant 已停止"
    echo "[INFO] 日志写入 $STOP_LOG"
    exit 0
  fi
done

echo "[ERROR] Home Assistant 停止失败"
mqtt_report failed
exit 1

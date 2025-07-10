#!/data/data/com.termux/files/usr/bin/bash

# update.sh - 升级或降级 Home Assistant 到指定版本
# 路径: /data/data/com.termux/files/home/servicemanager/hass/update.sh

SERVICE_ID="hass"
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
BACKUP_DIR="/sdcard/isgbackup/$SERVICE_ID"
CONFIG_PATH="/data/data/com.termux/files/home/servicemanager/configuration.yaml"
TARGET_VERSION="${1:-$TARGET_VERSION}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_FILE="$BACKUP_DIR/update_${TIMESTAMP}.log"
MQTT_TOPIC="isg/update/$SERVICE_ID/status"

if [[ -z "$TARGET_VERSION" ]]; then
  echo "[ERROR] 未提供目标版本 TARGET_VERSION"
  exit 1
fi

mkdir -p "$BACKUP_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

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
  local extra=$2
  mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" \
    -t "$MQTT_TOPIC" -m "{\"service\":\"$SERVICE_ID\",\"status\":\"$status\",\"version\":\"$TARGET_VERSION\",$extra\"timestamp\":$(date +%s)}" -r -q 1 >/dev/null 2>&1
}

mqtt_report updating "\"log\":\"$LOG_FILE\"," 

# 停止服务
bash ./stop.sh

# 安装目标版本
proot-distro login "$PROOT_DISTRO" -- bash -c "\
  source /root/homeassistant/bin/activate && \
  pip install --upgrade --no-cache-dir homeassistant==$TARGET_VERSION"

if [[ $? -ne 0 ]]; then
  echo "[ERROR] pip 安装失败"
  mqtt_report failed "\"error\":\"pip_failed\",\"log\":\"$LOG_FILE\"," 
  exit 1
fi

# 重启服务
bash ./start.sh

# 成功上报
mqtt_report success "\"log\":\"$LOG_FILE\","

#!/data/data/com.termux/files/usr/bin/bash

# restore.sh - 还原 Home Assistant 配置并通过 MQTT 上报状态
# 路径: /data/data/com.termux/files/home/servicemanager/hass/restore.sh

SERVICE_ID="hass"
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
BACKUP_DIR="/sdcard/isgbackup/$SERVICE_ID"
CONFIG_PATH="/data/data/com.termux/files/home/servicemanager/configuration.yaml"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_FILE="$BACKUP_DIR/restore_${TIMESTAMP}.log"
MQTT_TOPIC="isg/restore/$SERVICE_ID/status"

mkdir -p "$BACKUP_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

# 获取参数（备份文件）
INPUT_BACKUP="$1"

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
    -t "$MQTT_TOPIC" -m "{\"service\":\"$SERVICE_ID\",\"status\":\"$status\",$extra\"timestamp\":$(date +%s)}" -r -q 1 >/dev/null 2>&1
}

mqtt_report restoring ""

# 停止服务
bash ./stop.sh

# 确定备份文件
if [[ -n "$INPUT_BACKUP" && -f "$BACKUP_DIR/$INPUT_BACKUP" ]]; then
  FILE="$BACKUP_DIR/$INPUT_BACKUP"
elif FILE=$(ls -t "$BACKUP_DIR"/homeassistant_backup_*.tar.gz 2>/dev/null | head -n1); then
  echo "[INFO] 自动选取最新备份: $FILE"
elif [[ -f "$BACKUP_DIR/homeassistant_original.tar.gz" ]]; then
  FILE="$BACKUP_DIR/homeassistant_original.tar.gz"
  echo "[INFO] 使用初始镜像备份: $FILE"
else
  echo "[ERROR] 找不到任何可用备份"
  mqtt_report failed "\"error\":\"no_backup\",\"log\":\"$LOG_FILE\"," 
  exit 1
fi

# 解压还原
echo "[INFO] 开始还原配置..."
proot-distro login "$PROOT_DISTRO" -- bash -c "\
  rm -rf /root/.homeassistant && \
  mkdir -p /root/.homeassistant && \
  tar -xzf '$FILE' -C /root"

if [[ $? -ne 0 ]]; then
  echo "[ERROR] 解压失败"
  mqtt_report failed "\"error\":\"tar_failed\",\"log\":\"$LOG_FILE\"," 
  exit 1
fi

# 启动服务
bash ./start.sh

mqtt_report success "\"file\":\"$FILE\",\"log\":\"$LOG_FILE\","

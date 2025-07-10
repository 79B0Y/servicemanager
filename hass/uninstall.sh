#!/data/data/com.termux/files/usr/bin/bash

# uninstall.sh - 卸载 Home Assistant，清理环境并上报状态
# 路径: /data/data/com.termux/files/home/servicemanager/hass/uninstall.sh

SERVICE_ID="hass"
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
BACKUP_DIR="/sdcard/isgbackup/$SERVICE_ID"
CONFIG_PATH="/data/data/com.termux/files/home/servicemanager/configuration.yaml"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_FILE="$BACKUP_DIR/uninstall_${TIMESTAMP}.log"
MQTT_TOPIC="isg/install/$SERVICE_ID/status"

mkdir -p "$BACKUP_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "[INFO] 开始卸载 Home Assistant..."

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
  mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" \
    -t "$MQTT_TOPIC" -m "{\"service\":\"$SERVICE_ID\",\"status\":\"$status\",\"log\":\"$LOG_FILE\",\"timestamp\":$(date +%s)}" -r -q 1 >/dev/null 2>&1
}

mqtt_report uninstalling

# 确保服务已停止
if bash ./status.sh --quiet; then
  echo "[INFO] 服务正在运行，调用 stop.sh 停止..."
  bash ./stop.sh
else
  echo "[INFO] 服务已处于停止状态"
fi

# 删除虚拟环境与配置
echo "[INFO] 删除虚拟环境与配置目录..."
proot-distro login "$PROOT_DISTRO" -- bash -c "rm -rf /root/homeassistant /root/.homeassistant"

if [[ $? -eq 0 ]]; then
  echo "[OK] 已删除容器内安装目录"
else
  echo "[ERROR] 删除目录失败"
  mqtt_report failed
  exit 1
fi

# 标记为禁用，防止 autocheck 自动重装
touch .disabled

mqtt_report uninstalled

echo "[DONE] 卸载完成。日志写入 $LOG_FILE"
exit 0

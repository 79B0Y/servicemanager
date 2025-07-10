#!/data/data/com.termux/files/usr/bin/bash

# install.sh - 安装 Home Assistant 至 proot Ubuntu 容器并通过 MQTT 上报状态
# 路径: /data/data/com.termux/files/home/servicemanager/hass/install.sh

SERVICE_ID="hass"
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
HASS_VERSION="${HASS_VERSION:-2025.5.3}"
BACKUP_DIR="/sdcard/isgbackup/$SERVICE_ID"
CONFIG_PATH="/data/data/com.termux/files/home/servicemanager/configuration.yaml"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_FILE="$BACKUP_DIR/install_${TIMESTAMP}.log"
MQTT_TOPIC="isg/install/$SERVICE_ID/status"

mkdir -p "$BACKUP_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "[INFO] 开始安装 Home Assistant v$HASS_VERSION..."

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

mqtt_report installing ""

proot-distro login "$PROOT_DISTRO" -- bash -c "set -e
  echo '[STEP] 更新系统依赖'
  apt update && apt install -y ffmpeg libturbojpeg

  echo '[STEP] 创建虚拟环境 /root/homeassistant'
  python3 -m venv /root/homeassistant

  echo '[STEP] 安装基础依赖与 Home Assistant'
  source /root/homeassistant/bin/activate && \
  pip install --upgrade pip && \
  pip install numpy pillow mutagen aiohttp==3.10.8 attrs==23.2.0 PyTurboJPEG && \
  pip install homeassistant==$HASS_VERSION

  echo '[STEP] 首次启动以生成配置'
  nohup bash -c 'source /root/homeassistant/bin/activate && hass' > /root/hass_runtime.log 2>&1 &
  for i in $(seq 1 90); do
    sleep 60
    nc -z 127.0.0.1 8123 && break
  done || exit 1

  echo '[STEP] 杀掉初始化进程'
  pkill -f hass || true

  echo '[STEP] 安装压缩库'
  source /root/homeassistant/bin/activate && pip install zlib-ng isal --no-binary :all:

  echo '[STEP] 配置 configuration.yaml'
  grep -q '^logger:' /root/.homeassistant/configuration.yaml || echo -e '\nlogger:\n  default: critical' >> /root/.homeassistant/configuration.yaml
  grep -q 'use_x_frame_options:' /root/.homeassistant/configuration.yaml || echo -e '\nhttp:\n  use_x_frame_options: false' >> /root/.homeassistant/configuration.yaml
"

if [[ $? -eq 0 ]]; then
  VERSION_STR=$(proot-distro login "$PROOT_DISTRO" -- bash -c "source /root/homeassistant/bin/activate && hass --version")
  echo "[OK] 安装成功，版本: $VERSION_STR"
  mqtt_report success "\"version\":\"$VERSION_STR\",\"log\":\"$LOG_FILE\"," 
else
  echo "[ERROR] 安装失败"
  mqtt_report failed "\"error\":\"install_failed\",\"log\":\"$LOG_FILE\"," 
  exit 1
fi

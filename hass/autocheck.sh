#!/data/data/com.termux/files/usr/bin/bash

# autocheck.sh - Home Assistant 自愈脚本
# 路径: /data/data/com.termux/files/home/servicemanager/hass/autocheck.sh

SERVICE_ID="hass"
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
BACKUP_DIR="/sdcard/isgbackup/$SERVICE_ID"
CONFIG_PATH="/data/data/com.termux/files/home/servicemanager/configuration.yaml"
VERSION_FILE="VERSION"
DISABLED_FILE=".disabled"
MAX_FAILS="${AC_MAX_FAILS:-3}"
UPDATE_INTERVAL="${AC_UPDATE_INTERVAL:-21600}"
FAIL_COUNT_FILE=".failcount"
LAST_UPDATE_FILE=".lastupdate"
LOG_FILE="$BACKUP_DIR/autocheck_$(date +%Y%m%d-%H%M%S).log"
MQTT_TOPIC="isg/status/$SERVICE_ID/status"

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
  mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" \
    -t "$MQTT_TOPIC" -m "{\"status\":\"$status\"}" -r -q 1 >/dev/null 2>&1
}

mqtt_report config

[[ -f "$DISABLED_FILE" ]] && { mqtt_report disabled; exit 0; }

[[ ! -f "$VERSION_FILE" ]] && { bash ./install.sh || mqtt_report failed; exit 1; }

if [[ ! -d "/data/data/com.termux/files/usr/var/service/$SERVICE_ID" ]]; then
  bash ./restore.sh || { mqtt_report failed; exit 1; }
fi

bash ./status.sh --quiet
if [[ $? -eq 0 ]]; then
  mqtt_report running
  echo 0 > "$FAIL_COUNT_FILE"
else
  bash ./start.sh
  sleep 10
  bash ./status.sh --quiet
  if [[ $? -eq 0 ]]; then
    mqtt_report recovered
    echo 0 > "$FAIL_COUNT_FILE"
  else
    fails=$(cat "$FAIL_COUNT_FILE" 2>/dev/null || echo 0)
    fails=$((fails+1))
    echo $fails > "$FAIL_COUNT_FILE"
    if [[ $fails -ge $MAX_FAILS ]]; then
      mqtt_report permanent_failed
    else
      mqtt_report failed
    fi
  fi
fi

# 检查是否需要更新
now=$(date +%s)
last=$(cat "$LAST_UPDATE_FILE" 2>/dev/null || echo 0)
diff=$((now - last))
if [[ $diff -ge $UPDATE_INTERVAL && -n "$TARGET_VERSION" ]]; then
  bash ./update.sh "$TARGET_VERSION" && echo $now > "$LAST_UPDATE_FILE"
fi

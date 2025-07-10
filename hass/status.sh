#!/data/data/com.termux/files/usr/bin/bash

# status.sh - 检查 Home Assistant 当前状态并通过 MQTT 上报
# 脚本路径: /data/data/com.termux/files/home/servicemanager/hass/status.sh

CONFIG_PATH="/data/data/com.termux/files/home/servicemanager/configuration.yaml"
SERVICE_ID="hass"
MQTT_TOPIC="isg/status/$SERVICE_ID/status"
MQTT_TIMEOUT=${MQTT_TIMEOUT:-5}

# 加载 MQTT 配置
eval $(python3 -c "
import yaml
with open('$CONFIG_PATH') as f:
  cfg = yaml.safe_load(f)
  mqtt = cfg.get('mqtt', {})
  print(f'MQTT_HOST={mqtt.get("host", "127.0.0.1")}')
  print(f'MQTT_PORT={mqtt.get("port", 1883)}')
  print(f'MQTT_USER={mqtt.get("username", "")}')
  print(f'MQTT_PASS={mqtt.get("password", "")}')
")

get_runtime_minutes() {
  local pid=$1
  local etime=$(ps -o etimes= -p "$pid" 2>/dev/null)
  echo "${etime:-0}"
}

report_status() {
  local status=$1
  local pid=$2
  local runtime=$3
  local port_ok=$4
  local payload="{\"status\":\"$status\",\"pid\":$pid,\"runtime_min\":$runtime,\"port_ok\":$port_ok}"
  mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" \
    -u "$MQTT_USER" -P "$MQTT_PASS" \
    -t "$MQTT_TOPIC" -m "$payload" -r -q 1 -W $MQTT_TIMEOUT >/dev/null 2>&1
}

quiet=0
json=0
for arg in "$@"; do
  [[ "$arg" == "--quiet" ]] && quiet=1
  [[ "$arg" == "--json" ]] && json=1
done

pid=$(pgrep -f "[h]omeassistant")
if [[ -n "$pid" ]]; then
  runtime=$(get_runtime_minutes $pid)
  if nc -z 127.0.0.1 8123 >/dev/null 2>&1; then
    status="running"
    code=0
    port_ok=true
  else
    status="starting"
    code=2
    port_ok=false
  fi
else
  status="stopped"
  code=1
  pid=0
  runtime=0
  port_ok=false
fi

report_status "$status" "$pid" "$runtime" "$port_ok"

if [[ $json -eq 1 ]]; then
  echo "{\"status\":\"$status\",\"pid\":$pid,\"runtime\":${runtime} mins}"
elif [[ $quiet -eq 0 ]]; then
  echo "$status"
fi

exit $code

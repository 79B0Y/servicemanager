#!/data/data/com.termux/files/usr/bin/bash

# status.sh - 检查 Home Assistant 当前状态并通过 MQTT 上报
# 路径: /data/data/com.termux/files/home/servicemanager/hass/status.sh

CONFIG_PATH="/data/data/com.termux/files/home/servicemanager/configuration.yaml"
SERVICE_ID="hass"
MQTT_TOPIC="isg/status/$SERVICE_ID/status"

# 加载 MQTT 配置（兼容未安装 PyYAML 的情况）
if ! python3 -c "import yaml" 2>/dev/null; then
  echo "[WARN] PyYAML 未安装，使用默认 MQTT 配置"
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
  local payload="{\"service\":\"$SERVICE_ID\",\"status\":\"$status\",\"pid\":$pid,\"runtime_min\":$runtime,\"port_ok\":$port_ok,\"timestamp\":$(date +%s)}"
  echo "[DEBUG] MQTT Payload: $payload"
  mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" \
    -u "$MQTT_USERNAME" -P "$MQTT_PASSWORD" \
    -t "$MQTT_TOPIC" -m "$payload" -r -q 1 >/dev/null 2>&1
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

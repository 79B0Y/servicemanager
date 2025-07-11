#!/data/data/com.termux/files/usr/bin/bash

LOCK_FILE="/data/data/com.termux/files/usr/var/lock/autocheckall.lock"
SERVICEMANAGER_DIR="${SERVICEMANAGER_DIR:-/data/data/com.termux/files/home/servicemanager}"
SERVICE_DIR="/data/data/com.termux/files/usr/etc/service"
MQTT_CONFIG="$SERVICEMANAGER_DIR/configuration.yaml"

log_info()  { echo "[INFO] $1"; }
log_warn()  { echo "[WARN] $1"; }
log_error() { echo "[ERROR] $1"; }

mqtt_report() {
  local topic="$1"
  local payload="$2"
  mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" \
    -t "$topic" -m "$payload" \
    ${MQTT_USER:+-u "$MQTT_USER"} ${MQTT_PASS:+-P "$MQTT_PASS"}
}

load_mqtt_config() {
  MQTT_HOST=$(grep -A5 '^mqtt:' "$MQTT_CONFIG" | grep 'host:' | awk '{print $2}')
  MQTT_PORT=$(grep -A5 '^mqtt:' "$MQTT_CONFIG" | grep 'port:' | awk '{print $2}')
  MQTT_USER=$(grep -A5 '^mqtt:' "$MQTT_CONFIG" | grep 'username:' | awk '{print $2}')
  MQTT_PASS=$(grep -A5 '^mqtt:' "$MQTT_CONFIG" | grep 'password:' | awk '{print $2}')
}

# ========== 主体开始 ==========
(
  flock -n 200 || {
    log_warn "检测到已有 autocheckall.sh 实例运行，退出"
    exit 1
  }

  load_mqtt_config

  # 1. 检查 runsvdir 是否运行
  if ! pgrep -f runsvdir >/dev/null; then
    if pgrep -f "com.termux.*isgservicemonitor" >/dev/null; then
      runsvdir_status="assumed_by_isgservicemonitor"
    else
      runsvdir -P "$SERVICE_DIR" &
      sleep 2
      runsvdir_status=$(pgrep -f runsvdir >/dev/null && echo "restarted" || echo "failed")
    fi
  else
    runsvdir_status="running"
  fi
  mqtt_report "isg/system/runit/status" "{\"runsvdir\": \"$runsvdir_status\"}"

  # 2. 检查服务目录配置
  missing_services=()
  for d in "$SERVICE_DIR"/*; do
    [ -d "$d" ] && [ ! -x "$d/run" ] && chmod +x "$d/run" && missing_services+=("$(basename "$d")")
  done
  service_valid=true
  [ ${#missing_services[@]} -gt 0 ] && service_valid=false
  mqtt_report "isg/system/runit/service_dir" "{\"valid\": $service_valid, \"missing_services\": [\"${missing_services[*]}\"]}"

  # 3. 检查 runsv 状态
  supervision_report="{"
  for svc in isgservicemonitor sshd mysqld; do
    status=$(sv status "$svc" 2>&1 || true)
    case "$status" in
      *"run"*)  state="run" ;;
      *"down"*) state="down" ;;
      *)        state="invalid" ;;
    esac
    supervision_report="$supervision_report\"$svc\":\"$state\"," 
  done
  supervision_report="${supervision_report%,}}"
  mqtt_report "isg/system/runit/supervision" "$supervision_report"

  # 4. 检查并启动 isgservicemonitor
  if ! pgrep -f "com.termux.*isgservicemonitor" >/dev/null; then
    for i in {1..3}; do
      sv start isgservicemonitor
      sleep 5
      pgrep -f "com.termux.*isgservicemonitor" >/dev/null && break
    done
    if ! pgrep -f "com.termux.*isgservicemonitor" >/dev/null; then
      mqtt_report "isg/system/isgservicemonitor/start" '{"status": "failed", "attempts": 3}'
      if [ ! -f /data/data/com.termux/files/usr/var/termuxservice/isgservicemonitor/isgservicemonitor ]; then
        wget --no-check-certificate https://eucfg.linklinkiot.com/isg/isgservicemonitor_latest_termux_arm.deb -O isgservicemonitor.deb
        dpkg -i isgservicemonitor.deb
        pid=$(pgrep -f 'runsv isgservicemonitor')
        { ps -o pid= --ppid "$pid" | xargs -r kill -9; kill -9 "$pid"; } 2>/dev/null
        for i in {1..3}; do
          sv start isgservicemonitor
          sleep 5
          pgrep -f "com.termux.*isgservicemonitor" >/dev/null && break
        done
        if ! pgrep -f "com.termux.*isgservicemonitor" >/dev/null; then
          mqtt_report "isg/system/isgservicemonitor/install" '{"status": "failed", "reinstall_attempted": true}'
        fi
      fi
    fi
  fi

  # 5. 上报 isgservicemonitor 最终状态
  status_out=$(sv status isgservicemonitor 2>&1)
  if [[ "$status_out" =~ "run" ]]; then
    pid=$(pgrep -f "com.termux.*isgservicemonitor")
    uptime=$(ps -o etime= -p "$pid" | xargs)
    mqtt_report "isg/system/isgservicemonitor/final_status" "{\"status\": \"running\", \"pid\": $pid, \"uptime\": \"$uptime\"}"
  else
    mqtt_report "isg/system/isgservicemonitor/final_status" "{\"status\": \"stopped\"}"
  fi

  # 6. 执行所有子服务的 autocheck.sh
  find "$SERVICEMANAGER_DIR" -type f -name autocheck.sh -exec chmod +x {} \;
  declare -A versions
  for path in "$SERVICEMANAGER_DIR"/*; do
    [ -f "$path/autocheck.sh" ] || continue
    sid=$(basename "$path")
    [[ ",${SKIP_SERVICES}," =~ ",$sid," ]] && continue
    bash "$path/autocheck.sh"
    ver_file="$path/VERSION"
    [ -f "$ver_file" ] && ver=$(cat "$ver_file") || ver="unknown"
    versions["$sid"]="$ver"
  done

  # 汇总上报服务版本
  ts=$(date +%s)
  json_versions="{\"timestamp\": $ts, \"services\": {"
  for sid in "${!versions[@]}"; do
    json_versions="$json_versions\"$sid\":{\"version\":\"${versions[$sid]}\"},"
  done
  json_versions="${json_versions%,}}}"
  mqtt_report "isg/status/versions" "$json_versions"

) 200>"$LOCK_FILE"

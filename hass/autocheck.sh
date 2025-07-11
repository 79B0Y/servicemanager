#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

SERVICE_ID="hass"
SERVICE_DIR="/data/data/com.termux/files/home/servicemanager/$SERVICE_ID"
LOCK_FILE="/var/lock/${SERVICE_ID}_autocheck.lock"
VERSION_FILE="$SERVICE_DIR/VERSION.yaml"
DISABLED_FLAG="$SERVICE_DIR/.disabled"
LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/autocheck_$(date +%Y%m%d-%H%M%S).log"

PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
BACKUP_DIR="${BACKUP_DIR:-/sdcard/isgbackup/$SERVICE_ID}"
AC_MAX_FAILS="${AC_MAX_FAILS:-3}"
AC_UPDATE_INTERVAL="${AC_UPDATE_INTERVAL:-21600}"
FAIL_COUNT_FILE="$SERVICE_DIR/.failcount"
LAST_UPDATE_FILE="$SERVICE_DIR/.lastupdate"
TARGET_VERSION="${TARGET_VERSION:-}"

mkdir -p "$LOG_DIR"

CONFIG_FILE="/data/data/com.termux/files/home/servicemanager/configuration.yaml"
load_mqtt_conf() {
  MQTT_HOST=$(grep -Po '^[[:space:]]*host:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1)
  MQTT_PORT=$(grep -Po '^[[:space:]]*port:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1)
  MQTT_USER=$(grep -Po '^[[:space:]]*username:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1)
  MQTT_PASS=$(grep -Po '^[[:space:]]*password:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1)
}

mqtt_report() {
  local topic="$1"
  local payload="$2"
  load_mqtt_conf
  mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload" || true
  echo "[MQTT] $topic -> $payload" >> "$LOG_FILE"
}

log() {
  echo "[$(date +%F\ %T)] $*" | tee -a "$LOG_FILE"
}

exec 200>"$LOCK_FILE"
flock -n 200 || {
  log "Another instance is running. Exit."
  exit 0
}

log "🔍 Start Home Assistant autocheck"
mqtt_report "isg/autocheck/$SERVICE_ID/status" '{"status":"config"}'

if [ -f "$DISABLED_FLAG" ]; then
  log "⚠️ Detected .disabled flag, skip autocheck"
  mqtt_report "isg/autocheck/$SERVICE_ID/status" '{"status":"disabled","message":"Autocheck disabled manually."}'
  exit 0
fi

if [ ! -f "$VERSION_FILE" ]; then
  log "📦 Missing VERSION.yaml, try install..."
  bash "$SERVICE_DIR/install.sh" || {
    mqtt_report "isg/autocheck/$SERVICE_ID/status" '{"status":"failed","message":"Install failed."}'
    exit 1
  }
fi

if [ ! -d "$SERVICE_DIR" ] || [ ! -f "$SERVICE_DIR/start.sh" ]; then
  log "🔧 Service script missing, try restore"
  bash "$SERVICE_DIR/restore.sh" || {
    mqtt_report "isg/autocheck/$SERVICE_ID/status" '{"status":"failed","message":"Restore failed."}'
    exit 1
  }
fi

if bash "$SERVICE_DIR/status.sh" --quiet; then
  log "✅ Home Assistant is running"
  mqtt_report "isg/autocheck/$SERVICE_ID/status" '{"status":"running"}'
  echo 0 > "$FAIL_COUNT_FILE"
else
  log "🚫 Home Assistant not running, try start"
  for i in {1..3}; do
    bash "$SERVICE_DIR/start.sh"
    sleep 10
    if bash "$SERVICE_DIR/status.sh" --quiet; then
      log "✅ Recovered successfully"
      mqtt_report "isg/autocheck/$SERVICE_ID/status" '{"status":"recovered"}'
      echo 0 > "$FAIL_COUNT_FILE"
      break
    fi
  done

  if ! bash "$SERVICE_DIR/status.sh" --quiet; then
    FAIL_COUNT=$(cat "$FAIL_COUNT_FILE" 2>/dev/null || echo 0)
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "$FAIL_COUNT" > "$FAIL_COUNT_FILE"
    if [ "$FAIL_COUNT" -ge "$AC_MAX_FAILS" ]; then
      log "❌ Start failed $FAIL_COUNT times, reinstall..."
      mqtt_report "isg/autocheck/$SERVICE_ID/status" '{"status":"permanent_failed","message":"Exceeded start retry threshold."}'
      bash "$SERVICE_DIR/install.sh" && bash "$SERVICE_DIR/restore.sh" && bash "$SERVICE_DIR/start.sh"
      echo 0 > "$FAIL_COUNT_FILE"
    else
      mqtt_report "isg/autocheck/$SERVICE_ID/status" '{"status":"failed","message":"Start failed."}'
      exit 1
    fi
  fi
fi

HASS_PID=$(pgrep -f '[h]omeassistant' || true)
if [ -n "$HASS_PID" ]; then
  CPU_USAGE=$(top -b -n 1 -p "$HASS_PID" | grep "$HASS_PID" | awk '{print $9}')
  MEM_USAGE=$(top -b -n 1 -p "$HASS_PID" | grep "$HASS_PID" | awk '{print $10}')
  RSS_KB=$(awk '/VmRSS/ {print $2}' /proc/$HASS_PID/status 2>/dev/null)
  UPTIME=$(ps -o etime= -p "$HASS_PID" | xargs)
  PERF_JSON=$(cat <<EOF
{
  "service": "$SERVICE_ID",
  "status": "running",
  "pid": $HASS_PID,
  "cpu": "$CPU_USAGE",
  "mem": "$MEM_USAGE",
  "rss_kb": "$RSS_KB",
  "uptime": "$UPTIME",
  "timestamp": $(date +%s)
}
EOF
  )
  mqtt_report "isg/status/$SERVICE_ID/performance" "$PERF_JSON"
  log "📊 Reported performance: $PERF_JSON"
else
  log "⚠️ Unable to get performance info: PID not found"
fi

if [ -n "$TARGET_VERSION" ]; then
  NOW=$(date +%s)
  LAST_UPDATE=$(cat "$LAST_UPDATE_FILE" 2>/dev/null || echo 0)
  ELAPSED=$((NOW - LAST_UPDATE))
  if [ "$ELAPSED" -ge "$AC_UPDATE_INTERVAL" ]; then
    log "🆙 Target version: $TARGET_VERSION, starting update..."
    export TARGET_VERSION
    bash "$SERVICE_DIR/update.sh" && {
      echo "$NOW" > "$LAST_UPDATE_FILE"
    }
  else
    log "⏳ Update interval not reached. Skip update."
  fi
fi

log "✅ Autocheck completed"
exit 0

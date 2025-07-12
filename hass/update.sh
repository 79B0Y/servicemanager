#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

SERVICE_ID="hass"
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"

SERVICE_DIR="/data/data/com.termux/files/home/servicemanager/$SERVICE_ID"
CONFIG_FILE="/data/data/com.termux/files/home/servicemanager/configuration.yaml"
LOG_FILE="$SERVICE_DIR/logs/update.log"
VERSION_FILE="$SERVICE_DIR/VERSION"

mkdir -p "$(dirname "$LOG_FILE")"
START_TIME=$(date +%s)

###############################################################################
# 共用函数
###############################################################################
load_mqtt_conf() {
  MQTT_HOST=$(grep -Po '^[[:space:]]*host:[[:space:]]*\K.*' "$CONFIG_FILE"  | head -n1)
  MQTT_PORT=$(grep -Po '^[[:space:]]*port:[[:space:]]*\K.*' "$CONFIG_FILE"  | head -n1)
  MQTT_USER=$(grep -Po '^[[:space:]]*username:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1)
  MQTT_PASS=$(grep -Po '^[[:space:]]*password:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1)
}

mqtt_report() {
  local topic="$1" payload="$2"
  load_mqtt_conf
  mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" \
                -t "$topic" -m "$payload" || true
  echo "[MQTT] $topic -> $payload" >> "$LOG_FILE"
}

log() {
  echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"
}

###############################################################################
# 参数校验 & 版本->依赖映射
###############################################################################
if [ -z "${TARGET_VERSION:-}" ]; then
  log "❌ TARGET_VERSION not set, abort."
  mqtt_report "isg/update/$SERVICE_ID/status" \
              '{"status":"failed","message":"Missing TARGET_VERSION."}'
  exit 1
fi

# 针对特定版本定义额外依赖；如需扩展，继续加 case 分支即可
EXTRA_PIP_PKGS=""
case "$TARGET_VERSION" in
  2025.7.1) EXTRA_PIP_PKGS="click==8.1.7";;
  # 例：2025.8.0) EXTRA_PIP_PKGS="somepkg==1.2.3 otherpkg>=2.0";;
esac

log "⬆️ Updating Home Assistant to $TARGET_VERSION"
mqtt_report "isg/update/$SERVICE_ID/status" \
            "{\"status\":\"updating\",\"timestamp\":$(date +%s)}"

###############################################################################
# 执行升级（进入 proot 容器）
###############################################################################
proot-distro login "$PROOT_DISTRO" << EOF
# ----------  容器内脚本开始 ----------
set -euo pipefail

# 把外部的值显式带进容器，哪怕是空字符串也能避免 set -u 报错
export EXTRA_PIP_PKGS="${EXTRA_PIP_PKGS:-}"
export TARGET_VERSION="$TARGET_VERSION"

source /root/homeassistant/bin/activate

python -m ensurepip --upgrade 2>&1 | tee /tmp/update_step_ensurepip.log
pip install --upgrade pip          2>&1 | tee /tmp/update_step_pip.log

if [ -n "$EXTRA_PIP_PKGS" ]; then
  echo "🔧 Installing extra deps: \$EXTRA_PIP_PKGS"
  pip install \$EXTRA_PIP_PKGS     2>&1 | tee /tmp/update_step_extra.log
fi

pip install --upgrade "homeassistant==$TARGET_VERSION" \
                                 2>&1 | tee /tmp/update_step_ha.log

hass --version > /tmp/hass_version.txt
deactivate
# ----------  容器内脚本结束 ----------
EOF

###############################################################################
# 提取并上报步骤日志
###############################################################################
for step in ensurepip pip extra ha; do
  LOG_PATH="/data/data/com.termux/files/usr/tmp/update_step_${step}.log"
  if [ -f "$LOG_PATH" ]; then
    tail -n 100 "$LOG_PATH" | mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" \
         -u "$MQTT_USER" -P "$MQTT_PASS" \
         -t "isg/update/$SERVICE_ID/status/$step" -l || true
    cat "$LOG_PATH" >> "$LOG_FILE"
    rm -f "$LOG_PATH"
  fi
done

###############################################################################
# 版本校验
###############################################################################
UPDATED_VERSION=$(proot-distro login "$PROOT_DISTRO" \
                   -- cat /tmp/hass_version.txt | head -n1 | tr -d '\r')

if [ "$UPDATED_VERSION" != "$TARGET_VERSION" ]; then
  log "❌ Version mismatch: expected $TARGET_VERSION, got $UPDATED_VERSION"
  mqtt_report "isg/update/$SERVICE_ID/status" \
              "{\"status\":\"failed\",\"message\":\"Version mismatch ($UPDATED_VERSION)\"}"
  exit 1
fi

###############################################################################
# 重启服务并健康检查
###############################################################################
bash "$SERVICE_DIR/stop.sh"
sleep 5
bash "$SERVICE_DIR/start.sh"

MAX_WAIT=300
INTERVAL=5
WAITED=0
log "⏳ Waiting for Home Assistant to start..."

while [ "$WAITED" -lt "$MAX_WAIT" ]; do
  if bash "$SERVICE_DIR/status.sh" --quiet; then
    DURATION=$(( $(date +%s) - START_TIME ))
    log "✅ Service is running after ${WAITED}s"
    mqtt_report "isg/update/$SERVICE_ID/status" \
                "{\"service\":\"$SERVICE_ID\",\"status\":\"success\",\"version\":\"$TARGET_VERSION\",\"duration\":$DURATION,\"timestamp\":$(date +%s)}"
    exit 0
  fi
  sleep "$INTERVAL"
  WAITED=$((WAITED + INTERVAL))
done

log "❌ Timeout: service not running after ${MAX_WAIT}s"
mqtt_report "isg/update/$SERVICE_ID/status" \
            "{\"status\":\"failed\",\"message\":\"Timeout waiting for service start.\",\"timestamp\":$(date +%s)}"
exit 1

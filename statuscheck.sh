#!/data/data/com.termux/files/usr/bin/bash
# statuscheck.sh: 检查所有服务状态（支持 STATUS_MODE），双 MQTT 上报
set -euo pipefail

SERVICEMANAGER_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICEUPDATE_FILE="$SERVICEMANAGER_DIR/serviceupdate.json"
CONFIG_FILE="$SERVICEMANAGER_DIR/configuration.yaml"

STATUS_MODE="${STATUS_MODE:-0}"  # 0=全查，1=只查运行，2=只查安装

log() { echo "[$(date +'%F %T')] $*"; }

load_mqtt_config() {
    MQTT_HOST=$(yq eval '.mqtt.host' "$CONFIG_FILE" 2>/dev/null || echo "127.0.0.1")
    MQTT_PORT=$(yq eval '.mqtt.port' "$CONFIG_FILE" 2>/dev/null || echo "1883")
    MQTT_USER=$(yq eval '.mqtt.username' "$CONFIG_FILE" 2>/dev/null || echo "admin")
    MQTT_PASS=$(yq eval '.mqtt.password' "$CONFIG_FILE" 2>/dev/null || echo "admin")
}

mqtt_report() {
    local topic="$1" payload="$2"
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload" 2>/dev/null || log "⚠️ MQTT 上报失败: $topic"
}

check_service_status() {
    local service_id="$1"
    local service_path="$SERVICEMANAGER_DIR/$service_id"
    local status="unknown"
    local install="false"
    local version="unknown"

    if [ ! -f "$service_path/status.sh" ]; then
        log "⚠️  $service_id 缺少 status.sh"
        echo "$status,$install,$version"
        return
    fi

    chmod +x "$service_path/status.sh" 2>/dev/null || true
    case "$STATUS_MODE" in
        0|1)
            output=$(bash "$service_path/status.sh" --json 2>/dev/null || echo '{}')
            json_output=$(echo "$output" | grep -o '{.*}' | tail -n1)
            if [ -n "$json_output" ]; then
                status=$(echo "$json_output" | jq -r '.status // "unknown"')
                install=$(echo "$json_output" | jq -r '.install // false')
                version=$(echo "$json_output" | jq -r '.version // "unknown"')

                # STATUS_MODE=1 只看运行，running就标true+version=running
                if [[ "$STATUS_MODE" == "1" && "$status" == "running" ]]; then
                    install=true
                    version="running"
                fi
            fi
            ;;
        2)
            install=$(bash "$service_path/status.sh" --check-install 2>/dev/null || echo "false")
            ;;
    esac

    echo "$status,$install,$version"
}

log "🚀 启动 statuscheck.sh STATUS_MODE=$STATUS_MODE"
load_mqtt_config

services=$(jq -r '.services[].id' "$SERVICEUPDATE_FILE")
declare -A status_map

for service_id in $services; do
    result=$(check_service_status "$service_id")
    IFS=',' read -r status install version <<< "$result"

    if [[ "$STATUS_MODE" -lt 2 && "$status" == "stopped" ]]; then
        log "🔄 $service_id 运行状态stopped，补查安装状态..."
        backup_mode="$STATUS_MODE"
        STATUS_MODE=2
        result2=$(check_service_status "$service_id")
        STATUS_MODE=$backup_mode
        install=$(echo "$result2" | cut -d',' -f2)
    fi

    status_map["$service_id"]="{\"status\":\"$status\",\"install\":$install,\"version\":\"$version\"}"
done

# 拼装JSON
report="{"
for sid in "${!status_map[@]}"; do
    report+="\"$sid\":${status_map[$sid]},"
done
report="${report%,}}"

# 双MQTT上报
mqtt_report "isg/status/all/status" "$report"
mqtt_report "isg/status/all/status/confirm" "$report"

log "✅ 服务状态已上报：isg/status/all/status + confirm"
exit 0

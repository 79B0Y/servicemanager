#!/data/data/com.termux/files/usr/bin/bash
# statuscheck.sh: 快速检查所有服务的状态与安装状态，并上报 MQTT

set -euo pipefail

SERVICEMANAGER_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICEUPDATE_FILE="$SERVICEMANAGER_DIR/serviceupdate.json"
CONFIG_FILE="$SERVICEMANAGER_DIR/configuration.yaml"

log() {
    echo "[$(date +'%F %T')] $*"
}

load_mqtt_config() {
    log "🔧 加载 MQTT 配置..."
    MQTT_HOST=$(yq eval '.mqtt.host' "$CONFIG_FILE" 2>/dev/null || echo "127.0.0.1")
    MQTT_PORT=$(yq eval '.mqtt.port' "$CONFIG_FILE" 2>/dev/null || echo "1883")
    MQTT_USER=$(yq eval '.mqtt.username' "$CONFIG_FILE" 2>/dev/null || echo "admin")
    MQTT_PASS=$(yq eval '.mqtt.password' "$CONFIG_FILE" 2>/dev/null || echo "admin")
    log "✅ MQTT配置: host=$MQTT_HOST, port=$MQTT_PORT, user=$MQTT_USER"
}

mqtt_report() {
    local topic="$1"
    local payload="$2"
    log "📡 MQTT 上报: topic=$topic payload=$payload"
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload" 2>/dev/null || log "⚠️ MQTT 上报失败"
}

check_services_status() {
    log "🔍 开始检查所有服务状态..."
    local services=$(jq -r '.services[].id' "$SERVICEUPDATE_FILE")
    local report="{"

    for service_id in $services; do
        local service_path="$SERVICEMANAGER_DIR/$service_id"
        local status="unknown"
        local install="false"

        log "➡️ 检查服务: $service_id"
        if [ -f "$service_path/status.sh" ]; then
            chmod +x "$service_path/status.sh" 2>/dev/null || true
            output=$(bash "$service_path/status.sh" --json 2>/dev/null || echo '{}')
            log "🗒️  $service_id status.sh 输出: $output"

            # 只保留 output 中的 JSON 部分（去除多余的日志行）
            json_output=$(echo "$output" | grep -o '{.*}' | tail -n1)

            if [ -n "$json_output" ]; then
                status=$(echo "$json_output" | jq -r '.status // "unknown"')
                install=$(echo "$json_output" | jq -r '.install // false')
                log "🔎 JSON解析: status=$status, install=$install"

                # 如果系统正在运行且 install 为 false，强制设为 true
                if [[ "$status" == "running" && "$install" != "true" ]]; then
                    log "🔄  $service_id 运行中，但 install=false，修正为 true"
                    install="true"
                fi
            else
                log "⚠️  $service_id 返回的 JSON 无法解析，status/install 不可用"
            fi
        else
            log "⚠️  $service_id 缺少 status.sh 文件"
            status="not_found"
        fi

        log "✅  $service_id 最终状态: status=$status, install=$install"
        report+="\"$service_id\":{\"status\":\"$status\",\"install\":$install},"
    done

    report="${report%,}}"
    mqtt_report "isg/status/all/status" "$report"
    log "✅ 所有服务状态已上报"
}

log "🚀 启动 statuscheck.sh"
load_mqtt_config
check_services_status
log "🏁 statuscheck.sh 执行完成"

exit 0

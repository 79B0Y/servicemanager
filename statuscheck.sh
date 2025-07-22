#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# LinknLink Service Manager - Status Check Script
# 版本: 1.1 (检查所有服务，包括 enabled=false)
# =============================================================================

BASE_DIR="/data/data/com.termux/files/home/servicemanager"
CONFIG_FILE="$BASE_DIR/configuration.yaml"
SERVICEUPDATE_FILE="$BASE_DIR/serviceupdate.json"

# 加载 MQTT 配置
load_mqtt_conf() {
    MQTT_HOST=$(grep -Po '^[[:space:]]*host:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1)
    MQTT_PORT=$(grep -Po '^[[:space:]]*port:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1)
    MQTT_USER=$(grep -Po '^[[:space:]]*username:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1)
    MQTT_PASS=$(grep -Po '^[[:space:]]*password:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1)
}

# 解析 serviceupdate.json 获取所有 service id (无视 enabled)
load_services() {
    SERVICES=$(jq -r '.services[].id' "$SERVICEUPDATE_FILE")
}

# MQTT 上报
mqtt_report() {
    local topic=$1
    local payload=$2
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload"
}

# 检查服务状态
check_services() {
    declare -A STATUS_MAP
    declare -A INSTALL_MAP
    STOPPED_SERVICES=()

    for SERVICE in $SERVICES; do
        SERVICE_DIR="$BASE_DIR/$SERVICE"
        STATUS=$(bash "$SERVICE_DIR/status.sh" 2>/dev/null)
        if [[ "$STATUS" == "running" ]]; then
            STATUS_MAP["$SERVICE"]="running"
            INSTALL_MAP["$SERVICE"]=true
        else
            STATUS_MAP["$SERVICE"]="stopped"
            STOPPED_SERVICES+=("$SERVICE")
        fi
    done

    # MQTT 上报所有服务的运行状态
    report_status=$(printf '{')
    for SERVICE in "${!STATUS_MAP[@]}"; do
        report_status+="\"$SERVICE\":\"${STATUS_MAP[$SERVICE]}\","
    done
    report_status=${report_status%,}
    report_status+='}'
    mqtt_report "isg/status/all/status" "$report_status"
    echo "✅ 已上报运行状态: $report_status"

    # 检查停止的服务的安装状态
    for SERVICE in "${STOPPED_SERVICES[@]}"; do
        SERVICE_DIR="$BASE_DIR/$SERVICE"
        JSON_OUTPUT=$(bash "$SERVICE_DIR/status.sh" --json 2>/dev/null)
        INSTALL=$(echo "$JSON_OUTPUT" | jq -r '.install')
        if [[ "$INSTALL" == "true" ]]; then
            INSTALL_MAP["$SERVICE"]=true
        else
            INSTALL_MAP["$SERVICE"]=false
        fi
    done

    # MQTT 上报所有服务的安装状态
    report_install=$(printf '{')
    for SERVICE in "${!INSTALL_MAP[@]}"; do
        install_value="${INSTALL_MAP[$SERVICE]}"
        report_install+="\"$SERVICE\":$install_value,"
    done
    report_install=${report_install%,}
    report_install+='}'
    mqtt_report "isg/status/all/install" "$report_install"
    echo "✅ 已上报安装状态: $report_install"
}

# 执行流程
echo "🚀 启动 Status Check 全量状态检测"
load_mqtt_conf
echo "✅ 已加载 MQTT 配置: $MQTT_HOST:$MQTT_PORT"
load_services
echo "✅ 发现服务: $SERVICES"
check_services
echo "🎉 状态检查完成"

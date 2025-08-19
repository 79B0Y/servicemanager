#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# isg-android-control 自检脚本
# 版本: v1.0.0
# 功能: 单服务自检与性能监控，配置同步
# =============================================================================

set -euo pipefail

# =============================================================================
# 基础配置和路径设置
# =============================================================================
SERVICE_ID="isg-android-control"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"
TERMUX_TMP_DIR="/data/data/com.termux/files/usr/tmp"

# 配置文件
CONFIG_FILE="$BASE_DIR/configuration.yaml"
SERVICEUPDATE_FILE="$BASE_DIR/serviceupdate.json"
VERSION_FILE="$SERVICE_DIR/VERSION"

# Proot 相关路径
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
PROOT_ROOTFS="/data/data/com.termux/files/usr/var/lib/proot-distro/installed-rootfs/$PROOT_DISTRO"
ANDROID_CONTROL_INSTALL_DIR="$PROOT_ROOTFS/root/android-control"
ANDROID_CONTROL_CONFIG_DIR="$PROOT_ROOTFS/root/android-control/configs"
ANDROID_CONTROL_MQTT_CONFIG="$PROOT_ROOTFS/root/android-control/configs/mqtt.yaml"
ANDROID_CONTROL_APPS_CONFIG="$PROOT_ROOTFS/root/android-control/configs/apps.yaml"
ANDROID_CONTROL_DEVICE_CONFIG="$PROOT_ROOTFS/root/android-control/configs/device.yaml"

# 日志和状态文件
LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/autocheck.log"
LOCK_FILE_AUTOCHECK="$SERVICE_DIR/.lock_autocheck"
LAST_CHECK_FILE="$SERVICE_DIR/.lastcheck"
DISABLED_FLAG="$SERVICE_DIR/.disabled"

# 脚本参数
MAX_TRIES="${MAX_TRIES:-3}"
RETRY_INTERVAL="${RETRY_INTERVAL:-60}"

# =============================================================================
# 基础函数
# =============================================================================

# 确保必要目录存在
ensure_directories() {
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    mkdir -p "$ANDROID_CONTROL_CONFIG_DIR" 2>/dev/null || true
}

# 统一日志记录
log() {
    echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"
}

# MQTT 配置加载
load_mqtt_conf() {
    if [[ -f "$CONFIG_FILE" ]]; then
        MQTT_HOST=$(grep -Po '^[[:space:]]*host:[[:space:]]*\K.*' "$CONFIG_FILE" 2>/dev/null | head -n1 || echo "127.0.0.1")
        MQTT_PORT_CONFIG=$(grep -Po '^[[:space:]]*port:[[:space:]]*\K.*' "$CONFIG_FILE" 2>/dev/null | head -n1 || echo "1883")
        MQTT_USER=$(grep -Po '^[[:space:]]*username:[[:space:]]*\K.*' "$CONFIG_FILE" 2>/dev/null | head -n1 || echo "admin")
        MQTT_PASS=$(grep -Po '^[[:space:]]*password:[[:space:]]*\K.*' "$CONFIG_FILE" 2>/dev/null | head -n1 || echo "admin")
    else
        MQTT_HOST="127.0.0.1"
        MQTT_PORT_CONFIG="1883"
        MQTT_USER="admin"
        MQTT_PASS="admin"
    fi
}

# MQTT 消息上报
mqtt_report() {
    local topic="$1"
    local payload="$2"
    
    # 检查 MQTT broker 是否可用
    if ! nc -z 127.0.0.1 1883 2>/dev/null; then
        log "[MQTT-OFFLINE] $topic -> $payload"
        return 0
    fi
    
    load_mqtt_conf
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT_CONFIG" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload" >/dev/null 2>&1 || true
    log "[MQTT] $topic -> $payload"
}

# =============================================================================
# 配置同步函数
# =============================================================================

# 更新 MQTT 配置
sync_mqtt_config() {
    log "同步 MQTT 配置"
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log "未找到主配置文件，跳过 MQTT 配置同步"
        return 0
    fi
    
    load_mqtt_conf
    
    # 创建或更新 mqtt.yaml
    cat > "$ANDROID_CONTROL_MQTT_CONFIG" << MQTTEOF
host: $MQTT_HOST
port: $MQTT_PORT_CONFIG
username: "$MQTT_USER"
password: "$MQTT_PASS"
discovery_prefix: homeassistant
base_topic: isg/android
MQTTEOF
    
    log "MQTT 配置已更新: host=$MQTT_HOST, port=$MQTT_PORT_CONFIG, user=$MQTT_USER"
    return 0
}

# 更新应用列表配置
sync_apps_config() {
    log "同步应用列表配置"
    
    if [[ ! -f "$SERVICEUPDATE_FILE" ]]; then
        log "未找到 serviceupdate.json，跳过应用配置同步"
        return 0
    fi
    
    # 从 serviceupdate.json 的 config 字段中获取应用列表
    local apps_json
    apps_json=$(jq -r ".services[] | select(.id==\"$SERVICE_ID\") | .config.Apps // {}" "$SERVICEUPDATE_FILE" 2>/dev/null)
    
    if [[ "$apps_json" == "{}" || "$apps_json" == "null" ]]; then
        log "serviceupdate.json.config 中未找到应用列表，使用默认配置"
        # 使用默认应用配置
        cat > "$ANDROID_CONTROL_APPS_CONFIG" << APPSEOF
apps:
  Home Assistant: io.homeassistant.companion.android
  YouTube: com.google.android.youtube
  Spotify: com.spotify.music
  iSG: com.linknlink.app.device.isg
# Optional: limit the dropdown options shown in HA
# If omitted or empty, all keys from 'apps' will be shown.
visible:
  - Home Assistant
  - YouTube
  - Spotify
  - iSG
APPSEOF
        return 0
    fi
    
    # 构建 apps.yaml 内容
    local apps_yaml="apps:\n"
    local visible_yaml="visible:\n"
    
    # 解析 JSON 并生成 YAML
    local app_names
    app_names=$(echo "$apps_json" | jq -r 'keys[]' 2>/dev/null)
    
    if [[ -n "$app_names" ]]; then
        while IFS= read -r app_name; do
            local package_name
            package_name=$(echo "$apps_json" | jq -r ".[\"$app_name\"]" 2>/dev/null)
            apps_yaml="${apps_yaml}  $app_name: $package_name\n"
            visible_yaml="${visible_yaml}  - $app_name\n"
        done <<< "$app_names"
        
        # 写入配置文件
        {
            echo -e "$apps_yaml"
            echo "# Optional: limit the dropdown options shown in HA"
            echo "# If omitted or empty, all keys from 'apps' will be shown."
            echo -e "$visible_yaml"
        } > "$ANDROID_CONTROL_APPS_CONFIG"
        
        log "应用配置已更新，包含 $(echo "$app_names" | wc -l) 个应用"
    else
        log "应用列表为空，保持现有配置"
    fi
    
    return 0
}

# 更新设备配置
sync_device_config() {
    log "同步设备配置"
    
    # 获取当前的 screenshot_interval 设置
    local new_screenshot_interval=10  # 默认值
    
    if [[ -f "$SERVICEUPDATE_FILE" ]]; then
        # 从 serviceupdate.json 中读取 screenshot_interval
        local interval_from_json
        interval_from_json=$(jq -r ".services[] | select(.id==\"$SERVICE_ID\") | .screenshot_interval // 10" "$SERVICEUPDATE_FILE" 2>/dev/null)
        
        if [[ "$interval_from_json" != "null" && "$interval_from_json" =~ ^[0-9]+$ ]]; then
            new_screenshot_interval="$interval_from_json"
            log "从 serviceupdate.json 读取到 screenshot_interval: $new_screenshot_interval"
        else
            log "serviceupdate.json 中未找到有效的 screenshot_interval，使用默认值: $new_screenshot_interval"
        fi
    else
        log "未找到 serviceupdate.json，使用默认 screenshot_interval: $new_screenshot_interval"
    fi
    
    # 检查是否存在现有的 device.yaml 文件
    if [[ -f "$ANDROID_CONTROL_DEVICE_CONFIG" ]]; then
        log "更新现有的 device.yaml 文件"
        
        # 备份原文件
        cp "$ANDROID_CONTROL_DEVICE_CONFIG" "$ANDROID_CONTROL_DEVICE_CONFIG.backup.$(date +%s)" 2>/dev/null || true
        
        # 读取现有配置并更新 screenshot_interval
        local temp_file="/tmp/device_config_update_$$"
        
        # 使用 sed 更新 screenshot_interval，保持其他配置不变
        sed "s/^screenshot_interval:.*$/screenshot_interval: $new_screenshot_interval/" "$ANDROID_CONTROL_DEVICE_CONFIG" > "$temp_file"
        
        # 检查是否找到并替换了 screenshot_interval
        if grep -q "^screenshot_interval: $new_screenshot_interval$" "$temp_file"; then
            mv "$temp_file" "$ANDROID_CONTROL_DEVICE_CONFIG"
            log "已更新 device.yaml 中的 screenshot_interval 为: $new_screenshot_interval"
        else
            # 如果没有找到 screenshot_interval 行，则添加它
            echo "screenshot_interval: $new_screenshot_interval" >> "$ANDROID_CONTROL_DEVICE_CONFIG"
            rm -f "$temp_file"
            log "已添加 screenshot_interval 配置到 device.yaml: $new_screenshot_interval"
        fi
    else
        log "创建新的 device.yaml 文件"
        
        # 创建默认的 device.yaml 配置
        cat > "$ANDROID_CONTROL_DEVICE_CONFIG" << DEVICEEOF
adb_host: 10.0.0.227
adb_port: 5555
adb_serial: ""  # optional; set to override host:port
screenshots_dir: var/screenshots
logs_dir: var/log
run_dir: var/run
has_battery: false
has_cellular: false
camera_enabled: true
camera_interval: $new_screenshot_interval  # deprecated; use screenshot_interval
screenshot_interval: $new_screenshot_interval
screenshot_keep: 3
device_id: isg_android_controller
device_name: ISG Android Controller
DEVICEEOF
        
        log "已创建新的 device.yaml 文件，screenshot_interval: $new_screenshot_interval"
    fi
    
    return 0
}

# =============================================================================
# 版本信息获取函数
# =============================================================================

# 获取最新版本
get_latest_version() {
    if [[ -f "$SERVICEUPDATE_FILE" ]]; then
        jq -r ".services[] | select(.id==\"$SERVICE_ID\") | .latest_service_version" "$SERVICEUPDATE_FILE" 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
}

# 快速获取 isg-android-control 版本
get_current_version_fast() {
    # 优先从缓存文件读取
    if [[ -f "$VERSION_FILE" ]]; then
        local cached_version=$(cat "$VERSION_FILE" 2>/dev/null | head -n1 | tr -d '\n\r\t ')
        if [[ -n "$cached_version" && "$cached_version" != "unknown" && "$cached_version" != "v1.0.0" ]]; then
            echo "$cached_version"
            return
        fi
    fi
    
    # 使用临时文件避免管道导致的文件描述符问题
    local temp_file="/data/data/com.termux/files/usr/tmp/isg_version_$$"
    mkdir -p "/data/data/com.termux/files/usr/tmp"
    
    if proot-distro login "$PROOT_DISTRO" -- bash -lc '
        /root/.local/bin/isg-android-control version
    ' > "$temp_file" 2>/dev/null; then
        local proot_version=$(cat "$temp_file" | head -n1 | tr -d '\n\r\t ')
        rm -f "$temp_file"
        
        if [[ -n "$proot_version" && "$proot_version" != "unknown" ]]; then
            # 缓存版本到文件
            echo "$proot_version" > "$VERSION_FILE" 2>/dev/null || true
            echo "$proot_version"
        else
            echo "unknown"
        fi
    else
        rm -f "$temp_file"
        echo "unknown"
    fi
}

# =============================================================================
# 状态检查函数
# =============================================================================

# 获取 isg-android-control 进程 PID
get_android_control_pid() {
    pgrep -f "python3 -m isg_android_control.run" 2>/dev/null || return 1
}

# 改进的 RUN 状态检查
get_improved_run_status() {
    if pgrep -f "$SERVICE_DIR/start.sh" > /dev/null 2>&1; then
        echo "starting"
        return
    fi
    
    if pgrep -f "$SERVICE_DIR/stop.sh" > /dev/null 2>&1; then
        echo "stopping"
        return
    fi
    
    local status_output
    status_output=$(bash "$SERVICE_DIR/status.sh" 2>/dev/null)
    
    case "$status_output" in
        "running") echo "running" ;;
        "starting") echo "starting" ;;
        "stopped") echo "stopped" ;;
        *) echo "stopped" ;;
    esac
}

# 快速检查安装状态
check_install_fast() {
    if pgrep -f "$SERVICE_DIR/install.sh" > /dev/null 2>&1; then
        echo "installing"
        return
    fi
    
    if pgrep -f "$SERVICE_DIR/uninstall.sh" > /dev/null 2>&1; then
        echo "uninstalling"
        return
    fi
    
    # 抑制proot警告，检查安装目录
    if proot-distro login "$PROOT_DISTRO" -- test -d "/root/android-control" >/dev/null 2>&1; then
        echo "success"
    else
        echo "never"
    fi
}

# 生成状态消息
generate_status_message() {
    local run_status="$1"
    
    case "$run_status" in
        "running")
            local android_control_pid=$(get_android_control_pid 2>/dev/null || echo "")
            if [[ -n "$android_control_pid" ]]; then
                local uptime_seconds=$(ps -o etimes= -p "$android_control_pid" 2>/dev/null | xargs || echo 0)
                local uptime_minutes=$(( uptime_seconds / 60 ))
                
                if [[ $uptime_minutes -lt 5 ]]; then
                    echo "isg-android-control restarted $uptime_minutes minutes ago"
                elif [[ $uptime_minutes -lt 60 ]]; then
                    echo "isg-android-control running for $uptime_minutes minutes"
                else
                    local uptime_hours=$(( uptime_minutes / 60 ))
                    echo "isg-android-control running for $uptime_hours hours"
                fi
            else
                echo "isg-android-control is running"
            fi
            ;;
        "starting")
            echo "isg-android-control is starting up"
            ;;
        "stopping")
            echo "isg-android-control is stopping"
            ;;
        "stopped")
            echo "isg-android-control is not running"
            ;;
        "failed")
            echo "isg-android-control failed to start"
            ;;
        *)
            echo "isg-android-control status unknown"
            ;;
    esac
}

# 获取配置信息（简化版本，只提取必要字段）
get_config_info_fast() {
    local config_json="{}"
    
    # 尝试读取 MQTT 配置
    if [[ -f "$ANDROID_CONTROL_MQTT_CONFIG" ]]; then
        local mqtt_host=$(grep 'host:' "$ANDROID_CONTROL_MQTT_CONFIG" 2>/dev/null | sed -E 's/.*host: *([^[:space:]]+).*/\1/' || echo "")
        local mqtt_port=$(grep 'port:' "$ANDROID_CONTROL_MQTT_CONFIG" 2>/dev/null | sed -E 's/.*port: *([0-9]+).*/\1/' || echo "")
        
        config_json=$(cat << CONFIGEOF
{
  "mqtt_host": "$mqtt_host",
  "mqtt_port": "$mqtt_port",
  "config_path": "/root/android-control/configs/"
}
CONFIGEOF
)
    fi
    
    # 尝试读取应用列表
    if [[ -f "$ANDROID_CONTROL_APPS_CONFIG" ]]; then
        local apps_count=$(grep -c '^[[:space:]]*[A-Za-z].*:' "$ANDROID_CONTROL_APPS_CONFIG" 2>/dev/null || echo 0)
        config_json=$(echo "$config_json" | jq --argjson count "$apps_count" '. + {apps_count: $count}' 2>/dev/null || echo "$config_json")
    fi
    
    # 尝试读取设备配置
    if [[ -f "$ANDROID_CONTROL_DEVICE_CONFIG" ]]; then
        local screenshot_interval=$(grep 'screenshot_interval:' "$ANDROID_CONTROL_DEVICE_CONFIG" 2>/dev/null | sed -E 's/.*screenshot_interval: *([0-9]+).*/\1/' || echo "")
        local adb_host=$(grep 'adb_host:' "$ANDROID_CONTROL_DEVICE_CONFIG" 2>/dev/null | sed -E 's/.*adb_host: *([^[:space:]]+).*/\1/' || echo "")
        local device_id=$(grep 'device_id:' "$ANDROID_CONTROL_DEVICE_CONFIG" 2>/dev/null | sed -E 's/.*device_id: *([^[:space:]]+).*/\1/' || echo "")
        
        config_json=$(echo "$config_json" | jq \
            --arg interval "$screenshot_interval" \
            --arg host "$adb_host" \
            --arg id "$device_id" \
            '. + {screenshot_interval: $interval, adb_host: $host, device_id: $id}' 2>/dev/null || echo "$config_json")
    fi
    
    echo "$config_json"
}

# =============================================================================
# 主要逻辑开始
# =============================================================================

# 初始化
ensure_directories
RESULT_STATUS="healthy"

# 创建锁文件，防止重复执行
exec 200>"$LOCK_FILE_AUTOCHECK"
flock -n 200 || exit 0

NOW=$(date +%s)

log "开始 isg-android-control 自检"
mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"status\":\"start\",\"run\":\"unknown\",\"config\":{},\"install\":\"checking\",\"current_version\":\"unknown\",\"latest_version\":\"unknown\",\"update\":\"checking\",\"message\":\"starting autocheck process\",\"timestamp\":$NOW}"

# -----------------------------------------------------------------------------
# 检查必要脚本是否存在
# -----------------------------------------------------------------------------
for script in start.sh stop.sh install.sh status.sh; do
    if [[ ! -f "$SERVICE_DIR/$script" ]]; then
        RESULT_STATUS="problem"
        mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"status\":\"problem\",\"message\":\"missing $script\"}"
        exit 1
    fi
done

# -----------------------------------------------------------------------------
# 配置文件同步
# -----------------------------------------------------------------------------
log "执行配置同步"
sync_mqtt_config
sync_apps_config
sync_device_config

# -----------------------------------------------------------------------------
# 获取版本信息
# -----------------------------------------------------------------------------
ANDROID_CONTROL_VERSION=$(get_current_version_fast)
LATEST_ANDROID_CONTROL_VERSION=$(get_latest_version)

# -----------------------------------------------------------------------------
# 获取各脚本状态
# -----------------------------------------------------------------------------
RUN_STATUS=$(get_improved_run_status)

# 只有当服务不在运行时才详细检查安装状态
if [[ "$RUN_STATUS" == "running" ]]; then
    INSTALL_STATUS="success"  # 如果在运行，肯定已安装
else
    INSTALL_STATUS=$(check_install_fast)
fi

# isg-android-control 不支持备份、升级、恢复功能
BACKUP_STATUS="never"
UPDATE_STATUS="never"
RESTORE_STATUS="never"
UPDATE_INFO="no updates supported"

log "状态检查结果:"
log "  run: $RUN_STATUS"
log "  install: $INSTALL_STATUS"
log "  backup: $BACKUP_STATUS"
log "  update: $UPDATE_STATUS"
log "  restore: $RESTORE_STATUS"

# -----------------------------------------------------------------------------
# 检查是否被禁用
# -----------------------------------------------------------------------------
if [[ -f "$DISABLED_FLAG" ]]; then
    CONFIG_INFO=$(get_config_info_fast)
    mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"status\":\"disabled\",\"run\":\"disabled\",\"config\":$CONFIG_INFO,\"install\":\"$INSTALL_STATUS\",\"backup\":\"$BACKUP_STATUS\",\"restore\":\"$RESTORE_STATUS\",\"update\":\"$UPDATE_STATUS\",\"current_version\":\"$ANDROID_CONTROL_VERSION\",\"latest_version\":\"$LATEST_ANDROID_CONTROL_VERSION\",\"update_info\":\"$UPDATE_INFO\",\"message\":\"service is disabled\",\"timestamp\":$NOW}"
    RESULT_STATUS="disabled"
    exit 0
fi

# -----------------------------------------------------------------------------
# 检查服务状态并尝试恢复
# -----------------------------------------------------------------------------
if [[ "$RUN_STATUS" = "stopped" ]]; then
    log "isg-android-control 未运行，尝试启动"
    for i in $(seq 1 $MAX_TRIES); do
        bash "$SERVICE_DIR/start.sh"
        sleep $RETRY_INTERVAL
        NEW_RUN_STATUS=$(get_improved_run_status)
        if [[ "$NEW_RUN_STATUS" = "running" ]]; then
            log "服务在第 $i 次尝试后恢复"
            mqtt_report "isg/autocheck/$SERVICE_ID/status" "{\"status\":\"recovered\",\"message\":\"service recovered after restart attempts\",\"timestamp\":$(date +%s)}"
            RUN_STATUS="running"
            break
        fi
        [[ $i -eq $MAX_TRIES ]] && {
            RESULT_STATUS="problem"
            RUN_STATUS="failed"
        }
    done
fi

# -----------------------------------------------------------------------------
# 检查服务重启情况
# -----------------------------------------------------------------------------
ANDROID_CONTROL_PID=$(get_android_control_pid || echo "")
if [[ -n "$ANDROID_CONTROL_PID" ]]; then
    ANDROID_CONTROL_UPTIME=$(ps -o etimes= -p "$ANDROID_CONTROL_PID" 2>/dev/null | head -n1 | awk '{print $1}' || echo 0)
    # 确保是数字，移除任何非数字字符
    ANDROID_CONTROL_UPTIME=$(echo "$ANDROID_CONTROL_UPTIME" | tr -d '\n\r\t ' | grep -o '^[0-9]*' || echo 0)
    ANDROID_CONTROL_UPTIME=${ANDROID_CONTROL_UPTIME:-0}
else
    ANDROID_CONTROL_UPTIME=0
fi

LAST_CHECK=$(cat "$LAST_CHECK_FILE" 2>/dev/null | head -n1 | tr -d '\n\r\t ' || echo 0)
# 确保LAST_CHECK是数字
LAST_CHECK=${LAST_CHECK:-0}

# 检测重启但仅记录，不影响整体状态
RESTART_DETECTED=false
if [[ "$LAST_CHECK" -gt 0 && "$ANDROID_CONTROL_UPTIME" -lt $((NOW - LAST_CHECK)) ]]; then
    RESTART_DETECTED=true
    log "检测到服务重启：运行时间 ${ANDROID_CONTROL_UPTIME}s < 检查间隔 $((NOW - LAST_CHECK))s"
fi
echo "$NOW" > "$LAST_CHECK_FILE"

# -----------------------------------------------------------------------------
# 性能监控 - 优化版本：减少系统调用
# -----------------------------------------------------------------------------
if [[ -n "$ANDROID_CONTROL_PID" ]]; then
    # 使用单次 ps 调用获取 CPU 和内存信息
    PS_OUTPUT=$(ps -o pid,pcpu,pmem -p "$ANDROID_CONTROL_PID" 2>/dev/null | tail -n1)
    if [[ -n "$PS_OUTPUT" ]]; then
        CPU=$(echo "$PS_OUTPUT" | awk '{print $2}' | head -n1)
        MEM=$(echo "$PS_OUTPUT" | awk '{print $3}' | head -n1)
    else
        # 备用方法：使用 top（较慢）
        CPU=$(top -b -n 1 -p "$ANDROID_CONTROL_PID" 2>/dev/null | awk '/'"$ANDROID_CONTROL_PID"'/ {print $9}' | head -n1)
        MEM=$(top -b -n 1 -p "$ANDROID_CONTROL_PID" 2>/dev/null | awk '/'"$ANDROID_CONTROL_PID"'/ {print $10}' | head -n1)
    fi
    # 确保是数字
    CPU=${CPU:-0.0}
    MEM=${MEM:-0.0}
else
    CPU="0.0"
    MEM="0.0"
fi

mqtt_report "isg/autocheck/$SERVICE_ID/performance" "{\"cpu\":\"$CPU\",\"mem\":\"$MEM\",\"timestamp\":$NOW}"
mqtt_report "isg/status/$SERVICE_ID/performance" "{\"cpu\":\"$CPU\",\"mem\":\"$MEM\",\"timestamp\":$NOW}"

# -----------------------------------------------------------------------------
# 版本信息上报
# -----------------------------------------------------------------------------
log "android_control_version: $ANDROID_CONTROL_VERSION"
log "latest_android_control_version: $LATEST_ANDROID_CONTROL_VERSION"
log "install_status: $INSTALL_STATUS"
log "run_status: $RUN_STATUS"
log "update_info: $UPDATE_INFO"

mqtt_report "isg/autocheck/$SERVICE_ID/version" "{\"android_control_version\":\"$ANDROID_CONTROL_VERSION\",\"latest_android_control_version\":\"$LATEST_ANDROID_CONTROL_VERSION\"}"

# -----------------------------------------------------------------------------
# 获取配置信息和状态消息
# -----------------------------------------------------------------------------
CONFIG_INFO=$(get_config_info_fast 2>/dev/null)
STATUS_MESSAGE=$(generate_status_message "$RUN_STATUS")

# -----------------------------------------------------------------------------
# 生成最终的综合状态消息
# -----------------------------------------------------------------------------
log "自检完成"

# 构建最终状态消息
FINAL_MESSAGE="{"
FINAL_MESSAGE="$FINAL_MESSAGE\"status\":\"$RESULT_STATUS\","
FINAL_MESSAGE="$FINAL_MESSAGE\"run\":\"$RUN_STATUS\","
FINAL_MESSAGE="$FINAL_MESSAGE\"config\":$CONFIG_INFO,"
FINAL_MESSAGE="$FINAL_MESSAGE\"install\":\"$INSTALL_STATUS\","
FINAL_MESSAGE="$FINAL_MESSAGE\"backup\":\"$BACKUP_STATUS\","
FINAL_MESSAGE="$FINAL_MESSAGE\"restore\":\"$RESTORE_STATUS\","
FINAL_MESSAGE="$FINAL_MESSAGE\"update\":\"$UPDATE_STATUS\","
FINAL_MESSAGE="$FINAL_MESSAGE\"current_version\":\"$ANDROID_CONTROL_VERSION\","
FINAL_MESSAGE="$FINAL_MESSAGE\"latest_version\":\"$LATEST_ANDROID_CONTROL_VERSION\","
FINAL_MESSAGE="$FINAL_MESSAGE\"update_info\":\"$UPDATE_INFO\","
FINAL_MESSAGE="$FINAL_MESSAGE\"message\":\"$STATUS_MESSAGE\","
FINAL_MESSAGE="$FINAL_MESSAGE\"restart_detected\":$RESTART_DETECTED,"
FINAL_MESSAGE="$FINAL_MESSAGE\"timestamp\":$NOW"
FINAL_MESSAGE="$FINAL_MESSAGE}"

mqtt_report "isg/autocheck/$SERVICE_ID/status" "$FINAL_MESSAGE"

# -----------------------------------------------------------------------------
# 清理日志文件
# -----------------------------------------------------------------------------
if [[ -f "$LOG_FILE" ]]; then
    tail -n 500 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE" 2>/dev/null || true
fi

log "自检成功完成"

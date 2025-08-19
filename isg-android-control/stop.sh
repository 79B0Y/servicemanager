#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# isg-android-control 停止脚本
# 版本: v1.0.0
# 功能: 通过 isgservicemonitor 停止 isg-android-control 服务
# =============================================================================

set -euo pipefail
trap 'echo "[ERROR] line $LINENO: command failed." | tee -a "$LOG_FILE"' ERR

# -----------------------------------------------------------------------------
# 路径和变量定义
# -----------------------------------------------------------------------------
SERVICE_ID="isg-android-control"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"
TERMUX_VAR_DIR="/data/data/com.termux/files/usr/var"

CONFIG_FILE="$BASE_DIR/configuration.yaml"
SERVICE_CONTROL_DIR="$TERMUX_VAR_DIR/service/$SERVICE_ID"
CONTROL_FILE="$SERVICE_CONTROL_DIR/supervise/control"
DOWN_FILE="$SERVICE_CONTROL_DIR/down"

LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/stop.log"
DISABLED_FLAG="$SERVICE_DIR/.disabled"

MAX_TRIES=30

# -----------------------------------------------------------------------------
# 辅助函数
# -----------------------------------------------------------------------------
ensure_directories() {
    mkdir -p "$LOG_DIR"
}

log() {
    echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"
}

load_mqtt_conf() {
    if [ -f "$CONFIG_FILE" ]; then
        MQTT_HOST=$(grep -Po '^[[:space:]]*host:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1 || echo "127.0.0.1")
        MQTT_PORT_CONFIG=$(grep -Po '^[[:space:]]*port:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1 || echo "1883")
        MQTT_USER=$(grep -Po '^[[:space:]]*username:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1 || echo "admin")
        MQTT_PASS=$(grep -Po '^[[:space:]]*password:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1 || echo "admin")
    else
        MQTT_HOST="127.0.0.1"
        MQTT_PORT_CONFIG="1883"
        MQTT_USER="admin"
        MQTT_PASS="admin"
    fi
}

get_android_control_pid() {
    pgrep -f "python3 -m isg_android_control.run" 2>/dev/null || return 1
}

# 检查 REST API 8000 端口并获取对应的进程 PID
get_rest_api_pid() {
    # 检查 8000 端口是否被占用，并获取对应的 PID
    local api_pid=$(lsof -ti:8000 2>/dev/null | head -n1)
    if [[ -n "$api_pid" ]]; then
        echo "$api_pid"
        return 0
    else
        return 1
    fi
}

# 检查是否还有相关的 isg-android-control 进程在运行
check_all_processes() {
    local main_pid=$(get_android_control_pid 2>/dev/null || echo "")
    local api_pid=$(get_rest_api_pid 2>/dev/null || echo "")
    
    if [[ -n "$main_pid" || -n "$api_pid" ]]; then
        return 0  # 还有进程在运行
    else
        return 1  # 所有进程都已停止
    fi
}

# 停止所有相关进程
stop_all_processes() {
    local force_kill="$1"  # 是否强制杀死
    
    # 停止主进程
    local main_pid=$(get_android_control_pid 2>/dev/null || echo "")
    if [[ -n "$main_pid" ]]; then
        if [[ "$force_kill" == "force" ]]; then
            log "强制杀死主进程 PID: $main_pid"
            kill -9 "$main_pid" 2>/dev/null || true
        else
            log "优雅停止主进程 PID: $main_pid"
            kill "$main_pid" 2>/dev/null || true
        fi
    fi
    
    # 停止 REST API 进程
    local api_pid=$(get_rest_api_pid 2>/dev/null || echo "")
    if [[ -n "$api_pid" ]]; then
        # 检查这个 PID 是否与主进程相同，避免重复杀死
        if [[ "$api_pid" != "$main_pid" ]]; then
            if [[ "$force_kill" == "force" ]]; then
                log "强制杀死 REST API 进程 PID: $api_pid (端口 8000)"
                kill -9 "$api_pid" 2>/dev/null || true
            else
                log "优雅停止 REST API 进程 PID: $api_pid (端口 8000)"
                kill "$api_pid" 2>/dev/null || true
            fi
        else
            log "REST API 进程与主进程相同 (PID: $api_pid)，无需重复处理"
        fi
    fi
    
    # 额外检查：查找所有可能相关的进程
    local other_pids=$(pgrep -f "isg.android.control\|isg_android_control" 2>/dev/null | grep -v "^$" || echo "")
    if [[ -n "$other_pids" ]]; then
        while IFS= read -r pid; do
            if [[ "$pid" != "$main_pid" && "$pid" != "$api_pid" && -n "$pid" ]]; then
                if [[ "$force_kill" == "force" ]]; then
                    log "强制杀死其他相关进程 PID: $pid"
                    kill -9 "$pid" 2>/dev/null || true
                else
                    log "优雅停止其他相关进程 PID: $pid"
                    kill "$pid" 2>/dev/null || true
                fi
            fi
        done <<< "$other_pids"
    fi
}

mqtt_report() {
    local topic="$1"
    local payload="$2"
    
    # 检查 MQTT broker 是否可用
    if ! nc -z 127.0.0.1 1883 2>/dev/null; then
        echo "[$(date '+%F %T')] [MQTT-OFFLINE] $topic -> $payload" >> "$LOG_FILE"
        return 0
    fi
    
    load_mqtt_conf
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT_CONFIG" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload" 2>/dev/null || true
    echo "[$(date '+%F %T')] [MQTT] $topic -> $payload" >> "$LOG_FILE"
}

# -----------------------------------------------------------------------------
# 主停止流程
# -----------------------------------------------------------------------------
ensure_directories

log "停止 isg-android-control 服务"
mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"stopping\",\"message\":\"stopping service\",\"timestamp\":$(date +%s)}"

# -----------------------------------------------------------------------------
# 检查服务是否已经停止
# -----------------------------------------------------------------------------
if ! check_all_processes; then
    log "isg-android-control 所有进程已经停止"
    # 确保创建禁用文件
    touch "$DISABLED_FLAG"
    touch "$DOWN_FILE"
    mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"success\",\"message\":\"service already stopped\",\"timestamp\":$(date +%s)}"
    exit 0
fi

# 显示当前运行的进程信息
MAIN_PID=$(get_android_control_pid 2>/dev/null || echo "")
API_PID=$(get_rest_api_pid 2>/dev/null || echo "")

if [[ -n "$MAIN_PID" ]]; then
    log "发现主进程 PID: $MAIN_PID"
fi

if [[ -n "$API_PID" ]]; then
    log "发现 REST API 进程 PID: $API_PID (端口 8000)"
fi

# -----------------------------------------------------------------------------
# 发送停止信号
# -----------------------------------------------------------------------------
if [ -e "$CONTROL_FILE" ]; then
    echo d > "$CONTROL_FILE"
    log "已发送 'd' 命令到 $CONTROL_FILE"
    
    # 创建 down 文件禁用自启动
    touch "$DOWN_FILE"
    log "已创建 down 文件以禁用自启动"
    mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"stopping\",\"message\":\"created down file to disable auto-start\",\"timestamp\":$(date +%s)}"
else
    log "控制文件不存在，直接终止所有相关进程"
    stop_all_processes "normal"
fi

# -----------------------------------------------------------------------------
# 等待服务停止
# -----------------------------------------------------------------------------
log "等待所有相关进程停止"
mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"stopping\",\"message\":\"waiting for all processes to stop\",\"timestamp\":$(date +%s)}"

TRIES=0
while (( TRIES < MAX_TRIES )); do
    if ! check_all_processes; then
        log "所有 isg-android-control 相关进程已成功停止"
        break
    fi
    
    # 如果超过一半时间还没停止，尝试强制杀死所有进程
    if [ $TRIES -gt $((MAX_TRIES / 2)) ]; then
        log "超过等待时间一半，尝试强制停止所有进程"
        stop_all_processes "force"
    fi
    
    # 显示当前仍在运行的进程
    REMAINING_MAIN=$(get_android_control_pid 2>/dev/null || echo "")
    REMAINING_API=$(get_rest_api_pid 2>/dev/null || echo "")
    
    if [[ -n "$REMAINING_MAIN" ]]; then
        log "主进程仍在运行 PID: $REMAINING_MAIN"
    fi
    
    if [[ -n "$REMAINING_API" ]]; then
        log "REST API 进程仍在运行 PID: $REMAINING_API (端口 8000)"
    fi
    
    sleep 5
    TRIES=$((TRIES+1))
done

# -----------------------------------------------------------------------------
# 检查停止结果
# -----------------------------------------------------------------------------
if check_all_processes; then
    # 获取仍在运行的进程信息
    REMAINING_MAIN=$(get_android_control_pid 2>/dev/null || echo "")
    REMAINING_API=$(get_rest_api_pid 2>/dev/null || echo "")
    
    local remaining_info=""
    if [[ -n "$REMAINING_MAIN" ]]; then
        remaining_info="main_pid:$REMAINING_MAIN"
    fi
    if [[ -n "$REMAINING_API" ]]; then
        remaining_info="$remaining_info api_pid:$REMAINING_API"
    fi
    
    log "部分进程在 $((MAX_TRIES*5)) 秒后仍在运行: $remaining_info"
    mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"failed\",\"message\":\"some processes still running after stop timeout\",\"remaining\":\"$remaining_info\",\"timeout\":$((MAX_TRIES*5)),\"timestamp\":$(date +%s)}"
    exit 1
fi

# -----------------------------------------------------------------------------
# 创建禁用标志
# -----------------------------------------------------------------------------
touch "$DISABLED_FLAG"
log "服务已停止，已创建 .disabled 标志"
mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"success\",\"message\":\"service stopped and disabled\",\"timestamp\":$(date +%s)}"

log "isg-android-control 服务停止完成"
exit 0

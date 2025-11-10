#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# isg-adb-server 停止脚本
# 版本: v1.0.0
# 功能: 通过 isgservicemonitor 停止 ADB 连接
# =============================================================================

set -euo pipefail
trap 'echo "[ERROR] line $LINENO: command failed." | tee -a "$LOG_FILE"' ERR

# -----------------------------------------------------------------------------
# 路径和变量定义
# -----------------------------------------------------------------------------
SERVICE_ID="isg-adb-server"
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

ADB_PORT="5555"
ADB_HOST="127.0.0.1"
ADB_DEVICE="${ADB_HOST}:${ADB_PORT}"

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

check_adb_connected() {
    adb devices 2>/dev/null | grep -q "$ADB_DEVICE" && return 0 || return 1
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

log "停止 isg-adb-server 服务"
mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"stopping\",\"message\":\"stopping service\",\"timestamp\":$(date +%s)}"

# -----------------------------------------------------------------------------
# 创建禁用标志（必须最先做，防止 autocheck 重新连接）
# -----------------------------------------------------------------------------
touch "$DISABLED_FLAG"
log "已创建 .disabled 标志以防止自动重连"

# -----------------------------------------------------------------------------
# 检查服务是否已经停止
# -----------------------------------------------------------------------------
if ! check_adb_connected; then
    log "isg-adb-server 已经停止 (ADB 未连接)"
    # 确保创建 down 文件
    touch "$DOWN_FILE"
    mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"success\",\"message\":\"service already stopped\",\"timestamp\":$(date +%s)}"
    exit 0
fi

# -----------------------------------------------------------------------------
# 第一步：创建 down 文件（最高优先级，防止任何重启）
# -----------------------------------------------------------------------------
touch "$DOWN_FILE"
log "已创建 down 文件以禁用自启动"
mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"stopping\",\"message\":\"created down file to disable auto-start\",\"timestamp\":$(date +%s)}"

# 等待 supervise 识别 down 文件
sleep 2

# -----------------------------------------------------------------------------
# 第二步：使用 svc 命令停止服务（如果可用）
# -----------------------------------------------------------------------------
if command -v svc >/dev/null 2>&1; then
    log "使用 svc 命令停止服务"
    svc -d "$SERVICE_CONTROL_DIR" 2>/dev/null || true
    sleep 1
fi

# -----------------------------------------------------------------------------
# 第三步：使用 sv 命令停止服务（如果可用）
# -----------------------------------------------------------------------------
if command -v sv >/dev/null 2>&1; then
    log "使用 sv 命令停止服务"
    # force-stop: 强制停止
    sv force-stop "$SERVICE_CONTROL_DIR" 2>/dev/null || true
    sleep 1
    # down: 禁用服务
    sv down "$SERVICE_CONTROL_DIR" 2>/dev/null || true
    sleep 1
    # kill: 杀死服务进程
    sv kill "$SERVICE_CONTROL_DIR" 2>/dev/null || true
    log "已使用 sv 命令停止服务"
    sleep 2
fi

# -----------------------------------------------------------------------------
# 第四步：通过控制文件发送信号
# -----------------------------------------------------------------------------
if [ -e "$CONTROL_FILE" ]; then
    log "发送控制信号到 supervise"
    
    # 先发送 'x' 退出信号
    echo x > "$CONTROL_FILE" 2>/dev/null || true
    sleep 1
    
    # 再发送 'd' down 信号
    echo d > "$CONTROL_FILE" 2>/dev/null || true
    sleep 1
    
    # 最后发送 'k' kill 信号
    echo k > "$CONTROL_FILE" 2>/dev/null || true
    log "已发送控制信号: x, d, k"
    sleep 1
fi

# -----------------------------------------------------------------------------
# 第五步：强制杀死所有相关进程
# -----------------------------------------------------------------------------
log "强制终止所有相关进程"

# 1. 杀死 run 脚本进程（不影响其他服务的 run）
RUN_PIDS=$(pgrep -f "^.*sh.*$SERVICE_CONTROL_DIR/run" 2>/dev/null || true)
if [ -n "$RUN_PIDS" ]; then
    log "发现 run 脚本进程: $RUN_PIDS"
    echo "$RUN_PIDS" | xargs kill -9 2>/dev/null || true
    log "已杀死 run 脚本进程"
fi

# 2. 杀死所有 adb connect 到目标设备的进程
CONNECT_PIDS=$(pgrep -f "adb connect.*$ADB_DEVICE" 2>/dev/null || true)
if [ -n "$CONNECT_PIDS" ]; then
    log "发现 adb connect 进程: $CONNECT_PIDS"
    echo "$CONNECT_PIDS" | xargs kill -9 2>/dev/null || true
    log "已杀死 adb connect 进程"
fi

# 3. 清理可能的僵尸进程
pkill -9 -f "adb.*$ADB_DEVICE" 2>/dev/null || true

log "已终止所有服务子进程"

# -----------------------------------------------------------------------------
# 第六步：断开 ADB 连接（多种方法）
# -----------------------------------------------------------------------------
log "断开 ADB 连接"

# 方法 1: 多次调用 adb disconnect
for i in {1..3}; do
    adb disconnect "$ADB_DEVICE" 2>/dev/null || true
    sleep 1
done

# 方法 2: 杀死 adb server（会断开所有连接）
log "重启 ADB server 以强制断开所有连接"
adb kill-server 2>/dev/null || true
sleep 2

# 重新启动 adb server
adb start-server 2>/dev/null &
sleep 2

# 方法 3: 再次尝试断开
adb disconnect "$ADB_DEVICE" 2>/dev/null || true

# -----------------------------------------------------------------------------
# 第七步：等待确认 ADB 已断开
# -----------------------------------------------------------------------------
log "等待确认 ADB 已断开"
mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"stopping\",\"message\":\"waiting for ADB disconnection confirmation\",\"timestamp\":$(date +%s)}"

TRIES=0
MAX_TRIES=10

while (( TRIES < MAX_TRIES )); do
    if ! check_adb_connected; then
        log "✓ ADB 已成功断开"
        break
    fi
    
    log "警告: ADB 仍然连接 (尝试 $((TRIES+1))/$MAX_TRIES)"
    
    # 每次循环都尝试断开
    adb disconnect "$ADB_DEVICE" 2>/dev/null || true
    
    # 特殊处理：多次失败后采取更激进的措施
    if [ $TRIES -eq 3 ]; then
        log "尝试杀死所有 adb 相关进程"
        pkill -9 adb 2>/dev/null || true
        sleep 2
        adb start-server 2>/dev/null &
        sleep 2
    fi
    
    if [ $TRIES -eq 6 ]; then
        log "最后尝试: 完全重置 ADB"
        pkill -9 -f adb 2>/dev/null || true
        rm -rf ~/.android/adbkey* 2>/dev/null || true
        sleep 3
        adb start-server 2>/dev/null &
        sleep 2
    fi
    
    sleep 2
    TRIES=$((TRIES+1))
done

# -----------------------------------------------------------------------------
# 第八步：最终检查和清理
# -----------------------------------------------------------------------------
if check_adb_connected; then
    log "⚠️  警告: ADB 在 $((MAX_TRIES*2)) 秒后仍未断开"
    
    # 最后一次尝试：查找并显示所有可能维护连接的进程
    log "诊断信息 - 查找维护 ADB 连接的进程:"
    ps aux | grep -i adb | grep -v grep | while read line; do
        log "  进程: $line"
    done
    
    # 最后的杀手锏：强制杀死所有 adb 进程
    log "执行最终清理：强制终止所有 ADB 进程"
    pkill -9 -f "adb" 2>/dev/null || true
    killall -9 adb 2>/dev/null || true
    sleep 2
    
    # 再次检查
    if check_adb_connected; then
        log "✗ ADB 仍然连接，但服务已被禁用（.disabled 和 down 文件已创建）"
        mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"warning\",\"message\":\"ADB still connected after all attempts, but service disabled\",\"timestamp\":$(date +%s)}"
        
        log ""
        log "服务控制状态:"
        log "  - .disabled 标志: 已创建 ✓ (阻止 autocheck 重连)"
        log "  - down 文件: 已创建 ✓ (阻止 supervise 自启)"
        log "  - supervise 状态: 已发送停止信号 ✓"
        log ""
        log "如果 ADB 仍然连接，可能的原因:"
        log "  1. 有其他脚本或程序在维护 ADB 连接"
        log "  2. ADB daemon (adbd) 在系统层面持续运行"
        log "  3. 手动建立的 ADB 连接（不是由本服务管理）"
        log ""
        log "建议操作:"
        log "  1. 运行 debug.sh 查看详细状态"
        log "  2. 检查 crontab 或其他定时任务"
        log "  3. 完全重启 Termux: termux-reload-settings"
        log "  4. 重启 Android 设备"
        exit 1
    else
        log "✓ 最终清理成功，ADB 已断开"
    fi
fi

# -----------------------------------------------------------------------------
# 停止成功
# -----------------------------------------------------------------------------
log "=========================================="
log "✓ isg-adb-server 服务停止成功"
log "=========================================="
log "停止摘要:"
log "  - ADB 连接: 已断开 ✓"
log "  - .disabled 标志: 已创建 ✓"
log "  - down 文件: 已创建 ✓"
log "  - supervise 状态: 已禁用 ✓"
log "  - 自动重连: 已阻止 ✓"
log "=========================================="

mqtt_report "isg/run/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"success\",\"message\":\"service stopped and disabled successfully\",\"timestamp\":$(date +%s)}"

exit 0

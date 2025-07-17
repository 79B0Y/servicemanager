#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Mosquitto 启动脚本
# 版本: v1.0.1
# 功能: 通过 isgservicemonitor 启动 Mosquitto 服务
# 修复: IPv4监听验证，MQTT上报时机控制
# =============================================================================

set -euo pipefail

# 加载统一路径定义
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common_paths.sh" || {
    echo "Error: Cannot load common paths"
    exit 1
}

# 设置脚本特定的日志文件
LOG_FILE="$LOG_FILE_START"

# 确保必要目录存在
ensure_directories

log "starting mosquitto service"

# 初始阶段避免MQTT上报（服务可能未运行）
echo "[$(date '+%F %T')] [INFO] Starting Mosquitto service" >> "$LOG_FILE"

# -----------------------------------------------------------------------------
# 验证配置文件
# -----------------------------------------------------------------------------
if [ ! -f "$MOSQUITTO_CONF_FILE" ]; then
    log "configuration file not found: $MOSQUITTO_CONF_FILE"
    exit 1
fi

if ! mosquitto -c "$MOSQUITTO_CONF_FILE" -t 2>/dev/null; then
    log "configuration file validation failed"
    exit 1
fi

# -----------------------------------------------------------------------------
# 移除 .disabled 和 down 文件
# -----------------------------------------------------------------------------
if [ -f "$DISABLED_FLAG" ]; then
    rm -f "$DISABLED_FLAG"
    log "removed .disabled flag"
fi

if [ -f "$DOWN_FILE" ]; then
    rm -f "$DOWN_FILE"
    log "removed down file to enable auto-start"
fi

# -----------------------------------------------------------------------------
# 启动服务
# -----------------------------------------------------------------------------
if [ -e "$CONTROL_FILE" ]; then
    echo u > "$CONTROL_FILE"
    log "sent 'u' command to $CONTROL_FILE"
else
    log "control file not found; cannot start service"
    exit 1
fi

# -----------------------------------------------------------------------------
# 等待服务进入 running 状态并验证IPv4监听
# -----------------------------------------------------------------------------
log "waiting for service ready and IPv4 listening verification"

TRIES=0
MAX_TRIES_START=30
INTERVAL=5
IPV4_LISTENING=false

while (( TRIES < MAX_TRIES_START )); do
    # 检查进程是否存在
    if MOSQUITTO_PID=$(get_mosquitto_pid); then
        log "mosquitto process found (PID: $MOSQUITTO_PID)"
        
        # 验证IPv4端口监听 - 关键检查点
        if netstat -tulnp 2>/dev/null | grep -q "0.0.0.0:1883"; then
            log "SUCCESS: mosquitto listening on 0.0.0.0:1883"
            IPV4_LISTENING=true
            
            # 检查WebSocket端口（非必需）
            if netstat -tulnp 2>/dev/null | grep -q "0.0.0.0:9001"; then
                log "SUCCESS: mosquitto WebSocket listening on 0.0.0.0:9001"
            else
                log "WARNING: WebSocket port 9001 not listening properly"
            fi
            
            # 现在服务已启动，可以安全上报MQTT状态
            mqtt_report "isg/run/$SERVICE_ID/status" \
                "{\"service\":\"$SERVICE_ID\",\"status\":\"success\",\"message\":\"service started successfully\",\"ipv4_listening\":true,\"timestamp\":$(date +%s)}" \
                3 2>/dev/null || log "MQTT report failed (expected if this is the first start)"
            
            log "service started successfully with IPv4 global listening"
            exit 0
        else
            log "process exists but not listening on IPv4 yet (attempt $((TRIES+1))/$MAX_TRIES_START)"
            
            # 检查是否监听其他地址
            local listening_status=$(netstat -tulnp 2>/dev/null | grep ":1883" || echo "none")
            log "current 1883 listening: $listening_status"
        fi
    else
        log "waiting for mosquitto process (attempt $((TRIES+1))/$MAX_TRIES_START)"
    fi
    
    sleep "$INTERVAL"
    TRIES=$((TRIES+1))
done

# -----------------------------------------------------------------------------
# 启动失败处理
# -----------------------------------------------------------------------------
log "service failed to start properly after $((MAX_TRIES_START * INTERVAL)) seconds"

# 获取详细诊断信息
log "=== DIAGNOSTIC INFORMATION ==="
log "Mosquitto process status:"
ps aux | grep mosquitto | grep -v grep >> "$LOG_FILE" || echo "No mosquitto processes found" >> "$LOG_FILE"

log "Network listening status:"
netstat -tulnp 2>/dev/null | grep -E "(1883|9001)" >> "$LOG_FILE" || echo "No mosquitto ports listening" >> "$LOG_FILE"

log "Configuration file test:"
mosquitto -c "$MOSQUITTO_CONF_FILE" -t >> "$LOG_FILE" 2>&1 || echo "Configuration test failed" >> "$LOG_FILE"

log "Service control status:"
ls -la "$SERVICE_CONTROL_DIR/" >> "$LOG_FILE" 2>/dev/null || echo "Service control directory issue" >> "$LOG_FILE"

log "Recent log entries:"
if [ -f "$MOSQUITTO_LOG_DIR/mosquitto.log" ]; then
    tail -10 "$MOSQUITTO_LOG_DIR/mosquitto.log" >> "$LOG_FILE" 2>/dev/null || true
fi

# 恢复 .disabled 状态
log "service failed to start, restoring .disabled flag"
touch "$DISABLED_FLAG"
touch "$DOWN_FILE"

# 尝试上报失败状态（如果其他MQTT服务可用）
(
    sleep 2
    mqtt_report "isg/run/$SERVICE_ID/status" \
        "{\"service\":\"$SERVICE_ID\",\"status\":\"failed\",\"message\":\"service failed to reach IPv4 listening state\",\"timeout\":$((MAX_TRIES_START * INTERVAL)),\"ipv4_listening\":false,\"timestamp\":$(date +%s)}" \
        1 2>/dev/null || true
) &

log "mosquitto startup failed - check diagnostic information above"
exit 1
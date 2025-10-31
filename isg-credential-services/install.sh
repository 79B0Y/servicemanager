#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# isg-credential-services 安装脚本
# 版本: v1.0.0
# 功能: 在 proot Ubuntu 环境中安装 isg-credential-services
# =============================================================================

set -euo pipefail

# =============================================================================
# 路径和配置定义
# =============================================================================
SERVICE_ID="isg-credential-services"
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"

# 基础目录
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
SERVICE_DIR="$BASE_DIR/$SERVICE_ID"
CONFIG_FILE="$BASE_DIR/configuration.yaml"
SERVICEUPDATE_FILE="$BASE_DIR/serviceupdate.json"

# 日志和状态文件
LOG_DIR="$SERVICE_DIR/logs"
LOG_FILE="$LOG_DIR/install.log"
VERSION_FILE="$SERVICE_DIR/VERSION"
INSTALL_HISTORY_FILE="$SERVICE_DIR/.install_history"

# 服务监控相关路径
SERVICE_CONTROL_DIR="/data/data/com.termux/files/usr/var/service/$SERVICE_ID"
RUN_FILE="$SERVICE_CONTROL_DIR/run"
DOWN_FILE="$SERVICE_CONTROL_DIR/down"

# 容器内路径
ISG_INSTALL_DIR="/root/isg-credential-services"
ISG_PACKAGE_URL="https://eucfg.linklinkiot.com/isg/credential-services.zip"

# 服务特定配置
ISG_PORT="3000"

# 脚本参数
MAX_WAIT="${MAX_WAIT:-300}"
INTERVAL="${INTERVAL:-5}"

# =============================================================================
# 工具函数
# =============================================================================
ensure_directories() {
    mkdir -p "$LOG_DIR"
    mkdir -p "$SERVICE_CONTROL_DIR"
    touch "$INSTALL_HISTORY_FILE" 2>/dev/null || true
}

log() {
    echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"
}

load_mqtt_conf() {
    if [[ -f "$CONFIG_FILE" ]]; then
        MQTT_HOST=$(grep -Po '^[[:space:]]*host:[[:space:]]*\K.*' "$CONFIG_FILE" 2>/dev/null | head -n1 || echo "127.0.0.1")
        MQTT_PORT=$(grep -Po '^[[:space:]]*port:[[:space:]]*\K.*' "$CONFIG_FILE" 2>/dev/null | head -n1 || echo "1883")
        MQTT_USER=$(grep -Po '^[[:space:]]*username:[[:space:]]*\K.*' "$CONFIG_FILE" 2>/dev/null | head -n1 || echo "admin")
        MQTT_PASS=$(grep -Po '^[[:space:]]*password:[[:space:]]*\K.*' "$CONFIG_FILE" 2>/dev/null | head -n1 || echo "admin")
    else
        MQTT_HOST="127.0.0.1"
        MQTT_PORT="1883"
        MQTT_USER="admin"
        MQTT_PASS="admin"
    fi
}

mqtt_report() {
    local topic="$1"
    local payload="$2"
    load_mqtt_conf
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload" || true
    log "[MQTT] $topic -> $payload"
}

get_current_version() {
    proot-distro login "$PROOT_DISTRO" -- bash -c "
        if [ -f '$ISG_INSTALL_DIR/package.json' ]; then
            # 优先使用 jq
            if command -v jq &> /dev/null; then
                jq -r '.version // \"unknown\"' '$ISG_INSTALL_DIR/package.json' 2>/dev/null || echo 'unknown'
            else
                # 降级使用 grep
                grep -oP '\"version\":\s*\"\K[^\"]+' '$ISG_INSTALL_DIR/package.json' 2>/dev/null || echo 'unknown'
            fi
        else
            echo 'unknown'
        fi
    " 2>/dev/null || echo "unknown"
}

record_install_history() {
    local status="$1"
    local version="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$timestamp INSTALL $status $version" >> "$INSTALL_HISTORY_FILE"
}

# =============================================================================
# 主程序开始
# =============================================================================
ensure_directories
START_TIME=$(date +%s)

log "starting isg-credential-services installation process"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"starting installation process\",\"timestamp\":$(date +%s)}"

# -----------------------------------------------------------------------------
# 读取服务依赖配置
# -----------------------------------------------------------------------------
log "reading service dependencies from serviceupdate.json"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"reading service dependencies from serviceupdate.json\",\"timestamp\":$(date +%s)}"

if [ ! -f "$SERVICEUPDATE_FILE" ]; then
    log "serviceupdate.json not found, using default dependencies"
    DEPENDENCIES='["python3-numpy","python3-sklearn","python3-requests","wget","unzip"]'
else
    DEPENDENCIES=$(jq -c ".services[] | select(.id==\"$SERVICE_ID\") | .install_dependencies // [\"python3-numpy\",\"python3-sklearn\",\"python3-requests\",\"wget\",\"unzip\"]" "$SERVICEUPDATE_FILE" 2>/dev/null || echo '["python3-numpy","python3-sklearn","python3-requests","wget","unzip"]')
fi

# 转换为 bash 数组
if [ "$DEPENDENCIES" != "null" ] && [ -n "$DEPENDENCIES" ]; then
    readarray -t DEPS_ARRAY < <(echo "$DEPENDENCIES" | jq -r '.[]' 2>/dev/null)
else
    DEPS_ARRAY=("python3-numpy" "python3-sklearn" "python3-requests" "wget" "unzip")
fi

# 确保数组不为空
if [ ${#DEPS_ARRAY[@]} -eq 0 ]; then
    DEPS_ARRAY=("python3-numpy" "python3-sklearn" "python3-requests" "wget" "unzip")
fi

log "installing required dependencies: ${DEPS_ARRAY[*]}"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"installing required dependencies\",\"dependencies\":$DEPENDENCIES,\"timestamp\":$(date +%s)}"

# -----------------------------------------------------------------------------
# 安装系统依赖
# -----------------------------------------------------------------------------
log "installing system dependencies in proot container"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"installing system dependencies\",\"timestamp\":$(date +%s)}"

if ! proot-distro login "$PROOT_DISTRO" -- bash -c "
    apt-get update
    apt-get install -y ${DEPS_ARRAY[*]}
"; then
    log "failed to install system dependencies"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"dependency installation failed\",\"dependencies\":$DEPENDENCIES,\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

# -----------------------------------------------------------------------------
# 下载并安装 isg-credential-services
# -----------------------------------------------------------------------------
log "downloading and installing isg-credential-services"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"downloading and installing isg-credential-services\",\"timestamp\":$(date +%s)}"

if ! proot-distro login "$PROOT_DISTRO" -- bash -c "
    cd /root
    apt update
    apt install -y python3-numpy python3-sklearn python3-requests
    rm -rf isg-credential-services
    wget --no-check-certificate $ISG_PACKAGE_URL
    unzip credential-services.zip
    rm credential-services.zip
    mv credential-services isg-credential-services
    cd isg-credential-services
    npm install
"; then
    log "failed to install isg-credential-services"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"isg-credential-services installation failed\",\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

# -----------------------------------------------------------------------------
# 修改 bestMatch 配置文件
# -----------------------------------------------------------------------------
log "configuring bestMatch module"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"configuring bestMatch module\",\"timestamp\":$(date +%s)}"

CONFIG_FILE_PATH="/root/isg-credential-services/modules/bestMatch/config.json"

if ! proot-distro login "$PROOT_DISTRO" -- bash -c "
    if [ -f '$CONFIG_FILE_PATH' ]; then
        # 备份原配置文件
        cp '$CONFIG_FILE_PATH' '${CONFIG_FILE_PATH}.backup'
        
        # 使用 jq 修改 pythonPath
        if command -v jq &> /dev/null; then
            jq '.pythonPath = \"/usr/bin/python3.12\"' '$CONFIG_FILE_PATH' > '${CONFIG_FILE_PATH}.tmp'
            mv '${CONFIG_FILE_PATH}.tmp' '$CONFIG_FILE_PATH'
        else
            # 如果没有 jq，使用 sed 替换
            sed -i 's|\"pythonPath\": \"python3\"|\"pythonPath\": \"/usr/bin/python3.12\"|g' '$CONFIG_FILE_PATH'
        fi
        
        echo 'bestMatch config.json updated successfully'
    else
        echo 'Warning: bestMatch config.json not found at $CONFIG_FILE_PATH'
    fi
"; then
    log "warning: failed to update bestMatch config, but continuing installation"
else
    log "bestMatch configuration updated successfully"
fi

# 获取安装的版本
VERSION_STR=$(get_current_version)
log "isg-credential-services version: $VERSION_STR"

# -----------------------------------------------------------------------------
# 注册 servicemonitor 服务看护
# -----------------------------------------------------------------------------
log "registering servicemonitor service"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"registering servicemonitor service\",\"timestamp\":$(date +%s)}"

# 创建服务目录
mkdir -p "$SERVICE_CONTROL_DIR"

# 写入 run 启动脚本
cat << 'EOF' > "$RUN_FILE"
#!/data/data/com.termux/files/usr/bin/sh
# 启动 isg-credential-services
exec proot-distro login ubuntu -- bash -c '
    cd /root/isg-credential-services
    node --expose-gc start-termux.js
'
EOF

# 赋予执行权限
chmod +x "$RUN_FILE"

# 创建 down 文件（初始状态不自启）
touch "$DOWN_FILE"

log "servicemonitor service registered successfully"

# -----------------------------------------------------------------------------
# 启动服务测试
# -----------------------------------------------------------------------------
log "starting service for testing"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"starting service for testing\",\"timestamp\":$(date +%s)}"

bash "$SERVICE_DIR/start.sh"

# -----------------------------------------------------------------------------
# 等待服务启动
# -----------------------------------------------------------------------------
log "waiting for service ready"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"waiting for service ready\",\"timestamp\":$(date +%s)}"

WAITED=0
while [ "$WAITED" -lt "$MAX_WAIT" ]; do
    if bash "$SERVICE_DIR/status.sh" --quiet; then
        log "service is running after ${WAITED}s"
        break
    fi
    sleep "$INTERVAL"
    WAITED=$((WAITED + INTERVAL))
done

if [ "$WAITED" -ge "$MAX_WAIT" ]; then
    log "timeout: service not running after ${MAX_WAIT}s"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"service start timeout after installation\",\"timeout\":$MAX_WAIT,\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "$VERSION_STR"
    exit 1
fi

# -----------------------------------------------------------------------------
# 停止服务 (安装完成后暂停运行)
# -----------------------------------------------------------------------------
bash "$SERVICE_DIR/stop.sh"

# -----------------------------------------------------------------------------
# 记录安装历史
# -----------------------------------------------------------------------------
log "recording installation history"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"recording installation history\",\"version\":\"$VERSION_STR\",\"timestamp\":$(date +%s)}"

echo "$VERSION_STR" > "$VERSION_FILE"
record_install_history "SUCCESS" "$VERSION_STR"

# -----------------------------------------------------------------------------
# 安装完成
# -----------------------------------------------------------------------------
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

log "isg-credential-services installation completed successfully in ${DURATION}s"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"installed\",\"version\":\"$VERSION_STR\",\"duration\":$DURATION,\"timestamp\":$END_TIME}"

exit 0

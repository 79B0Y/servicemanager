#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# isg-android-control 安装脚本
# 版本: v1.0.0
# 功能: 在 proot Ubuntu 环境中安装 isg-android-control
# =============================================================================

set -euo pipefail

# =============================================================================
# 路径与配置定义
# =============================================================================
SERVICE_ID="isg-android-control"
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
ANDROID_CONTROL_INSTALL_DIR="/root/android-control"

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
    # 使用临时文件避免管道导致的文件描述符问题
    local temp_file="/data/data/com.termux/files/usr/tmp/isg_version_$$"
    mkdir -p "/data/data/com.termux/files/usr/tmp"
    
    if proot-distro login "$PROOT_DISTRO" -- bash -lc '
        /root/.local/bin/isg-android-control version
    ' > "$temp_file" 2>/dev/null; then
        local version=$(cat "$temp_file" | head -n1 | tr -d '\n\r\t ')
        rm -f "$temp_file"
        echo "${version:-unknown}"
    else
        rm -f "$temp_file"
        echo "unknown"
    fi
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

log "开始 isg-android-control 安装流程"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"starting installation process\",\"timestamp\":$(date +%s)}"

# -----------------------------------------------------------------------------
# 检查并创建android-control源文件
# -----------------------------------------------------------------------------
log "检查android-control源文件"
ANDROID_CONTROL_SOURCE="$SERVICE_DIR/android-control"

if [[ ! -d "$ANDROID_CONTROL_SOURCE" ]]; then
    log "错误: android-control源目录不存在: $ANDROID_CONTROL_SOURCE"
    log "请确保已将isg-android-control文件放置在: $ANDROID_CONTROL_SOURCE/"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"android-control source directory not found\",\"expected_path\":\"$ANDROID_CONTROL_SOURCE\",\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

# 检查关键文件是否存在
REQUIRED_FILES=("install.sh")
for file in "${REQUIRED_FILES[@]}"; do
    if [[ ! -f "$ANDROID_CONTROL_SOURCE/$file" ]]; then
        log "错误: 缺少必需文件: $ANDROID_CONTROL_SOURCE/$file"
        mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"missing required file: $file\",\"timestamp\":$(date +%s)}"
        record_install_history "FAILED" "unknown"
        exit 1
    fi
done

log "android-control源文件检查通过"

# -----------------------------------------------------------------------------
# 读取服务依赖配置
# -----------------------------------------------------------------------------
log "读取服务依赖配置"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"reading service dependencies from serviceupdate.json\",\"timestamp\":$(date +%s)}"

if [ ! -f "$SERVICEUPDATE_FILE" ]; then
    log "serviceupdate.json 未找到，使用默认依赖"
    DEPENDENCIES='["python3","python3-pip","python3-venv","git","wget","curl","unzip","redis-server"]'
else
    DEPENDENCIES=$(jq -c ".services[] | select(.id==\"$SERVICE_ID\") | .install_dependencies // [\"python3\",\"python3-pip\",\"python3-venv\",\"git\",\"wget\",\"curl\",\"unzip\",\"redis-server\"]" "$SERVICEUPDATE_FILE" 2>/dev/null || echo '["python3","python3-pip","python3-venv","git","wget","curl","unzip","redis-server"]')
fi

# 转换为 bash 数组
if [ "$DEPENDENCIES" != "null" ] && [ -n "$DEPENDENCIES" ]; then
    readarray -t DEPS_ARRAY < <(echo "$DEPENDENCIES" | jq -r '.[]' 2>/dev/null)
else
    DEPS_ARRAY=("python3" "python3-pip" "python3-venv" "git" "wget" "curl" "unzip" "redis-server")
fi

# 确保数组不为空
if [ ${#DEPS_ARRAY[@]} -eq 0 ]; then
    DEPS_ARRAY=("python3" "python3-pip" "python3-venv" "git" "wget" "curl" "unzip" "redis-server")
fi

log "安装所需依赖: ${DEPS_ARRAY[*]}"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"installing required dependencies\",\"dependencies\":$DEPENDENCIES,\"timestamp\":$(date +%s)}"

# -----------------------------------------------------------------------------
# 安装系统依赖
# -----------------------------------------------------------------------------
log "在 proot 容器内安装系统依赖"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"installing system dependencies\",\"timestamp\":$(date +%s)}"

if ! proot-distro login "$PROOT_DISTRO" -- bash -c "
    set -e
    echo '更新软件包列表...'
    apt-get update
    echo '安装系统依赖...'
    apt-get install -y ${DEPS_ARRAY[*]}
    echo '系统依赖安装完成'
"; then
    log "系统依赖安装失败"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"dependency installation failed\",\"dependencies\":$DEPENDENCIES,\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

log "系统依赖安装成功"

# -----------------------------------------------------------------------------
# 复制android-control到proot环境并安装
# -----------------------------------------------------------------------------
log "复制 isg-android-control 到容器内并安装"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"copying and installing isg-android-control\",\"timestamp\":$(date +%s)}"

# 检查proot环境是否可以访问
if ! proot-distro login "$PROOT_DISTRO" -- bash -c "pwd" >/dev/null 2>&1; then
    log "错误: 无法访问proot环境"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"cannot access proot environment\",\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

# 创建临时复制脚本来处理复制和安装
TEMP_INSTALL_SCRIPT="/data/data/com.termux/files/usr/tmp/install_isg_android_control_$$"
cat > "$TEMP_INSTALL_SCRIPT" << 'INSTALL_EOF'
#!/bin/bash
set -e

echo "开始复制和安装isg-android-control..."
echo "当前目录: $(pwd)"
echo "用户: $(whoami)"

# 创建目标目录
mkdir -p /root
echo "创建目录 /root 完成"

# 检查源目录是否存在于Termux中（通过挂载点访问）
SOURCE_DIR="/data/data/com.termux/files/home/servicemanager/isg-android-control/android-control"
if [ ! -d "$SOURCE_DIR" ]; then
    echo "错误: 源目录不存在: $SOURCE_DIR"
    exit 1
fi

echo "找到源目录: $SOURCE_DIR"
echo "源目录内容:"
ls -la "$SOURCE_DIR" || echo "无法列出源目录内容"

# 复制整个android-control目录到/root/
echo "复制 $SOURCE_DIR 到 /root/android-control"
if cp -r "$SOURCE_DIR" /root/android-control; then
    echo "复制成功"
else
    echo "复制失败，退出状态: $?"
    exit 1
fi

# 验证复制结果
if [ -d "/root/android-control" ]; then
    echo "验证: /root/android-control 目录存在"
    echo "/root/android-control 内容:"
    ls -la /root/android-control
else
    echo "错误: /root/android-control 目录不存在"
    exit 1
fi

# 检查install.sh是否存在
if [ -f "/root/android-control/install.sh" ]; then
    echo "找到install.sh文件"
    
    # 进入安装目录
    cd /root/android-control
    echo "当前工作目录: $(pwd)"
    
    # 给install.sh执行权限
    chmod +x install.sh
    echo "已设置install.sh执行权限"
    
    # 执行安装
    echo "开始执行安装脚本..."
    if bash install.sh; then
        echo "install.sh执行成功"
    else
        echo "install.sh执行失败，退出状态: $?"
        exit 1
    fi
else
    echo "错误: /root/android-control/install.sh 不存在"
    exit 1
fi

echo "isg-android-control安装完成"
INSTALL_EOF

# 赋予临时脚本执行权限
chmod +x "$TEMP_INSTALL_SCRIPT"

# 在proot环境中执行安装
if ! proot-distro login "$PROOT_DISTRO" -- bash "$TEMP_INSTALL_SCRIPT"; then
    log "isg-android-control 复制和安装失败"
    rm -f "$TEMP_INSTALL_SCRIPT"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"isg-android-control installation failed\",\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

# 清理临时脚本
rm -f "$TEMP_INSTALL_SCRIPT"
log "isg-android-control 复制和安装成功"

# 获取安装的版本
VERSION_STR=$(get_current_version)
if [[ "$VERSION_STR" == "unknown" ]]; then
    # 如果获取失败，尝试直接执行版本命令
    log "尝试直接获取版本信息"
    TEMP_VERSION_FILE="/data/data/com.termux/files/usr/tmp/isg_android_control_install_version_$$"
    if proot-distro login "$PROOT_DISTRO" -- bash -c "
        cd /root/android-control
        if [ -f '/root/.local/bin/isg-android-control' ]; then
            /root/.local/bin/isg-android-control version
        elif [ -f './isg-android-control' ]; then
            ./isg-android-control version
        else
            echo 'v1.0.0'  # 默认版本
        fi
    " > "$TEMP_VERSION_FILE" 2>/dev/null; then
        VERSION_STR=$(cat "$TEMP_VERSION_FILE" | head -n1 | tr -d '\n\r\t ')
        rm -f "$TEMP_VERSION_FILE"
    else
        rm -f "$TEMP_VERSION_FILE"
        VERSION_STR="v1.0.0"  # 默认版本
    fi
fi

log "isg-android-control 版本: $VERSION_STR"

# -----------------------------------------------------------------------------
# 注册 servicemonitor 服务看护
# -----------------------------------------------------------------------------
log "注册 servicemonitor 服务"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"registering servicemonitor service\",\"timestamp\":$(date +%s)}"

# 创建服务目录
mkdir -p "$SERVICE_CONTROL_DIR"

# 写入 run 启动脚本
cat << 'EOF' > "$RUN_FILE"
#!/data/data/com.termux/files/usr/bin/sh
export PROCESS_TAG="${PROCESS_TAG}"
exec proot-distro login ubuntu -- bash -lc '
  set -e
  
  # 检查Redis端口6379是否已经运行
  echo "检查Redis服务状态..."
  if netstat -tulpn | grep -q ":6379 "; then
    echo "Redis服务已运行在端口6379"
  else
    echo "Redis服务未运行，正在启动..."
    
    # 尝试启动Redis服务器（后台运行）
    if redis-server /etc/redis/redis.conf --daemonize yes; then
      echo "Redis启动命令已执行"
      
      # 等待一下让Redis完全启动
      sleep 3
      
      # 再次检查是否启动成功
      if netstat -tulpn | grep -q ":6379 "; then
        echo "Redis服务启动成功"
      else
        echo "Redis服务启动失败，尝试前台模式获取错误信息..."
        # 前台模式启动以查看错误
        redis-server /etc/redis/redis.conf &
        sleep 2
      fi
    else
      echo "Redis启动失败"
      exit 1
    fi
  fi
  
  # 最终验证Redis是否可用
  echo "验证Redis连接..."
  if redis-cli ping >/dev/null 2>&1; then
    echo "Redis连接正常"
  else
    echo "警告：Redis无法连接，但继续执行后续命令"
  fi
  
  # 启动isg-android-control服务
  /root/.local/bin/isg-android-control start
'
EOF

# 赋予执行权限
chmod +x "$RUN_FILE"

# 创建 down 文件（初始状态不自启）
touch "$DOWN_FILE"

log "servicemonitor 服务注册成功"

# -----------------------------------------------------------------------------
# 启动服务测试
# -----------------------------------------------------------------------------
log "启动服务进行测试"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"starting service for testing\",\"timestamp\":$(date +%s)}"

bash "$SERVICE_DIR/start.sh"

# -----------------------------------------------------------------------------
# 等待服务启动
# -----------------------------------------------------------------------------
log "等待服务就绪"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"waiting for service ready\",\"timestamp\":$(date +%s)}"

WAITED=0
while [ "$WAITED" -lt "$MAX_WAIT" ]; do
    if bash "$SERVICE_DIR/status.sh" --quiet; then
        log "服务在 ${WAITED}s 后启动成功"
        break
    fi
    sleep "$INTERVAL"
    WAITED=$((WAITED + INTERVAL))
done

if [ "$WAITED" -ge "$MAX_WAIT" ]; then
    log "超时: 服务在 ${MAX_WAIT}s 后仍未启动"
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
log "记录安装历史"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"recording installation history\",\"version\":\"$VERSION_STR\",\"timestamp\":$(date +%s)}"

echo "$VERSION_STR" > "$VERSION_FILE"
record_install_history "SUCCESS" "$VERSION_STR"

# -----------------------------------------------------------------------------
# 安装完成
# -----------------------------------------------------------------------------
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

log "isg-android-control 安装成功完成，耗时 ${DURATION}s"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"installed\",\"version\":\"$VERSION_STR\",\"duration\":$DURATION,\"timestamp\":$END_TIME}"

log "安装摘要:"
log "  - 源目录: $ANDROID_CONTROL_SOURCE"
log "  - 目标目录: $ANDROID_CONTROL_INSTALL_DIR (proot环境内)"
log "  - 版本: $VERSION_STR"
log "  - 耗时: ${DURATION}s"

exit 0

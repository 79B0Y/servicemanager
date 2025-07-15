#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Home Assistant 安装脚本
# 版本: v1.4.0
# 功能: 在 proot Ubuntu 环境中安装 Home Assistant
# =============================================================================

set -euo pipefail

# 加载统一路径定义
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common_paths.sh" || {
    echo "Error: Cannot load common paths"
    exit 1
}

# 设置脚本特定的日志文件
LOG_FILE="$LOG_FILE_INSTALL"

# 确保必要目录存在
ensure_directories

HASS_VERSION="${TARGET_VERSION:-$DEFAULT_HA_VERSION}"
START_TIME=$(date +%s)

log "starting Home Assistant installation process"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"starting installation process\",\"timestamp\":$(date +%s)}"

# -----------------------------------------------------------------------------
# 读取服务依赖配置
# -----------------------------------------------------------------------------
log "reading service dependencies from serviceupdate.json"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"reading service dependencies from serviceupdate.json\",\"timestamp\":$(date +%s)}"

if [ ! -f "$SERVICEUPDATE_FILE" ]; then
    log "serviceupdate.json not found, using default dependencies"
    DEPENDENCIES='["python3","python3-pip","python3-venv","ffmpeg","libturbojpeg0-dev","gcc","g++","make","build-essential"]'
else
    DEPENDENCIES=$(jq -c ".services[] | select(.id==\"$SERVICE_ID\") | .install_dependencies // [\"python3\",\"python3-pip\",\"python3-venv\",\"ffmpeg\",\"libturbojpeg0-dev\",\"gcc\",\"g++\",\"make\",\"build-essential\"]" "$SERVICEUPDATE_FILE" 2>/dev/null || echo '["python3","python3-pip","python3-venv","ffmpeg","libturbojpeg0-dev","gcc","g++","make","build-essential"]')
fi

# 转换为 bash 数组
DEPS_ARRAY=($(echo "$DEPENDENCIES" | jq -r '.[]' 2>/dev/null || echo "python3 python3-pip python3-venv ffmpeg libturbojpeg0-dev gcc g++ make build-essential"))

log "installing required dependencies: ${DEPS_ARRAY[*]}"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"installing required dependencies\",\"dependencies\":$DEPENDENCIES,\"timestamp\":$(date +%s)}"

# -----------------------------------------------------------------------------
# 安装系统依赖
# -----------------------------------------------------------------------------
log "installing system dependencies in proot container"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"installing system dependencies\",\"timestamp\":$(date +%s)}"

if ! proot-distro login "$PROOT_DISTRO" -- bash -c "
    apt update
    apt install -y ${DEPS_ARRAY[*]}
"; then
    log "failed to install system dependencies"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"dependency installation failed\",\"dependencies\":$DEPENDENCIES,\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

# -----------------------------------------------------------------------------
# 清理旧环境
# -----------------------------------------------------------------------------
log "cleaning up old installation"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"cleaning up old installation\",\"timestamp\":$(date +%s)}"

proot-distro login "$PROOT_DISTRO" -- bash -c "
    [ -d $HA_VENV_DIR ] && rm -rf $HA_VENV_DIR
    [ -d $HA_CONFIG_DIR ] && rm -rf $HA_CONFIG_DIR
"

# -----------------------------------------------------------------------------
# 创建 Python 虚拟环境
# -----------------------------------------------------------------------------
log "creating Python virtual environment"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"creating virtual environment\",\"timestamp\":$(date +%s)}"

# 获取时区设置
TZ_VAL=$(getprop persist.sys.timezone 2>/dev/null || echo "Asia/Shanghai")

if ! proot-distro login "$PROOT_DISTRO" -- bash -c "
    export TZ=\"$TZ_VAL\"
    python3 -m venv $HA_VENV_DIR
    source $HA_VENV_DIR/bin/activate
    pip install --upgrade pip wheel setuptools
"; then
    log "failed to create virtual environment"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"virtual environment creation failed\",\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

# -----------------------------------------------------------------------------
# 安装 Python 依赖
# -----------------------------------------------------------------------------
log "installing Python dependencies"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"installing python dependencies\",\"timestamp\":$(date +%s)}"

if ! proot-distro login "$PROOT_DISTRO" -- bash -c "
    export TZ=\"$TZ_VAL\"
    source $HA_VENV_DIR/bin/activate
    pip install numpy mutagen pillow aiohttp_fast_zlib
    pip install aiohttp==3.10.8 attrs==23.2.0
    pip install PyTurboJPEG
"; then
    log "failed to install Python dependencies"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"python dependencies installation failed\",\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

# -----------------------------------------------------------------------------
# 安装 Home Assistant
# -----------------------------------------------------------------------------
log "installing Home Assistant $HASS_VERSION"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"installing Home Assistant\",\"version\":\"$HASS_VERSION\",\"timestamp\":$(date +%s)}"

if ! proot-distro login "$PROOT_DISTRO" -- bash -c "
    export TZ=\"$TZ_VAL\"
    source $HA_VENV_DIR/bin/activate
    pip install homeassistant==$HASS_VERSION
"; then
    log "failed to install Home Assistant"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"Home Assistant installation failed\",\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

# 获取安装的版本
VERSION_STR=$(get_current_ha_version)
log "Home Assistant version: $VERSION_STR"

# -----------------------------------------------------------------------------
# 生成初始配置
# -----------------------------------------------------------------------------
log "generating initial configuration"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"generating initial configuration\",\"timestamp\":$(date +%s)}"

bash "$SERVICE_DIR/restore.sh"

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

# 让服务稳定运行5分钟，每分钟检查一次
log "letting service stabilize for 5 minutes"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"stabilizing service for 5 minutes\",\"timestamp\":$(date +%s)}"

for i in {1..5}; do
    if ! bash "$SERVICE_DIR/status.sh" --quiet; then
        log "service stopped during stabilization at minute $i"
        break
    fi
    sleep 60
done

# -----------------------------------------------------------------------------
# 停止服务 (安装完成后暂停运行)
# -----------------------------------------------------------------------------
bash "$SERVICE_DIR/stop.sh"

# -----------------------------------------------------------------------------
# 安装加速库
# -----------------------------------------------------------------------------
log "installing acceleration libraries"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"installing acceleration libraries\",\"timestamp\":$(date +%s)}"

proot-distro login "$PROOT_DISTRO" -- bash -c "
    source $HA_VENV_DIR/bin/activate
    pip install --force-reinstall zlib-ng isal --no-binary :all:
" || log "warning: acceleration libraries installation failed, continuing anyway"

# -----------------------------------------------------------------------------
# 配置优化
# -----------------------------------------------------------------------------
log "applying configuration optimizations"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"applying configuration optimizations\",\"timestamp\":$(date +%s)}"

proot-distro login "$PROOT_DISTRO" -- bash -c "
    # 添加日志级别配置
    if ! grep -q '^logger:' $HA_CONFIG_DIR/configuration.yaml; then
        echo -e '\nlogger:\n  default: warning' >> $HA_CONFIG_DIR/configuration.yaml
    fi
    
    # 添加HTTP配置
    if ! grep -q 'use_x_frame_options:' $HA_CONFIG_DIR/configuration.yaml; then
        echo -e '\nhttp:\n  use_x_frame_options: false' >> $HA_CONFIG_DIR/configuration.yaml
    fi
"

# -----------------------------------------------------------------------------
# 记录安装历史
# -----------------------------------------------------------------------------
log "recording installation history"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"recording installation history\",\"version\":\"$VERSION_STR\",\"timestamp\":$(date +%s)}"

echo "$VERSION_STR" > "$VERSION_FILE"
record_install_history "SUCCESS" "$VERSION_STR"

# -----------------------------------------------------------------------------
# 最终启动验证
# -----------------------------------------------------------------------------
log "final startup verification"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"final startup verification\",\"timestamp\":$(date +%s)}"

bash "$SERVICE_DIR/start.sh"

# 等待服务完全启动
WAITED=0
while [ "$WAITED" -lt "$MAX_WAIT" ]; do
    if bash "$SERVICE_DIR/status.sh" --quiet; then
        END_TIME=$(date +%s)
        DURATION=$((END_TIME - START_TIME))
        
        log "Home Assistant installation completed successfully in ${DURATION}s"
        mqtt_report "isg/install/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"success\",\"version\":\"$VERSION_STR\",\"duration\":$DURATION,\"timestamp\":$END_TIME}"
        exit 0
    fi
    sleep "$INTERVAL"
    WAITED=$((WAITED + INTERVAL))
done

log "timeout: service not running after final verification"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"service failed to start after installation\",\"timestamp\":$(date +%s)}"
exit 1

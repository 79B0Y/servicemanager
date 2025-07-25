#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Home Assistant 安装脚本
# 版本: v1.4.1
# 功能: 在 proot Ubuntu 环境中安装 Home Assistant
# 优化: 1. 使用 heredoc 减少 proot 调用次数 2. 检查 Python 版本避免重复安装
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
MIN_PYTHON_VERSION="3.10.0"

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
# 检查和安装系统依赖（使用 heredoc 优化）
# -----------------------------------------------------------------------------
log "checking system environment and installing dependencies in proot container"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"checking system environment and installing dependencies\",\"timestamp\":$(date +%s)}"

# 获取时区设置
TZ_VAL=$(getprop persist.sys.timezone 2>/dev/null || echo "Asia/Shanghai")

if ! proot-distro login "$PROOT_DISTRO" << EOF
set -euo pipefail

# 设置时区
export TZ="$TZ_VAL"

log_step() {
    echo "[STEP] \$1"
}

# 函数：检查 Python 版本
check_python_version() {
    local min_version="$MIN_PYTHON_VERSION"
    local current_version=""
    
    if command -v python3 >/dev/null 2>&1; then
        current_version=\$(python3 -c "import sys; print('.'.join(map(str, sys.version_info[:3])))" 2>/dev/null || echo "0.0.0")
        log_step "Found Python3 version: \$current_version"
        
        # 版本比较函数
        version_ge() {
            printf '%s\n%s\n' "\$2" "\$1" | sort -V -C
        }
        
        if version_ge "\$current_version" "\$min_version"; then
            log_step "Python version \$current_version >= \$min_version, skipping Python installation"
            return 0
        else
            log_step "Python version \$current_version < \$min_version, need to upgrade"
            return 1
        fi
    else
        log_step "Python3 not found, need to install"
        return 1
    fi
}

log_step "Checking existing Python installation"
NEED_PYTHON_INSTALL=true
if check_python_version; then
    NEED_PYTHON_INSTALL=false
    log_step "Python check passed"
else
    log_step "Python installation required"
fi

log_step "Updating package list"
apt update

# 过滤依赖包：如果 Python 版本足够，跳过 Python 相关包
FILTERED_DEPS=()
for dep in ${DEPS_ARRAY[*]}; do
    case "\$dep" in
        python3|python3-pip|python3-venv)
            if [ "\$NEED_PYTHON_INSTALL" = "true" ]; then
                FILTERED_DEPS+=("\$dep")
                log_step "Adding \$dep to install list"
            else
                log_step "Skipping \$dep (version sufficient)"
            fi
            ;;
        *)
            FILTERED_DEPS+=("\$dep")
            log_step "Adding \$dep to install list"
            ;;
    esac
done

if [ \${#FILTERED_DEPS[@]} -gt 0 ]; then
    log_step "Installing filtered dependencies: \${FILTERED_DEPS[*]}"
    apt install -y "\${FILTERED_DEPS[@]}"
else
    log_step "No additional packages needed"
fi

# 验证 Python 安装
log_step "Verifying Python installation"
if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: Python3 not available after installation"
    exit 1
fi

FINAL_PYTHON_VERSION=\$(python3 -c "import sys; print('.'.join(map(str, sys.version_info[:3])))")
log_step "Final Python version: \$FINAL_PYTHON_VERSION"

# 验证 pip 安装
if ! command -v pip3 >/dev/null 2>&1 && ! python3 -m pip --version >/dev/null 2>&1; then
    log_step "Installing pip using ensurepip"
    python3 -m ensurepip --upgrade
fi

log_step "System dependencies installation completed"
EOF
then
    log "failed to install system dependencies"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"dependency installation failed\",\"dependencies\":$DEPENDENCIES,\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

# -----------------------------------------------------------------------------
# 清理旧环境并创建虚拟环境
# -----------------------------------------------------------------------------
log "cleaning up old installation and creating virtual environment"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"creating virtual environment\",\"timestamp\":$(date +%s)}"

if ! proot-distro login "$PROOT_DISTRO" << EOF
set -euo pipefail
export TZ="$TZ_VAL"

log_step() {
    echo "[STEP] \$1"
}

log_step "Cleaning up old installation"
[ -d $HA_VENV_DIR ] && rm -rf $HA_VENV_DIR
[ -d $HA_CONFIG_DIR ] && rm -rf $HA_CONFIG_DIR

log_step "Creating Python virtual environment"
python3 -m venv $HA_VENV_DIR

log_step "Activating virtual environment"
source $HA_VENV_DIR/bin/activate

log_step "Upgrading pip and basic tools"
pip install --upgrade pip wheel setuptools

log_step "Verifying virtual environment"
which python
python --version
which pip
pip --version

log_step "Virtual environment setup completed"
EOF
then
    log "failed to create virtual environment"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"virtual environment creation failed\",\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

# -----------------------------------------------------------------------------
# 安装 Python 依赖和 Home Assistant
# -----------------------------------------------------------------------------
log "installing Python dependencies and Home Assistant $HASS_VERSION"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"installing Home Assistant\",\"version\":\"$HASS_VERSION\",\"timestamp\":$(date +%s)}"

if ! proot-distro login "$PROOT_DISTRO" << EOF
set -euo pipefail
export TZ="$TZ_VAL"

log_step() {
    echo "[STEP] \$1"
}

log_step "Activating virtual environment"
source $HA_VENV_DIR/bin/activate

log_step "Installing base Python dependencies"
pip install numpy mutagen pillow aiohttp_fast_zlib

log_step "Installing specific version dependencies"
pip install aiohttp==3.10.8 attrs==23.2.0

log_step "Installing PyTurboJPEG for image processing"
pip install PyTurboJPEG

log_step "Installing Home Assistant $HASS_VERSION"
pip install homeassistant==$HASS_VERSION

log_step "Verifying Home Assistant installation"
hass --version

log_step "Python dependencies and Home Assistant installation completed"
EOF
then
    log "failed to install Home Assistant"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"Home Assistant installation failed\",\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

# 获取安装的版本
VERSION_STR=$(get_current_ha_version)
log "Home Assistant version: $VERSION_STR"

# -----------------------------------------------------------------------------
# 自动生成初始配置
# -----------------------------------------------------------------------------
log "automatically generating initial configuration"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"generating initial configuration\",\"timestamp\":$(date +%s)}"

# 确保配置目录存在
proot-distro login "$PROOT_DISTRO" -- mkdir -p "$HA_CONFIG_DIR"

# 检查是否已有配置文件
if proot-distro login "$PROOT_DISTRO" -- test -f "$HA_CONFIG_DIR/configuration.yaml"; then
    log "configuration file already exists, skipping restore"
else
    log "no existing configuration found, running restore to generate default config"
    # 调用 restore.sh 生成默认配置，但不启动服务（因为我们马上要测试启动）
    if ! bash "$SERVICE_DIR/restore.sh"; then
        log "warning: restore failed, will generate minimal config"
        # 如果 restore 失败，生成最小配置以确保 HA 能够启动
        proot-distro login "$PROOT_DISTRO" << EOF
log_step() {
    echo "[STEP] \$1"
}

log_step "Generating minimal configuration as fallback"
cat > $HA_CONFIG_DIR/configuration.yaml << 'CONFIG_EOF'
# Loads default set of integrations. Do not remove.
default_config:

# Load frontend themes from the themes folder
frontend:
  themes: !include_dir_merge_named themes

automation: !include automations.yaml
script: !include scripts.yaml
scene: !include scenes.yaml
config_editor:
logger:
  default: critical

http:
  use_x_frame_options: false
CONFIG_EOF

# Create empty automation files
echo '[]' > $HA_CONFIG_DIR/automations.yaml
echo '{}' > $HA_CONFIG_DIR/scripts.yaml
echo '[]' > $HA_CONFIG_DIR/scenes.yaml

log_step "Minimal configuration generated successfully"
EOF
    fi
fi

# -----------------------------------------------------------------------------
# 首次启动测试
# -----------------------------------------------------------------------------
log "performing first startup test"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"performing first startup test\",\"timestamp\":$(date +%s)}"

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
# 安装加速库和配置优化（使用 heredoc）
# -----------------------------------------------------------------------------
log "installing acceleration libraries and applying optimizations"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"installing acceleration libraries and optimizations\",\"timestamp\":$(date +%s)}"

proot-distro login "$PROOT_DISTRO" << EOF || log "warning: acceleration libraries installation failed, continuing anyway"
set -euo pipefail

log_step() {
    echo "[STEP] \$1"
}

log_step "Activating virtual environment"
source $HA_VENV_DIR/bin/activate

log_step "Installing acceleration libraries"
pip install --force-reinstall zlib-ng isal --no-binary :all: || echo "Warning: Some acceleration libraries failed to install"

log_step "Applying configuration optimizations"
# 添加日志级别配置
if ! grep -q '^logger:' $HA_CONFIG_DIR/configuration.yaml; then
    echo -e '\nlogger:\n  default: warning' >> $HA_CONFIG_DIR/configuration.yaml
fi

# 添加HTTP配置
if ! grep -q 'use_x_frame_options:' $HA_CONFIG_DIR/configuration.yaml; then
    echo -e '\nhttp:\n  use_x_frame_options: false' >> $HA_CONFIG_DIR/configuration.yaml
fi

log_step "Configuration optimizations completed"
EOF

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

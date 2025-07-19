**文档版本**: v2.0.0  
**最后更新**: 2025-07-16  
**维护者**: LinknLink 技术团队

# 整体服务管理系统总体设计文档

## 1. 系统概览

### 1.1 系统架构
```
LinknLink IoT 服务管理系统
├── 系统基础设施
│   ├── autocheckall.sh           # 全局监控调度器
│   ├── statuscheck.sh            # 全局查询所有服务的安装状态和运行状态，调用每个服务里的status.sh，然后汇总通过MQTT上报
│   ├── configuration.yaml        # 全局配置文件
│   ├── serviceupdate.sh          # 服务更新管理器
│   ├── serviceupdate.json        # 服务版本信息库
│   ├── detect_serial_adapters.py        # 检测串口信息是否支持zigbee还是zwave
│   ├── zigbee_known.yaml        # zigbee硬件数据库
│   └── requirements.yaml         # 依赖管理配置
├── 核心服务模块
│   ├── Home Assistant (hass)     # 智能家居中枢
│   ├── Zigbee2MQTT (zigbee2mqtt) # Zigbee设备桥接
│   ├── Node-RED (node-red)       # 流程自动化
│   ├── MySQL数据库 (mysqld)       # 数据存储
│   └── SSH服务 (sshd)            # 远程访问
└── 监控基础设施
    ├── isgservicemonitor         # 服务进程监控
    ├── runit/runsvdir           # 进程管理器
    └── MQTT消息总线              # 状态通信
```

### 1.2 设计原则
- **统一管理**: 所有服务使用相同的管理接口和状态报告格式
- **模块化设计**: 每个服务独立管理，互不干扰
- **容器化隔离**: 服务运行在proot容器中，环境隔离
- **实时监控**: 完整的MQTT状态上报和性能监控
- **自动化运维**: 自动检查、恢复、更新机制

## 2. 核心组件详细设计

### 2.1 autocheckall.sh - 全局监控调度器

#### 2.1.1 功能职责
- **系统基础设施检查**: runsvdir、isgservicemonitor状态监控
- **服务编排调度**: 按优先级顺序执行各服务的autocheck.sh
- **全局状态汇总**: 收集所有服务状态并统一上报
- **故障自动恢复**: 检测到系统级问题时自动修复

#### 2.1.2 执行流程
```mermaid
flowchart TD
    A[获取锁文件] --> B[加载MQTT配置]
    B --> C[检查runsvdir状态]
    C --> D[检查服务目录配置]
    D --> E[检查runsv监控状态]
    E --> F[启动isgservicemonitor]
    F --> G[执行各服务autocheck]
    G --> H[汇总版本信息]
    H --> I[上报系统状态]
    I --> J[释放锁文件]
```

#### 2.1.3 关键实现逻辑
```bash
# 1. 系统基础设施检查
check_runit_infrastructure() {
    # 检查runsvdir进程状态
    if ! pgrep -f runsvdir >/dev/null; then
        restart_runsvdir
    fi
    
    # 验证服务目录权限
    validate_service_directories
    
    # 确保监控服务运行
    ensure_isgservicemonitor_running
}

# 2. 服务autocheck执行
execute_service_autochecks() {
    for service_path in "$SERVICEMANAGER_DIR"/*; do
        if [ -f "$service_path/autocheck.sh" ]; then
            service_id=$(basename "$service_path")
            if [[ ! ",${SKIP_SERVICES}," =~ ",$service_id," ]]; then
                bash "$service_path/autocheck.sh"
            fi
        fi
    done
}

# 3. 全局状态汇总
generate_global_status() {
    collect_service_versions
    aggregate_health_status
    mqtt_report "isg/status/versions" "$version_summary"
}
```

#### 2.1.4 MQTT状态上报
| 主题 | 内容 | 说明 |
|-----|------|------|
| `isg/system/runit/status` | runsvdir状态 | 进程管理器状态 |
| `isg/system/isgservicemonitor/status` | 监控程序状态 | 服务监控器状态 |
| `isg/status/versions` | 全服务版本汇总 | 所有服务版本信息 |

### 2.2 configuration.yaml - 全局配置文件

#### 2.2.1 配置结构设计
```yaml
# ========== MQTT通信配置 ==========
mqtt:
  host: 127.0.0.1                 # MQTT服务器地址
  port: 1883                      # MQTT服务器端口
  username: admin                 # MQTT用户名
  password: admin                 # MQTT密码
  tls: false                      # 是否启用TLS加密
  cert_path: ""                   # TLS证书路径
  keepalive: 30                   # 心跳间隔(秒)
  debug: false                    # 是否打印MQTT调试日志

# ========== 全局系统配置 ==========
global:
  log_dir: /data/data/com.termux/files/home/servicemanager/logs
  skip_services: ""               # 跳过的服务列表，逗号分隔
  update_interval: 21600          # 自动更新检查间隔(秒)
  max_log_size: 10485760         # 日志文件最大大小(字节)
  log_retention_days: 7           # 日志保留天数
  backup_retention_count: 5       # 备份文件保留数量

# ========== 容器环境配置 ==========
containers:
  default_distro: ubuntu          # 默认proot容器
  data_root: /data/data/com.termux/files/home/servicemanager
  backup_root: /sdcard/isgbackup
  temp_root: /data/data/com.termux/files/usr/tmp

# ========== 服务特定配置 ==========
services:
  hass:
    enabled: true
    priority: 1                   # 启动优先级
    dependencies: ["mysqld"]      # 依赖服务
    health_check_interval: 300    # 健康检查间隔
    auto_restart: true           # 自动重启
    
  zigbee2mqtt:
    enabled: true
    priority: 2
    dependencies: []
    health_check_interval: 180
    auto_restart: true
    
  node-red:
    enabled: true
    priority: 3
    dependencies: []
    health_check_interval: 120
    auto_restart: true
    
  mysqld:
    enabled: true
    priority: 0                   # 基础服务，最高优先级
    dependencies: []
    health_check_interval: 600
    auto_restart: true
    
  sshd:
    enabled: true
    priority: 0
    dependencies: []
    health_check_interval: 900
    auto_restart: false

# ========== 监控告警配置 ==========
monitoring:
  enable_alerts: true
  alert_channels: ["mqtt", "log"]
  thresholds:
    cpu_usage: 80                # CPU使用率告警阈值(%)
    memory_usage: 85             # 内存使用率告警阈值(%)
    disk_usage: 90               # 磁盘使用率告警阈值(%)
    service_restart_count: 3     # 服务重启次数告警阈值

# ========== 安全配置 ==========
security:
  enable_firewall: false         # 是否启用防火墙规则
  allowed_networks: []           # 允许访问的网络段
  fail2ban_enabled: false        # 是否启用失败登录保护
  log_sensitive_data: false      # 是否记录敏感数据日志
```

#### 2.2.2 配置使用方式
```bash
# 通用配置读取函数
load_global_config() {
    MQTT_HOST=$(yq eval '.mqtt.host' "$CONFIG_FILE")
    MQTT_PORT=$(yq eval '.mqtt.port' "$CONFIG_FILE")
    SKIP_SERVICES=$(yq eval '.global.skip_services' "$CONFIG_FILE")
    UPDATE_INTERVAL=$(yq eval '.global.update_interval' "$CONFIG_FILE")
}

# 服务特定配置读取
load_service_config() {
    local service_id="$1"
    SERVICE_ENABLED=$(yq eval ".services.$service_id.enabled" "$CONFIG_FILE")
    SERVICE_PRIORITY=$(yq eval ".services.$service_id.priority" "$CONFIG_FILE")
    DEPENDENCIES=$(yq eval ".services.$service_id.dependencies[]" "$CONFIG_FILE")
}
```

### 2.3 serviceupdate.json - 服务版本信息库

#### 2.3.1 数据结构设计
```json
{
  "generated": "2025-07-16T12:00:00Z",
  "metadata": {
    "version": "2.0.0",
    "update_interval": 3600,
    "last_check": "2025-07-16T11:30:00Z",
    "source": "https://api.linknlink.com/services/updates"
  },
  "global_dependencies": {
    "termux_packages": [
      "pkg install netcat-openbsd",
      "pkg install jq", 
      "pkg install python",
      "pip install pyserial pyyaml"
    ],
    "proot_packages": [
      "apt update && apt install -y netcat jq unzip curl wget",
      "apt install -y python3 python3-pip python3-venv"
    ]
  },
  "services": [
    {
      "id": "hass",
      "display_name": "Home Assistant Core",
      "category": "automation",
      "enabled": true,
      "current_script_version": "1.3.2",
      "latest_script_version": "1.4.0",
      "latest_script_package_url": "https://dl.linknlink.com/services/hass-scripts-1.4.0.tar.gz",
      "latest_script_package_sha256": "abc123def456789...",
      "current_service_version": "2025.5.3",
      "latest_service_version": "2025.7.1",
      "compatibility": {
        "min_python_version": "3.11",
        "supported_architectures": ["arm64", "aarch64"],
        "required_memory_mb": 1024,
        "required_disk_mb": 2048
      },
      "upgrade_dependencies": [
        "click==8.1.7",
        "home-assistant-frontend==20250701.0"
      ],
      "install_dependencies": [
        "python3",
        "python3-pip", 
        "python3-venv",
        "ffmpeg",
        "libturbojpeg0-dev",
        "gcc",
        "g++",
        "make",
        "build-essential"
      ],
      "security_updates": [
        {
          "cve": "CVE-2025-1234",
          "severity": "medium",
          "fixed_in": "2025.7.1"
        }
      ],
      "changelog_url": "https://github.com/home-assistant/core/releases/tag/2025.7.1",
      "documentation_url": "https://www.home-assistant.io/docs/",
      "notes": "Support for new MQTT schema and stability fixes."
    },
    {
      "id": "zigbee2mqtt", 
      "display_name": "Zigbee2MQTT",
      "category": "gateway",
      "enabled": true,
      "current_script_version": "1.0.0",
      "latest_script_version": "1.1.0",
      "latest_script_package_url": "https://dl.linknlink.com/services/zigbee2mqtt-scripts-1.1.0.tar.gz",
      "latest_script_package_sha256": "def789abc456123...",
      "current_service_version": "2.5.1",
      "latest_service_version": "2.5.3",
      "compatibility": {
        "min_node_version": "18.0.0",
        "supported_architectures": ["arm64", "aarch64"],
        "required_memory_mb": 256,
        "required_disk_mb": 512
      },
      "upgrade_dependencies": [
        "zigbee-herdsman@0.46.4",
        "zigbee-herdsman-converters@18.67.1"
      ],
      "install_dependencies": [
        "nodejs",
        "git",
        "make", 
        "g++",
        "gcc",
        "libsystemd-dev"
      ],
      "security_updates": [],
      "changelog_url": "https://github.com/Koenkk/zigbee2mqtt/releases/tag/2.5.3",
      "documentation_url": "https://www.zigbee2mqtt.io/",
      "notes": "Improved Zigbee adapter support and new device definitions."
    },
    {
      "id": "node-red",
      "display_name": "Node-RED", 
      "category": "automation",
      "enabled": true,
      "current_script_version": "1.0.0",
      "latest_script_version": "1.0.0",
      "latest_script_package_url": "https://dl.linknlink.com/services/node-red-scripts-1.0.0.tar.gz",
      "latest_script_package_sha256": "ghi789def456123...",
      "current_service_version": "4.0.9",
      "latest_service_version": "4.0.10",
      "compatibility": {
        "min_node_version": "18.0.0",
        "supported_architectures": ["arm64", "aarch64"], 
        "required_memory_mb": 128,
        "required_disk_mb": 256
      },
      "upgrade_dependencies": [
        "node-red-contrib-dashboard@3.6.0",
        "@node-red/nodes@1.4.0"
      ],
      "install_dependencies": [
        "nodejs",
        "npm"
      ],
      "security_updates": [
        {
          "cve": "CVE-2025-5678",
          "severity": "low", 
          "fixed_in": "4.0.10"
        }
      ],
      "changelog_url": "https://github.com/node-red/node-red/releases/tag/4.0.10",
      "documentation_url": "https://nodered.org/docs/",
      "notes": "Visual programming for IoT and automation flows."
    }
  ]
}
```

#### 2.3.2 动态更新机制
```bash
# serviceupdate.json更新流程
update_service_metadata() {
    local temp_file="/tmp/serviceupdate.json.tmp"
    
    # 1. 从远程服务器获取最新信息
    curl -s -o "$temp_file" "$UPDATE_SOURCE_URL" || {
        log "Failed to fetch service updates from remote"
        return 1
    }
    
    # 2. 验证JSON格式
    jq . "$temp_file" >/dev/null || {
        log "Invalid JSON format in service update"
        return 1
    }
    
    # 3. 备份当前文件
    cp "$SERVICEUPDATE_FILE" "$SERVICEUPDATE_FILE.backup"
    
    # 4. 更新文件
    mv "$temp_file" "$SERVICEUPDATE_FILE"
    
    # 5. 上报更新事件
    mqtt_report "isg/system/serviceupdate" "{\"status\":\"updated\",\"timestamp\":$(date +%s)}"
}
```

### 2.4 serviceupdate.sh - 服务更新管理器

#### 2.4.1 功能设计
```bash
#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# 服务更新管理器
# 版本: v2.0.0
# 功能: 统一管理所有服务的版本检查、更新、依赖管理
# =============================================================================

# 主要功能模块
main() {
    case "${1:-check}" in
        check)      check_all_updates ;;
        update)     update_service "$2" ;;
        upgrade)    upgrade_all_services ;;
        rollback)   rollback_service "$2" ;;
        status)     show_update_status ;;
        *)          show_usage ;;
    esac
}

# 检查所有服务更新
check_all_updates() {
    log "Checking updates for all services..."
    
    # 1. 更新服务元数据
    update_service_metadata
    
    # 2. 检查各服务更新
    for service in $(get_enabled_services); do
        check_service_updates "$service"
    done
    
    # 3. 生成更新报告
    generate_update_report
    
    # 4. MQTT状态上报
    mqtt_report "isg/system/updates" "$update_summary"
}

# 单服务更新
update_service() {
    local service_id="$1"
    local target_version="$2"
    
    log "Updating service: $service_id to version: $target_version"
    
    # 1. 验证服务存在
    validate_service_exists "$service_id"
    
    # 2. 检查依赖关系
    check_service_dependencies "$service_id"
    
    # 3. 停止依赖服务
    stop_dependent_services "$service_id"
    
    # 4. 执行服务更新
    bash "$SERVICEMANAGER_DIR/$service_id/update.sh"
    
    # 5. 重启依赖服务
    start_dependent_services "$service_id"
    
    # 6. 验证更新结果
    verify_update_success "$service_id" "$target_version"
}

# 批量升级所有服务
upgrade_all_services() {
    local services=$(get_updatable_services)
    
    for service in $services; do
        if confirm_service_update "$service"; then
            update_service "$service"
            
            # 验证服务健康状态
            if ! verify_service_health "$service"; then
                log "Service $service failed health check after update"
                rollback_service "$service"
            fi
        fi
    done
}

# 服务回滚
rollback_service() {
    local service_id="$1"
    
    log "Rolling back service: $service_id"
    
    # 1. 获取上一个版本信息
    local previous_version=$(get_previous_version "$service_id")
    
    # 2. 停止当前服务
    bash "$SERVICEMANAGER_DIR/$service_id/stop.sh"
    
    # 3. 恢复备份
    restore_service_backup "$service_id" "$previous_version"
    
    # 4. 重启服务
    bash "$SERVICEMANAGER_DIR/$service_id/start.sh"
    
    # 5. 验证回滚结果
    verify_rollback_success "$service_id" "$previous_version"
}
```

#### 2.4.2 依赖管理机制
```bash
# 依赖关系管理
manage_service_dependencies() {
    local action="$1"  # install, update, remove
    local service_id="$2"
    
    case "$action" in
        "install")
            install_service_dependencies "$service_id"
            ;;
        "update") 
            update_service_dependencies "$service_id"
            ;;
        "remove")
            remove_service_dependencies "$service_id"
            ;;
    esac
}

# 安装服务依赖
install_service_dependencies() {
    local service_id="$1"
    
    # 1. 读取依赖列表
    local deps=$(get_service_dependencies "$service_id")
    
    # 2. 安装全局依赖
    install_global_dependencies
    
    # 3. 安装服务特定依赖
    for dep in $deps; do
        install_dependency "$dep"
    done
    
    # 4. 验证依赖安装
    verify_dependencies_installed "$service_id"
}

# 依赖冲突检测
detect_dependency_conflicts() {
    local conflicts=()
    
    # 检查版本冲突
    for service in $(get_all_services); do
        local service_deps=$(get_service_dependencies "$service")
        check_version_conflicts "$service_deps" conflicts
    done
    
    # 上报冲突信息
    if [ ${#conflicts[@]} -gt 0 ]; then
        mqtt_report "isg/system/dependency_conflicts" "$(printf '%s\n' "${conflicts[@]}" | jq -R . | jq -s .)"
    fi
}
```

### 2.5 requirements.yaml - 依赖管理配置

#### 2.5.1 分层依赖结构
```yaml
# ========== 系统基础依赖 ==========
system:
  termux:
    description: "Termux基础环境依赖"
    packages:
      - name: "netcat-openbsd"
        command: "pkg install netcat-openbsd"
        description: "网络连接测试工具"
        required_by: ["all"]
      - name: "jq" 
        command: "pkg install jq"
        description: "JSON处理工具"
        required_by: ["all"]
      - name: "python"
        command: "pkg install python"
        description: "Python运行环境"
        required_by: ["all"]
      - name: "proot-distro"
        command: "pkg install proot-distro"
        description: "容器环境"
        required_by: ["all"]
    python_packages:
      - name: "pyserial"
        command: "pip install pyserial"
        description: "串口通信库"
        required_by: ["zigbee2mqtt"]
      - name: "pyyaml"
        command: "pip install pyyaml"
        description: "YAML解析库"
        required_by: ["all"]
      - name: "requests"
        command: "pip install requests"
        description: "HTTP客户端库"
        required_by: ["hass", "serviceupdate"]

  proot_ubuntu:
    description: "Ubuntu容器基础依赖"
    packages:
      - name: "netcat"
        command: "apt update && apt install -y netcat"
        description: "网络连接测试"
        required_by: ["all"]
      - name: "jq"
        command: "apt install -y jq"
        description: "JSON处理工具"
        required_by: ["all"]
      - name: "unzip"
        command: "apt install -y unzip"
        description: "压缩文件处理"
        required_by: ["all"]
      - name: "curl"
        command: "apt install -y curl wget"
        description: "文件下载工具"
        required_by: ["all"]
      - name: "build-essential"
        command: "apt install -y build-essential"
        description: "编译工具链"
        required_by: ["hass", "zigbee2mqtt"]

# ========== 服务特定依赖 ==========
services:
  hass:
    description: "Home Assistant依赖环境"
    runtime_requirements:
      python_version: ">=3.11"
      memory_mb: 1024
      disk_mb: 2048
      cpu_cores: 2
    system_packages:
      - name: "python3"
        command: "apt install -y python3 python3-pip python3-venv"
        description: "Python运行环境"
      - name: "ffmpeg"
        command: "apt install -y ffmpeg"
        description: "多媒体处理"
      - name: "libturbojpeg"
        command: "apt install -y libturbojpeg0-dev"
        description: "图像处理加速"
      - name: "development-tools"
        command: "apt install -y gcc g++ make build-essential"
        description: "编译工具"
    python_packages:
      - name: "wheel"
        command: "pip3 install wheel"
        description: "Python包构建工具"
      - name: "homeassistant"
        command: "pip3 install homeassistant==${VERSION}"
        description: "Home Assistant核心"
        version_variable: "HASS_VERSION"
    optional_packages:
      - name: "numpy"
        command: "pip3 install numpy"
        description: "数值计算库(用于机器学习组件)"
      - name: "pillow"
        command: "pip3 install pillow"
        description: "图像处理库"
      - name: "opencv-python"
        command: "pip3 install opencv-python-headless"
        description: "计算机视觉库"

  zigbee2mqtt:
    description: "Zigbee2MQTT依赖环境"
    runtime_requirements:
      node_version: ">=18.0.0"
      memory_mb: 256
      disk_mb: 512
      cpu_cores: 1
    system_packages:
      - name: "nodejs"
        command: "curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && apt install -y nodejs"
        description: "Node.js运行环境"
      - name: "development-tools"
        command: "apt install -y git make g++ gcc"
        description: "编译工具"
      - name: "libsystemd"
        command: "apt install -y libsystemd-dev"
        description: "系统服务库"
    npm_packages:
      - name: "pnpm"
        command: "npm install -g pnpm@10.11.0"
        description: "包管理器"
      - name: "zigbee2mqtt"
        command: "pnpm add zigbee2mqtt@${VERSION}"
        description: "Zigbee2MQTT核心"
        version_variable: "Z2M_VERSION"

  node-red:
    description: "Node-RED依赖环境"
    runtime_requirements:
      node_version: ">=18.0.0"
      memory_mb: 128
      disk_mb: 256
      cpu_cores: 1
    system_packages:
      - name: "nodejs"
        command: "apt install -y nodejs npm"
        description: "Node.js和npm"
    npm_packages:
      - name: "pnpm"
        command: "npm install -g pnpm"
        description: "包管理器"
      - name: "node-red"
        command: "pnpm add node-red@${VERSION}"
        description: "Node-RED核心"
        version_variable: "NR_VERSION"
    optional_packages:
      - name: "node-red-dashboard"
        command: "pnpm add node-red-contrib-dashboard"
        description: "仪表盘界面"
      - name: "node-red-mqtt"
        command: "pnpm add node-red-contrib-mqtt-broker"
        description: "MQTT节点"

# ========== 环境检查配置 ==========
environment_checks:
  system:
    - name: "termux_version"
      command: "termux-info | grep 'Termux version'"
      required: true
      description: "检查Termux版本"
    - name: "android_version"
      command: "getprop ro.build.version.release"
      required: false
      description: "检查Android版本"
    - name: "available_memory"
      command: "free -m | awk '/^Mem:/{print $2}'"
      threshold: 2048
      description: "检查可用内存(MB)"
    - name: "available_disk"
      command: "df -h /data | awk 'NR==2{print $4}'"
      threshold: "2G"
      description: "检查可用磁盘空间"

  proot:
    - name: "ubuntu_version"
      command: "lsb_release -rs"
      required: true
      description: "检查Ubuntu版本"
    - name: "python_version"
      command: "python3 --version | cut -d' ' -f2"
      min_version: "3.11"
      description: "检查Python版本"
    - name: "node_version"
      command: "node --version | cut -d'v' -f2"
      min_version: "18.0.0"
      description: "检查Node.js版本"

# ========== 安装顺序配置 ==========
installation_order:
  phases:
    - name: "system_preparation"
      description: "系统环境准备"
      packages: ["termux.packages", "proot_ubuntu.packages"]
      parallel: false
    - name: "runtime_installation" 
      description: "运行时环境安装"
      packages: ["services.*.system_packages"]
      parallel: true
    - name: "service_packages"
      description: "服务特定包安装"
      packages: ["services.*.python_packages", "services.*.npm_packages"]
      parallel: true
    - name: "optional_components"
      description: "可选组件安装"
      packages: ["services.*.optional_packages"]
      parallel: true
      continue_on_error: true

# ========== 版本兼容性矩阵 ==========
compatibility_matrix:
  python_versions:
    "3.11": ["hass>=2025.1.0"]
    "3.12": ["hass>=2025.6.0"]
  node_versions:
    "18.x": ["zigbee2mqtt>=1.33.0", "node-red>=3.0.0"]
    "20.x": ["zigbee2mqtt>=1.35.0", "node-red>=4.0.0"]
  architecture_support:
    "arm64": ["all_services"]
    "aarch64": ["all_services"] 
    "x86_64": ["hass", "node-red"]
```

#### 2.5.2 依赖管理实现
```bash
# 依赖安装引擎
install_requirements() {
    local target_service="$1"
    local phase="${2:-all}"
    
    log "Installing requirements for service: $target_service, phase: $phase"
    
    # 1. 环境检查
    check_environment_requirements
    
    # 2. 按阶段安装依赖
    case "$phase" in
        "system"|"all")
            install_system_requirements
            ;;
        "service"|"all")
            install_service_requirements "$target_service"
            ;;
        "optional"|"all")
            install_optional_requirements "$target_service"
            ;;
    esac
    
    # 3. 验证安装结果
    verify_requirements_installed "$target_service"
}

# 环境检查
check_environment_requirements() {
    local failed_checks=()
    
    # 系统环境检查
    while IFS= read -r check; do
        local name=$(echo "$check" | yq eval '.name' -)
        local command=$(echo "$check" | yq eval '.command' -)
        local required=$(echo "$check" | yq eval '.required' -)
        
        if ! eval "$command" >/dev/null 2>&1; then
            if [ "$required" = "true" ]; then
                failed_checks+=("$name")
            else
                log "Optional check failed: $name"
            fi
        fi
    done < <(yq eval '.environment_checks.system[]' "$REQUIREMENTS_FILE")
    
    # 报告检查结果
    if [ ${#failed_checks[@]} -gt 0 ]; then
        log "Environment check failed: ${failed_checks[*]}"
        return 1
    fi
}
```

## 3. 服务集成架构

### 3.1 服务间依赖关系
```mermaid
graph TB
    subgraph "基础设施层"
        MQTT[MQTT Broker]
        MySQL[MySQL数据库]
        SSH[SSH服务]
        Runit[Runit进程管理]
    end
    
    subgraph "核心服务层"
        HASS[Home Assistant]
        Z2M[Zigbee2MQTT]
        NR[Node-RED]
    end
    
    subgraph "管理监控层"
        ISG[isgservicemonitor]
        AC[autocheckall.sh]
        SU[serviceupdate.sh]
    end
    
    MySQL --> HASS
    MQTT --> HASS
    MQTT --> Z2M
    MQTT --> NR
    
    HASS --> Z2M
    HASS --> NR
    NR --> Z2M
    
    Runit --> ISG
    ISG --> HASS
    ISG --> Z2M
    ISG --> NR
    ISG --> MySQL
    ISG --> SSH
    
    AC --> ISG
    AC --> SU
    SU --> HASS
    SU --> Z2M
    SU --> NR
```

### 3.2 启动顺序管理
```bash
# 服务启动优先级控制
start_services_by_priority() {
    # 读取服务优先级配置
    local services=$(yq eval '.services | to_entries | sort_by(.value.priority) | .[].key' "$CONFIG_FILE")
    
    for service in $services; do
        local enabled=$(yq eval ".services.$service.enabled" "$CONFIG_FILE")
        local dependencies=$(yq eval ".services.$service.dependencies[]" "$CONFIG_FILE" 2>/dev/null)
        
        if [ "$enabled" = "true" ]; then
            # 检查依赖服务状态
            if check_dependencies_ready "$dependencies"; then
                log "Starting service: $service"
                bash "$SERVICEMANAGER_DIR/$service/start.sh"
                
                # 等待服务就绪
                wait_service_ready "$service"
            else
                log "Dependencies not ready for service: $service"
            fi
        fi
    done
}

# 依赖检查
check_dependencies_ready() {
    local dependencies="$1"
    
    for dep in $dependencies; do
        if ! bash "$SERVICEMANAGER_DIR/$dep/status.sh" --quiet; then
            return 1
        fi
    done
    return 0
}
```

### 3.3 故障隔离机制
```bash
# 服务故障隔离
isolate_failed_service() {
    local failed_service="$1"
    local failure_reason="$2"
    
    log "Isolating failed service: $failed_service, reason: $failure_reason"
    
    # 1. 停止故障服务
    bash "$SERVICEMANAGER_DIR/$failed_service/stop.sh"
    
    # 2. 标记服务为故障状态
    touch "$SERVICEMANAGER_DIR/$failed_service/.failed"
    echo "$failure_reason" > "$SERVICEMANAGER_DIR/$failed_service/.failure_reason"
    
    # 3. 通知依赖服务
    notify_dependent_services "$failed_service"
    
    # 4. 上报故障事件
    mqtt_report "isg/system/failure" "{\"service\":\"$failed_service\",\"reason\":\"$failure_reason\",\"timestamp\":$(date +%s)}"
    
    # 5. 尝试自动恢复
    schedule_auto_recovery "$failed_service"
}

# 自动恢复调度
schedule_auto_recovery() {
    local service="$1"
    local auto_restart=$(yq eval ".services.$service.auto_restart" "$CONFIG_FILE")
    
    if [ "$auto_restart" = "true" ]; then
        (
            sleep 300  # 等待5分钟后尝试恢复
            attempt_service_recovery "$service"
        ) &
    fi
}
```

## 4. 监控与告警体系

### 4.1 多层监控架构
```
监控层级:
├── L1: 进程级监控 (isgservicemonitor)
│   ├── 进程存活检查
│   ├── 资源使用监控
│   └── 自动重启机制
├── L2: 服务级监控 (各服务autocheck.sh)
│   ├── 功能健康检查
│   ├── 接口可用性验证
│   └── 配置完整性检查
├── L3: 系统级监控 (autocheckall.sh)
│   ├── 服务间依赖检查
│   ├── 全局状态汇总
│   └── 系统资源监控
└── L4: 业务级监控 (自定义扩展)
    ├── 设备连接状态
    ├── 自动化规则执行
    └── 用户体验指标
```

### 4.2 MQTT消息总线设计
```
MQTT主题层级结构:
isg/
├── system/                    # 系统级消息
│   ├── runit/status          # Runit进程管理器状态
│   ├── isgservicemonitor/    # 服务监控器状态
│   ├── updates/              # 系统更新信息
│   ├── failures/             # 系统故障事件
│   └── resources/            # 系统资源使用
├── install/                   # 安装相关消息
│   ├── {service}/status      # 服务安装状态
│   └── {service}/progress    # 安装进度信息
├── run/                      # 运行控制消息
│   ├── {service}/status      # 服务启停状态
│   └── {service}/command     # 服务控制命令
├── status/                   # 状态查询消息
│   ├── {service}/status      # 服务运行状态
│   ├── {service}/performance # 性能监控数据
│   └── versions              # 全服务版本信息
├── backup/                   # 备份相关消息
│   └── {service}/status      # 备份操作状态
├── restore/                  # 还原相关消息
│   └── {service}/status      # 还原操作状态
├── update/                   # 更新相关消息
│   └── {service}/status      # 更新操作状态
└── autocheck/                # 自检相关消息
    ├── {service}/status      # 综合健康状态
    ├── {service}/performance # 性能监控数据
    └── {service}/version     # 版本信息
```

### 4.3 告警策略配置
```yaml
# 告警配置
alerting:
  rules:
    - name: "service_down"
      condition: "service.status == 'stopped' for > 5m"
      severity: "critical"
      actions: ["mqtt_alert", "log_alert", "auto_restart"]
      
    - name: "high_cpu_usage" 
      condition: "service.cpu > 80% for > 10m"
      severity: "warning"
      actions: ["mqtt_alert", "log_alert"]
      
    - name: "memory_leak"
      condition: "service.memory > 90% for > 15m"
      severity: "critical"
      actions: ["mqtt_alert", "service_restart"]
      
    - name: "disk_space_low"
      condition: "system.disk_usage > 90%"
      severity: "warning"
      actions: ["mqtt_alert", "cleanup_logs"]
      
    - name: "update_available"
      condition: "service.current_version != service.latest_version"
      severity: "info"
      actions: ["mqtt_notification"]

  channels:
    mqtt_alert:
      topic: "isg/alerts/critical"
      format: "json"
      
    log_alert:
      file: "/data/data/com.termux/files/home/servicemanager/logs/alerts.log"
      format: "structured"
      
    mqtt_notification:
      topic: "isg/notifications/info"
      format: "json"
```

## 5. 数据流与通信协议

### 5.1 内部通信流程
```mermaid
sequenceDiagram
    participant AC as autocheckall.sh
    participant ISG as isgservicemonitor
    participant SVC as Service Scripts
    participant MQTT as MQTT Broker
    participant CFG as Configuration
    
    AC->>ISG: 检查监控器状态
    ISG-->>AC: 返回运行状态
    
    AC->>SVC: 执行autocheck.sh
    SVC->>CFG: 读取配置信息
    CFG-->>SVC: 返回配置数据
    
    SVC->>SVC: 执行健康检查
    SVC->>MQTT: 上报状态信息
    SVC-->>AC: 返回检查结果
    
    AC->>AC: 汇总所有状态
    AC->>MQTT: 上报系统级状态
    
    Note over MQTT: 外部系统可订阅状态消息
```

### 5.2 配置热更新机制
```bash
# 配置热更新监控
watch_config_changes() {
    local config_file="$1"
    local last_mtime=$(stat -c %Y "$config_file")
    
    while true; do
        local current_mtime=$(stat -c %Y "$config_file")
        
        if [ "$current_mtime" -gt "$last_mtime" ]; then
            log "Configuration file changed, reloading..."
            
            # 验证配置文件格式
            if validate_config_format "$config_file"; then
                reload_configuration "$config_file"
                notify_services_config_change
                last_mtime="$current_mtime"
            else
                log "Invalid configuration format, ignoring changes"
            fi
        fi
        
        sleep 30
    done
}

# 通知服务配置变更
notify_services_config_change() {
    mqtt_report "isg/system/config_reload" "{\"timestamp\":$(date +%s),\"source\":\"$config_file\"}"
    
    # 触发各服务重新加载配置
    for service_dir in "$SERVICEMANAGER_DIR"/*/; do
        if [ -f "$service_dir/reload_config.sh" ]; then
            bash "$service_dir/reload_config.sh" &
        fi
    done
}
```

## 6. 安全与权限管理

### 6.1 权限分离设计
```bash
# 权限级别定义
PERMISSION_LEVELS=(
    "system"      # 系统级操作权限
    "service"     # 服务管理权限
    "monitor"     # 监控查看权限
    "user"        # 普通用户权限
)

# 操作权限检查
check_operation_permission() {
    local operation="$1"
    local required_level="$2"
    local current_user=$(whoami)
    
    case "$operation" in
        "install"|"uninstall"|"system_config")
            required_level="system"
            ;;
        "start"|"stop"|"update"|"backup"|"restore")
            required_level="service"
            ;;
        "status"|"autocheck")
            required_level="monitor"
            ;;
    esac
    
    if ! has_permission "$current_user" "$required_level"; then
        log "Permission denied: $operation requires $required_level level"
        return 1
    fi
}
```

### 6.2 安全配置
```yaml
# 安全配置
security:
  authentication:
    enable_auth: false           # 是否启用认证
    auth_method: "token"         # 认证方式: token, password, cert
    token_file: "/data/data/com.termux/files/home/.isg_token"
    session_timeout: 3600        # 会话超时时间(秒)
    
  encryption:
    mqtt_tls: false             # MQTT传输加密
    config_encryption: false    # 配置文件加密
    log_encryption: false       # 日志文件加密
    
  access_control:
    allowed_operations:
      monitor: ["status", "autocheck", "version"]
      service: ["start", "stop", "restart", "backup", "restore"]
      admin: ["install", "uninstall", "update", "config"]
      
  audit:
    enable_audit_log: true      # 启用操作审计
    audit_log_file: "/data/data/com.termux/files/home/servicemanager/logs/audit.log"
    audit_retention_days: 30    # 审计日志保留天数
```

## 7. 扩展机制与插件架构

### 7.1 服务插件接口
```bash
# 服务插件标准接口
SERVICE_PLUGIN_INTERFACE=(
    "install.sh"      # 安装脚本(必需)
    "uninstall.sh"    # 卸载脚本(必需)
    "start.sh"        # 启动脚本(必需)
    "stop.sh"         # 停止脚本(必需)
    "status.sh"       # 状态脚本(必需)
    "autocheck.sh"    # 自检脚本(必需)
    "update.sh"       # 更新脚本(可选)
    "backup.sh"       # 备份脚本(可选)
    "restore.sh"      # 还原脚本(可选)
    "common_paths.sh" # 路径定义(推荐)
    "VERSION"         # 版本文件(推荐)
)

# 插件注册机制
register_service_plugin() {
    local plugin_name="$1"
    local plugin_path="$2"
    
    # 验证插件接口完整性
    validate_plugin_interface "$plugin_path"
    
    # 创建服务目录
    local service_dir="$SERVICEMANAGER_DIR/$plugin_name"
    mkdir -p "$service_dir"
    
    # 安装插件文件
    cp -r "$plugin_path"/* "$service_dir/"
    
    # 设置执行权限
    chmod +x "$service_dir"/*.sh
    
    # 注册到配置文件
    register_service_config "$plugin_name"
    
    # 更新服务元数据
    update_service_metadata_entry "$plugin_name"
}
```

### 7.2 钩子(Hook)机制
```bash
# 钩子函数支持
HOOK_POINTS=(
    "pre_install"     # 安装前钩子
    "post_install"    # 安装后钩子
    "pre_start"       # 启动前钩子
    "post_start"      # 启动后钩子
    "pre_stop"        # 停止前钩子
    "post_stop"       # 停止后钩子
    "pre_update"      # 更新前钩子
    "post_update"     # 更新后钩子
    "on_failure"      # 故障时钩子
    "on_recovery"     # 恢复时钩子
)

# 执行钩子函数
execute_hooks() {
    local hook_point="$1"
    local service_id="$2"
    local context="$3"
    
    # 系统级钩子
    if [ -f "$SERVICEMANAGER_DIR/hooks/${hook_point}.sh" ]; then
        bash "$SERVICEMANAGER_DIR/hooks/${hook_point}.sh" "$service_id" "$context"
    fi
    
    # 服务级钩子
    if [ -f "$SERVICEMANAGER_DIR/$service_id/hooks/${hook_point}.sh" ]; then
        bash "$SERVICEMANAGER_DIR/$service_id/hooks/${hook_point}.sh" "$context"
    fi
    
    # 用户自定义钩子
    if [ -f "$SERVICEMANAGER_DIR/custom_hooks/${hook_point}_${service_id}.sh" ]; then
        bash "$SERVICEMANAGER_DIR/custom_hooks/${hook_point}_${service_id}.sh" "$context"
    fi
}
```

## 8. 性能优化与资源管理

### 8.1 资源限制配置
```yaml
# 资源管理配置
resource_management:
  global_limits:
    max_cpu_percent: 80          # 全局CPU使用限制
    max_memory_mb: 2048          # 全局内存使用限制
    max_disk_usage_percent: 85   # 磁盘使用告警阈值
    max_concurrent_operations: 3  # 并发操作数限制
    
  service_limits:
    hass:
      max_cpu_percent: 50
      max_memory_mb: 1024
      max_disk_mb: 2048
      priority: "high"
      
    zigbee2mqtt:
      max_cpu_percent: 20
      max_memory_mb: 256
      max_disk_mb: 512
      priority: "medium"
      
    node-red:
      max_cpu_percent: 15
      max_memory_mb: 128
      max_disk_mb: 256
      priority: "medium"
      
  optimization:
    enable_resource_monitoring: true
    monitoring_interval: 60      # 监控间隔(秒)
    cleanup_interval: 3600       # 清理间隔(秒)
    log_rotation_size: 10485760  # 日志轮转大小(字节)
    temp_file_cleanup: true      # 自动清理临时文件
```

### 8.2 缓存与优化策略
```bash
# 缓存管理
manage_cache() {
    local action="$1"
    
    case "$action" in
        "init")
            mkdir -p "$CACHE_DIR"/{status,version,config}
            ;;
        "clean")
            find "$CACHE_DIR" -type f -mtime +1 -delete
            ;;
        "status")
            show_cache_statistics
            ;;
    esac
}

# 状态缓存
cache_service_status() {
    local service_id="$1"
    local status_data="$2"
    local cache_file="$CACHE_DIR/status/${service_id}.json"
    
    echo "$status_data" > "$cache_file"
    echo "$(date +%s)" > "${cache_file}.timestamp"
}

# 缓存有效性检查
is_cache_valid() {
    local cache_file="$1"
    local max_age="${2:-300}"  # 默认5分钟有效期
    
    if [ -f "${cache_file}.timestamp" ]; then
        local cache_time=$(cat "${cache_file}.timestamp")
        local current_time=$(date +%s)
        local age=$((current_time - cache_time))
        
        [ "$age" -le "$max_age" ]
    else
        return 1
    fi
}
```

## 9. 故障恢复与备份策略

### 9.1 多级备份策略
```
备份层级:
├── L1: 配置文件备份
│   ├── 每日自动备份
│   ├── 变更时增量备份
│   └── 保留30天历史
├── L2: 服务数据备份
│   ├── 每周完整备份
│   ├── 关键变更实时备份
│   └── 保留12周历史
├── L3: 系统状态备份
│   ├── 每月系统快照
│   ├── 升级前自动备份
│   └── 保留6个月历史
└── L4: 灾难恢复备份
    ├── 异地存储
    ├── 加密保护
    └── 年度验证测试
```

### 9.2 自动恢复机制
```bash
# 自动恢复策略
auto_recovery_strategy() {
    local service_id="$1"
    local failure_type="$2"
    local recovery_attempts="$3"
    
    case "$failure_type" in
        "process_crash")
            if [ "$recovery_attempts" -lt 3 ]; then
                simple_restart_recovery "$service_id"
            else
                full_reinstall_recovery "$service_id"
            fi
            ;;
        "config_corruption")
            restore_from_backup "$service_id"
            ;;
        "dependency_failure")
            reinstall_dependencies "$service_id"
            ;;
        "resource_exhaustion")
            resource_cleanup_recovery "$service_id"
            ;;
        *)
            escalate_to_manual_intervention "$service_id" "$failure_type"
            ;;
    esac
}

# 分级恢复机制
tiered_recovery() {
    local service_id="$1"
    
    # Level 1: 简单重启
    if attempt_simple_restart "$service_id"; then
        return 0
    fi
    
    # Level 2: 配置重置
    if attempt_config_reset "$service_id"; then
        return 0
    fi
    
    # Level 3: 服务重装
    if attempt_service_reinstall "$service_id"; then
        return 0
    fi
    
    # Level 4: 系统级干预
    request_manual_intervention "$service_id"
    return 1
}
```

## 10. 文档与运维指南

### 10.1 目录结构总览
```
/data/data/com.termux/files/home/servicemanager/
├── autocheckall.sh                    # 全局监控调度器
├── configuration.yaml                 # 全局配置文件
├── serviceupdate.sh                   # 服务更新管理器
├── serviceupdate.json                 # 服务版本信息库
├── requirements.yaml                  # 依赖管理配置
├── logs/                              # 系统日志目录
│   ├── autocheckall.log              # 全局监控日志
│   ├── serviceupdate.log             # 更新管理日志
│   ├── system.log                    # 系统运行日志
│   └── audit.log                     # 操作审计日志
├── cache/                             # 缓存目录
│   ├── status/                       # 状态缓存
│   ├── version/                      # 版本缓存
│   └── config/                       # 配置缓存
├── hooks/                             # 系统级钩子脚本
├── custom_hooks/                      # 用户自定义钩子
├── templates/                         # 配置模板
└── services/                          # 服务目录
    ├── hass/                         # Home Assistant服务
    │   ├── install.sh
    │   ├── start.sh
    │   ├── stop.sh
    │   ├── status.sh
    │   ├── autocheck.sh
    │   ├── update.sh
    │   ├── backup.sh
    │   ├── restore.sh
    │   ├── uninstall.sh
    │   ├── common_paths.sh
    │   ├── VERSION
    │   └── logs/
    ├── zigbee2mqtt/                  # Zigbee2MQTT服务
    │   └── [相同结构]
    ├── node-red/                     # Node-RED服务
    │   └── [相同结构]
    ├── mysqld/                       # MySQL服务
    │   └── [相同结构]
    └── sshd/                         # SSH服务
        └── [相同结构]
```

### 10.2 运维操作手册
```bash
# 常用运维命令
# 1. 系统级操作
./autocheckall.sh                     # 执行全系统检查
./serviceupdate.sh check              # 检查所有服务更新
./serviceupdate.sh update hass        # 更新指定服务
./serviceupdate.sh upgrade            # 升级所有服务

# 2. 服务级操作
cd hass && ./install.sh               # 安装Home Assistant
cd hass && ./start.sh                 # 启动Home Assistant
cd hass && ./stop.sh                  # 停止Home Assistant
cd hass && ./status.sh                # 查看服务状态
cd hass && ./autocheck.sh             # 执行服务自检
cd hass && ./backup.sh                # 备份服务数据
cd hass && ./restore.sh               # 还原服务数据

# 3. 监控和诊断
tail -f logs/autocheckall.log         # 查看系统监控日志
grep ERROR logs/*.log                 # 查找错误信息
find . -name "*.log" -mtime -1        # 查找最近日志文件

# 4. 故障排查
# 检查系统资源
free -h && df -h
# 检查进程状态
ps aux | grep -E "(hass|zigbee2mqtt|node-red)"
# 检查服务监控
sv status /data/data/com.termux/files/usr/var/service/*

# 5. 配置管理
# 编辑全局配置
nano configuration.yaml
# 验证配置文件
yq eval . configuration.yaml
# 重新加载配置
kill -HUP $(pgrep autocheckall)
```

## 11. 总结与展望

### 11.1 系统优势
- **统一管理**: 所有IoT服务通过统一接口管理，降低运维复杂度
- **高可用性**: 多层监控和自动恢复机制，确保服务稳定运行
- **可扩展性**: 标准化插件接口，支持新服务快速集成
- **可观测性**: 完整的日志、监控、告警体系，实现全链路追踪
- **安全性**: 分层权限控制和审计机制，保障系统安全

### 11.2 未来规划
- **容器化升级**: 从proot迁移到Docker容器，提升隔离性和便携性
- **集群支持**: 支持多节点部署和负载均衡
- **AI运维**: 集成机器学习算法，实现智能故障预测和自动优化
- **Web管理界面**: 开发可视化管理控制台，提升用户体验
- **云端集成**: 支持云端配置同步和远程管理能力

这个整体服务管理系统为LinknLink IoT平台提供了完整的企业级服务管理能力，通过标准化、自动化、智能化的设计，实现了高效、可靠、安全的IoT服务运维体系。

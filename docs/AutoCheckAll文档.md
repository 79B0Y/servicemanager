# AutoCheckAll 系统全局自检脚本设计文档

**脚本名称**: `autocheckall.sh`  
**版本**: v2.0.0  
**最后更新**: 2025-07-22  
**维护者**: LinknLink 技术团队

## 1. 功能概述

`autocheckall.sh` 是服务管理系统的全局自检脚本，负责：
- 检查系统基础服务状态（runsvdir、isgservicemonitor）
- 根据 `serviceupdate.json` 动态发现并检查所有已配置的服务
- 汇总生成系统整体健康状况报告
- 通过 MQTT 上报详细的系统监控数据
- 维护服务运行历史和性能统计

## 2. 核心职责

### 2.1 系统基础服务检查
| 组件 | 检查项目 | 状态定义 |
|------|---------|---------|
| **runsvdir** | 进程存在性 | `running`, `stopped`, `assumed_by_isgservicemonitor` |
| **isgservicemonitor** | 服务状态 | `running`, `starting`, `failed`, `not_installed` |
| **服务目录** | run 文件权限 | `valid`, `invalid` |
| **runsv 监管** | 各服务监管状态 | `run`, `down`, `invalid` |

### 2.2 动态服务发现
```bash
# 基于 serviceupdate.json 获取服务列表
jq -r '.services[] | select(.enabled == true) | .id' serviceupdate.json
```

支持的服务类型：
- `hass` - Home Assistant Core
- `node-red` - Node-RED 流程编程
- `zwave-js-ui` - Z-Wave 设备管理
- `mosquitto` - MQTT 消息代理
- `zigbee2mqtt` - Zigbee 设备桥接

### 2.3 汇总报告生成
生成包含以下信息的系统状态报告：
- 系统基础服务健康度
- 各个业务服务运行状态
- 版本信息统计
- 性能指标汇总
- 异常服务列表
- 需要更新的服务

## 3. MQTT 上报主题结构

### 3.1 系统级上报
| 主题 | 功能 | 内容示例 |
|------|------|---------|
| `isg/system/runit/status` | runsvdir 状态 | `{"runsvdir": "running"}` |
| `isg/system/runit/service_dir` | 服务目录验证 | `{"valid": true, "missing_services": []}` |
| `isg/system/runit/supervision` | runsv 监管状态 | `{"isgservicemonitor": "run", "sshd": "down"}` |
| `isg/system/isgservicemonitor/status` | 服务监控器状态 | `{"status": "running", "pid": 1234, "uptime": "2h30m"}` |

### 3.2 全局汇总上报
| 主题 | 功能 | 内容 |
|------|------|------|
| `isg/system/health` | 整体健康状况 | 系统级健康评分和关键指标 |
| `isg/system/services/summary` | 服务状态汇总 | 各服务运行状态统计 |
| `isg/system/versions` | 版本信息汇总 | 所有服务的版本信息 |
| `isg/system/performance` | 性能指标汇总 | CPU、内存、网络等系统性能 |
| `isg/system/alerts` | 系统告警 | 异常服务和需要关注的问题 |

### 3.3 汇总报告数据结构
```json
{
  "timestamp": "2025-07-22T10:30:00Z",
  "system_health": {
    "overall_score": 95,
    "status": "healthy",
    "issues": []
  },
  "infrastructure": {
    "runsvdir": "running",
    "isgservicemonitor": "running",
    "service_directory": "valid"
  },
  "services": {
    "total": 5,
    "running": 4,
    "stopped": 1,
    "failed": 0,
    "services_status": {
      "hass": {"status": "running", "health": "good"},
      "mosquitto": {"status": "running", "health": "good"},
      "zwave-js-ui": {"status": "stopped", "health": "warning"},
      "node-red": {"status": "running", "health": "good"},
      "zigbee2mqtt": {"status": "disabled", "health": "n/a"}
    }
  },
  "versions": {
    "services": {
      "hass": {"current": "2025.7.1", "latest": "2025.7.1", "outdated": false},
      "mosquitto": {"current": "2.0.18", "latest": "2.0.18", "outdated": false}
    },
    "scripts": {
      "hass": {"current": "1.3.2", "latest": "1.4.0", "outdated": true}
    }
  },
  "performance": {
    "cpu_usage": "15.2%",
    "memory_usage": "68.5%",
    "disk_usage": "45.1%",
    "services_resource_usage": {
      "hass": {"cpu": "8.5%", "memory": "256MB"},
      "mosquitto": {"cpu": "0.1%", "memory": "12MB"}
    }
  },
  "alerts": {
    "critical": [],
    "warnings": [
      {"service": "zwave-js-ui", "issue": "service_stopped", "message": "Z-Wave JS UI service is not running"}
    ],
    "updates_available": [
      {"service": "hass", "type": "script", "current": "1.3.2", "latest": "1.4.0"}
    ]
  }
}
```

## 4. 文件结构和路径

### 4.1 核心配置文件
```bash
SERVICEMANAGER_DIR="/data/data/com.termux/files/home/servicemanager"
CONFIG_FILE="$SERVICEMANAGER_DIR/configuration.yaml"
SERVICEUPDATE_FILE="$SERVICEMANAGER_DIR/serviceupdate.json"
```

### 4.2 锁文件和状态文件
```bash
LOCK_FILE="/data/data/com.termux/files/usr/var/lock/autocheckall.lock"
STATUS_FILE="/data/data/com.termux/files/usr/var/lib/autocheckall_status.json"
HISTORY_FILE="/data/data/com.termux/files/usr/var/lib/autocheckall_history.json"
```

### 4.3 日志文件
```bash
LOG_DIR="$SERVICEMANAGER_DIR/logs"
LOG_FILE="$LOG_DIR/autocheckall.log"
```

### 4.4 runit 服务目录
```bash
SERVICE_DIR="/data/data/com.termux/files/usr/var/service"
```

## 5. 执行流程

### 5.1 初始化检查
1. **获取文件锁**: 防止多个实例同时运行
2. **加载配置**: 读取 MQTT 和全局配置
3. **验证环境**: 检查必要目录和文件权限

### 5.2 基础设施检查
1. **runsvdir 状态检查**
   ```bash
   if ! pgrep -f runsvdir >/dev/null; then
       # 尝试启动或检查 isgservicemonitor 接管
   fi
   ```

2. **服务目录验证**
   ```bash
   for d in "$SERVICE_DIR"/*; do
       [ -d "$d" ] && [ ! -x "$d/run" ] && chmod +x "$d/run"
   done
   ```

3. **isgservicemonitor 健康检查**
   ```bash
   if ! pgrep -f "com.termux.*isgservicemonitor" >/dev/null; then
       # 尝试启动并重新安装（如果需要）
   fi
   ```

### 5.3 动态服务发现和检查
1. **服务列表获取**
   ```bash
   services=$(jq -r '.services[] | select(.enabled == true) | .id' "$SERVICEUPDATE_FILE")
   ```

2. **并行服务检查**
   ```bash
   for service_id in $services; do
       service_dir="$SERVICEMANAGER_DIR/$service_id"
       if [ -f "$service_dir/autocheck.sh" ]; then
           bash "$service_dir/autocheck.sh" &
       fi
   done
   wait  # 等待所有并行检查完成
   ```

3. **版本信息收集**
   ```bash
   for service_id in $services; do
       version_file="$SERVICEMANAGER_DIR/$service_id/VERSION"
       [ -f "$version_file" ] && versions["$service_id"]=$(cat "$version_file")
   done
   ```

### 5.4 汇总报告生成
1. **健康评分计算**
   - 基础设施权重: 40%
   - 服务运行状态权重: 40%
   - 版本更新状态权重: 20%

2. **性能数据收集**
   - 系统 CPU、内存使用率
   - 各服务资源消耗统计
   - 网络连接状态

3. **告警信息整理**
   - 停止的关键服务
   - 失败的服务启动
   - 过期的版本信息
   - 资源使用过高

### 5.5 MQTT 数据上报
1. **分类上报**: 按主题分别上报不同类型的信息
2. **汇总上报**: 发送完整的系统状态报告
3. **历史记录**: 保存检查历史和趋势分析

## 6. 错误处理和恢复

### 6.1 自动恢复机制
- **runsvdir 自动启动**: 检测到停止时自动重启
- **isgservicemonitor 重装**: 检测到缺失时自动下载安装
- **服务权限修复**: 自动修复 run 文件权限问题

### 6.2 告警升级
- **立即告警**: 基础设施服务失败
- **延迟告警**: 业务服务异常（避免误报）
- **趋势告警**: 性能指标持续恶化

### 6.3 故障记录
```json
{
  "timestamp": "2025-07-22T10:30:00Z",
  "incident_id": "autocheckall_001",
  "severity": "warning",
  "component": "isgservicemonitor",
  "issue": "service_startup_failed",
  "recovery_action": "reinstall_attempted",
  "resolution": "success"
}
```

## 7. 性能优化

### 7.1 并行执行
- 各服务的 autocheck.sh 并行执行
- 使用 `wait` 确保所有检查完成
- 设置合理的超时机制

### 7.2 缓存机制
- 版本信息缓存 5 分钟
- 性能数据采样优化
- MQTT 连接复用

### 7.3 资源控制
- 限制并发检查数量
- 设置内存使用上限
- 控制日志文件大小

## 8. 配置参数

### 8.1 环境变量
| 变量名 | 默认值 | 说明 |
|--------|--------|------|
| `SERVICEMANAGER_DIR` | `/data/data/com.termux/files/home/servicemanager` | 服务管理根目录 |
| `SKIP_SERVICES` | `""` | 跳过检查的服务列表（逗号分隔） |
| `CHECK_TIMEOUT` | `30` | 单个服务检查超时时间（秒） |
| `MQTT_TIMEOUT` | `10` | MQTT 发布超时时间（秒） |
| `PARALLEL_LIMIT` | `5` | 最大并行检查数量 |

### 8.2 配置文件参数
```yaml
global:
  log_level: "INFO"
  check_interval: 300  # 自检间隔（秒）
  history_retention: 30  # 历史记录保留天数
  performance_sampling: 60  # 性能采样间隔（秒）
  alert_thresholds:
    cpu_warning: 80
    memory_warning: 85
    disk_warning: 90
```

## 9. 监控和告警

### 9.1 健康度评分
- **优秀 (90-100)**: 所有服务正常运行，无更新需求
- **良好 (80-89)**: 大部分服务正常，有少量更新需求
- **警告 (70-79)**: 部分服务异常或性能问题
- **危险 (60-69)**: 多个关键服务异常
- **故障 (<60)**: 基础设施或大量服务失败

### 9.2 告警策略
- **即时告警**: 基础设施服务失败
- **聚合告警**: 5分钟内的异常汇总上报
- **趋势告警**: 30分钟性能趋势分析

### 9.3 恢复验证
```bash
# 检查恢复动作是否成功
verify_recovery() {
    local component="$1"
    local action="$2"
    
    case "$component" in
        "isgservicemonitor")
            pgrep -f "com.termux.*isgservicemonitor" >/dev/null
            ;;
        "runsvdir")
            pgrep -f runsvdir >/dev/null
            ;;
    esac
}
```

## 10. 维护和扩展

### 10.1 新服务接入
1. 在 `serviceupdate.json` 中添加服务定义
2. 确保服务目录包含标准的 `autocheck.sh`
3. 无需修改 `autocheckall.sh` 脚本

### 10.2 自定义检查
```bash
# 支持自定义检查钩子
CUSTOM_CHECKS_DIR="$SERVICEMANAGER_DIR/custom_checks"
if [ -d "$CUSTOM_CHECKS_DIR" ]; then
    for check_script in "$CUSTOM_CHECKS_DIR"/*.sh; do
        [ -f "$check_script" ] && bash "$check_script"
    done
fi
```

### 10.3 插件化扩展
- 支持检查插件动态加载
- 自定义 MQTT 主题和格式
- 可扩展的告警通道（除 MQTT 外的通知方式）

---

**注意事项**:
1. 脚本必须具有适当的文件锁机制，避免重复执行
2. 所有 MQTT 上报应包含时间戳和版本信息
3. 错误处理应该优雅，避免级联失败
4. 性能数据采集不应影响系统正常运行
5. 历史数据应定期清理，避免存储空间问题

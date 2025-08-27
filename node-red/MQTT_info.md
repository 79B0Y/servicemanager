# Node-RED 服务管理系统 - MQTT 消息上报列表

## 1. 安装相关消息 (install.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/install/node-red/status` | `installing` | `{"status":"installing","message":"starting installation process","timestamp":1234567890}` | 开始安装 |
| `isg/install/node-red/status` | `installing` | `{"status":"installing","message":"reading service dependencies from serviceupdate.json","timestamp":1234567890}` | 读取服务依赖 |
| `isg/install/node-red/status` | `installing` | `{"status":"installing","message":"installing required dependencies","dependencies":["nodejs","npm"],"timestamp":1234567890}` | 安装依赖包 |
| `isg/install/node-red/status` | `installing` | `{"status":"installing","message":"installing system dependencies","timestamp":1234567890}` | 安装系统依赖 |
| `isg/install/node-red/status` | `installing` | `{"status":"installing","message":"checking node.js and npm versions","timestamp":1234567890}` | 检查环境版本 |
| `isg/install/node-red/status` | `installing` | `{"status":"installing","message":"installing pnpm package manager","timestamp":1234567890}` | 安装pnpm |
| `isg/install/node-red/status` | `installing` | `{"status":"installing","message":"installing node-red application","timestamp":1234567890}` | 安装Node-RED |
| `isg/install/node-red/status` | `installing` | `{"status":"installing","message":"generating package.json","timestamp":1234567890}` | 生成package.json |
| `isg/install/node-red/status` | `installing` | `{"status":"installing","message":"creating data directory","timestamp":1234567890}` | 创建数据目录 |
| `isg/install/node-red/status` | `installing` | `{"status":"installing","message":"registering service monitor","timestamp":1234567890}` | 注册服务监控 |
| `isg/install/node-red/status` | `installing` | `{"status":"installing","message":"starting service for testing","timestamp":1234567890}` | 启动服务测试 |
| `isg/install/node-red/status` | `installing` | `{"status":"installing","message":"waiting for service ready","timestamp":1234567890}` | 等待服务就绪 |
| `isg/install/node-red/status` | `installing` | `{"status":"installing","message":"recording installation history","version":"4.0.9","timestamp":1234567890}` | 记录安装历史 |
| `isg/install/node-red/status` | `installed` | `{"service":"node-red","status":"installed","version":"4.0.9","duration":180,"timestamp":1234567890}` | 安装成功 |
| `isg/install/node-red/status` | `failed` | `{"status":"failed","message":"dependency installation failed","dependencies":["nodejs","npm"],"timestamp":1234567890}` | 依赖安装失败 |
| `isg/install/node-red/status` | `failed` | `{"status":"failed","message":"node.js or npm not properly installed","timestamp":1234567890}` | 环境检查失败 |
| `isg/install/node-red/status` | `failed` | `{"status":"failed","message":"service start timeout after installation","timeout":300,"timestamp":1234567890}` | 安装后启动超时 |

## 2. 卸载相关消息 (uninstall.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/install/node-red/status` | `uninstalling` | `{"status":"uninstalling","message":"starting uninstall process","timestamp":1234567890}` | 开始卸载 |
| `isg/install/node-red/status` | `uninstalling` | `{"status":"uninstalling","message":"stopping service","timestamp":1234567890}` | 停止服务 |
| `isg/install/node-red/status` | `uninstalling` | `{"status":"uninstalling","message":"removing installation directory","timestamp":1234567890}` | 删除安装目录 |
| `isg/install/node-red/status` | `uninstalled` | `{"status":"uninstalled","message":"node-red completely removed","timestamp":1234567890}` | 卸载完成 |

## 3. 启动相关消息 (start.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/run/node-red/status` | `starting` | `{"service":"node-red","status":"starting","message":"starting service","timestamp":1234567890}` | 开始启动 |
| `isg/run/node-red/status` | `starting` | `{"service":"node-red","status":"starting","message":"removed down file to enable auto-start","timestamp":1234567890}` | 移除down文件 |
| `isg/run/node-red/status` | `starting` | `{"service":"node-red","status":"starting","message":"waiting for service ready","timestamp":1234567890}` | 等待服务就绪 |
| `isg/run/node-red/status` | `success` | `{"service":"node-red","status":"success","message":"service started successfully","timestamp":1234567890}` | 启动成功 |
| `isg/run/node-red/status` | `failed` | `{"service":"node-red","status":"failed","message":"supervise control file not found","timestamp":1234567890}` | 控制文件不存在 |
| `isg/run/node-red/status` | `failed` | `{"service":"node-red","status":"failed","message":"service failed to reach running state","timeout":150,"timestamp":1234567890}` | 启动超时 |

## 4. 停止相关消息 (stop.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/run/node-red/status` | `stopping` | `{"service":"node-red","status":"stopping","message":"stopping service","timestamp":1234567890}` | 开始停止 |
| `isg/run/node-red/status` | `stopping` | `{"service":"node-red","status":"stopping","message":"created down file to disable auto-start","timestamp":1234567890}` | 创建down文件 |
| `isg/run/node-red/status` | `stopping` | `{"service":"node-red","status":"stopping","message":"waiting for service to stop","timestamp":1234567890}` | 等待服务停止 |
| `isg/run/node-red/status` | `success` | `{"service":"node-red","status":"success","message":"service stopped and disabled","timestamp":1234567890}` | 停止成功 |
| `isg/run/node-red/status` | `failed` | `{"service":"node-red","status":"failed","message":"service still running after stop timeout","timeout":150,"timestamp":1234567890}` | 停止失败 |

## 5. 状态查询消息 (status.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/status/node-red/status` | `running` | `{"service":"node-red","status":"running","pid":1234,"runtime":"1:23:45","http_status":"online","port":"1880","timestamp":1234567890}` | 服务运行中 |
| `isg/status/node-red/status` | `starting` | `{"service":"node-red","status":"starting","pid":1234,"runtime":"0:01:30","http_status":"starting","port":"1880","timestamp":1234567890}` | 服务启动中 |
| `isg/status/node-red/status` | `stopped` | `{"service":"node-red","status":"stopped","message":"service not running","timestamp":1234567890}` | 服务已停止 |

## 6. 备份相关消息 (backup.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/backup/node-red/status` | `backuping` | `{"status":"backuping","message":"starting backup process","timestamp":1234567890}` | 开始备份 |
| `isg/backup/node-red/status` | `backuping` | `{"status":"backuping","message":"creating archive","timestamp":1234567890}` | 创建压缩包 |
| `isg/backup/node-red/status` | `skipped` | `{"status":"skipped","message":"service not running - backup skipped","timestamp":1234567890}` | 服务未运行跳过 |
| `isg/backup/node-red/status` | `success` | `{"service":"node-red","status":"success","file":"/sdcard/isgbackup/node-red/backup.tar.gz","size_kb":2048,"duration":45,"message":"backup completed successfully","timestamp":1234567890}` | 备份成功 |
| `isg/backup/node-red/status` | `failed` | `{"status":"failed","message":"tar command failed inside container","timestamp":1234567890}` | 备份失败 |

## 7. 还原相关消息 (restore.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/restore/node-red/status` | `restoring` | `{"status":"restoring","method":"latest_backup","file":"node-red_backup_20250715.tar.gz"}` | 使用最新备份文件还原 |
| `isg/restore/node-red/status` | `restoring` | `{"status":"restoring","method":"user_specified","file":"/sdcard/Download/my_backup.tar.gz"}` | 用户指定tar.gz文件 |
| `isg/restore/node-red/status` | `restoring` | `{"status":"restoring","method":"user_specified","file":"/sdcard/Download/backup.zip","converting_zip":true}` | 用户指定ZIP文件（需转换） |
| `isg/restore/node-red/status` | `restoring` | `{"status":"restoring","method":"default_config","timestamp":1234567890}` | 无备份文件，生成默认配置 |
| `isg/restore/node-red/status` | `success` | `{"service":"node-red","status":"success","method":"latest_backup","file":"node-red_backup_20250715.tar.gz","size_kb":2048,"duration":60,"timestamp":1234567890}` | 最新备份还原成功 |
| `isg/restore/node-red/status` | `success` | `{"service":"node-red","status":"success","method":"user_specified","original_file":"backup.zip","restore_file":"backup.tar.gz","size_kb":2048,"duration":75,"converted_from_zip":true,"timestamp":1234567890}` | 用户指定文件还原成功（含转换） |
| `isg/restore/node-red/status` | `success` | `{"service":"node-red","status":"success","method":"default_config","duration":90,"startup_time":25,"timestamp":1234567890}` | 默认配置生成成功 |
| `isg/restore/node-red/status` | `failed` | `{"status":"failed","message":"user specified file not found","file":"/sdcard/nonexistent.tar.gz","timestamp":1234567890}` | 用户指定文件不存在 |
| `isg/restore/node-red/status` | `failed` | `{"status":"failed","message":"unsupported file format. only .tar.gz and .zip are supported","file":"backup.rar","timestamp":1234567890}` | 不支持的文件格式 |
| `isg/restore/node-red/status` | `failed` | `{"status":"failed","message":"service failed to start after restore","method":"user_specified","timestamp":1234567890}` | 还原后启动失败 |
| `isg/restore/node-red/status` | `failed` | `{"status":"failed","message":"service failed to start after config generation","method":"default_config","timestamp":1234567890}` | 配置生成后启动失败 |

## 8. 更新相关消息 (update.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/update/node-red/status` | `updating` | `{"status":"updating","current_version":"4.0.8","message":"starting update process","timestamp":1234567890}` | 开始更新 |
| `isg/update/node-red/status` | `updating` | `{"status":"updating","current_version":"4.0.8","message":"reading upgrade dependencies from serviceupdate.json","timestamp":1234567890}` | 读取升级依赖 |
| `isg/update/node-red/status` | `updating` | `{"status":"updating","current_version":"4.0.8","message":"installing upgrade dependencies","dependencies":["node-red-contrib-dashboard@3.6.0"],"timestamp":1234567890}` | 安装升级依赖 |
| `isg/update/node-red/status` | `updating` | `{"status":"updating","current_version":"4.0.8","message":"stopping service","timestamp":1234567890}` | 停止服务 |
| `isg/update/node-red/status` | `updating` | `{"status":"updating","current_version":"4.0.8","message":"updating node-red package","timestamp":1234567890}` | 更新Node-RED包 |
| `isg/update/node-red/status` | `updating` | `{"status":"updating","current_version":"4.0.8","message":"updating package.json","timestamp":1234567890}` | 更新package.json |
| `isg/update/node-red/status` | `updating` | `{"status":"updating","current_version":"4.0.8","message":"starting service","timestamp":1234567890}` | 启动服务 |
| `isg/update/node-red/status` | `updating` | `{"status":"updating","current_version":"4.0.8","message":"waiting for service ready","timestamp":1234567890}` | 等待服务就绪 |
| `isg/update/node-red/status` | `updating` | `{"status":"updating","old_version":"4.0.8","new_version":"4.0.9","message":"recording update history","timestamp":1234567890}` | 记录更新历史 |
| `isg/update/node-red/status` | `success` | `{"service":"node-red","status":"success","old_version":"4.0.8","new_version":"4.0.9","duration":210,"timestamp":1234567890}` | 更新成功 |
| `isg/update/node-red/status` | `failed` | `{"status":"failed","message":"upgrade dependencies installation failed","dependencies":["node-red-contrib-dashboard@3.6.0"],"current_version":"4.0.8","timestamp":1234567890}` | 升级依赖安装失败 |
| `isg/update/node-red/status` | `failed` | `{"status":"failed","message":"node-red package update failed","current_version":"4.0.8","timestamp":1234567890}` | Node-RED包更新失败 |
| `isg/update/node-red/status` | `failed` | `{"status":"failed","message":"service start timeout after update","old_version":"4.0.8","new_version":"4.0.9","timeout":300,"timestamp":1234567890}` | 更新后启动超时 |

## 9. 自检相关消息 (autocheck.sh)

### 9.1 自检过程消息

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/autocheck/node-red/status` | `start` | `{"status":"start","run":"unknown","config":{},"install":"checking","current_version":"unknown","latest_version":"unknown","update":"checking","message":"starting autocheck process","timestamp":1234567890}` | 开始自检 |
| `isg/autocheck/node-red/status` | `recovered` | `{"status":"recovered","message":"service recovered after restart attempts","timestamp":1234567890}` | 服务恢复成功 |

### 9.2 综合状态消息 (汇总所有脚本状态)

| 状态场景 | MQTT 消息内容 |
|---------|--------------|
| **服务被禁用** | `{"status":"disabled","run":"disabled","config":{"port":"1880","admin_auth":"none","https_enabled":false,"theme_enabled":false},"install":"success","backup":"success","restore":"success","update":"success","current_version":"4.0.9","latest_version":"4.0.9","update_info":"SUCCESS 2 hours ago (4.0.8 -> 4.0.9)","message":"service is disabled","timestamp":1234567890}` |
| **服务健康运行** | `{"status":"healthy","run":"running","config":{"port":"1880","admin_auth":"none","https_enabled":false,"theme_enabled":false},"install":"success","backup":"success","restore":"success","update":"success","current_version":"4.0.9","latest_version":"4.0.9","update_info":"SUCCESS 2 hours ago (4.0.8 -> 4.0.9)","message":"node-red running for 2 hours","http_status":"online","port":"1880","timestamp":1234567890}` |
| **服务启动中** | `{"status":"healthy","run":"starting","config":{"port":"1880","admin_auth":"none","https_enabled":false,"theme_enabled":false},"install":"success","backup":"success","restore":"success","update":"success","current_version":"4.0.9","latest_version":"4.0.9","update_info":"SUCCESS 2 hours ago (4.0.8 -> 4.0.9)","message":"node-red is starting up","http_status":"starting","port":"1880","timestamp":1234567890}` |
| **安装进行中** | `{"status":"healthy","run":"stopped","config":{},"install":"installing","backup":"success","restore":"success","update":"success","current_version":"unknown","latest_version":"4.0.9","update_info":"SUCCESS 1 day ago (4.0.7 -> 4.0.8)","message":"node-red installation in progress","timestamp":1234567890}` |
| **更新进行中** | `{"status":"healthy","run":"running","config":{"port":"1880","admin_auth":"none","https_enabled":false,"theme_enabled":false},"install":"success","backup":"success","restore":"success","update":"updating","current_version":"4.0.8","latest_version":"4.0.9","update_info":"UPDATING 4.0.8 -> 4.0.9","message":"node-red update in progress","timestamp":1234567890}` |
| **服务启动失败** | `{"status":"problem","run":"failed","config":{"port":"1880","admin_auth":"none","https_enabled":false,"theme_enabled":false},"install":"success","backup":"success","restore":"success","update":"success","current_version":"4.0.9","latest_version":"4.0.9","update_info":"SUCCESS 2 hours ago (4.0.8 -> 4.0.9)","message":"failed to start service after retries","timestamp":1234567890}` |
| **HTTP接口离线问题** | `{"status":"problem","run":"running","config":{"port":"1880","admin_auth":"none","https_enabled":false,"theme_enabled":false},"install":"success","backup":"success","restore":"success","update":"success","current_version":"4.0.9","latest_version":"4.0.9","update_info":"SUCCESS 2 hours ago (4.0.8 -> 4.0.9)","message":"service running but http interface offline","http_status":"starting","port":"1880","timestamp":1234567890}` |

### 9.3 状态字段说明

| 字段名 | 可能值 | 说明 |
|-------|--------|------|
| `status` | `start`, `healthy`, `problem`, `disabled` | 总体健康状态 |
| `run` | `starting`, `stopping`, `running`, `stopped`, `failed`, `disabled` | 运行状态 |
| `config` | JSON对象 或 `{}` | 当前配置信息，服务未安装时为空 |
| `install` | `installing`, `uninstalling`, `success`, `failed` | 安装状态 |
| `backup` | `backuping`, `success`, `failed`, `skipped`, `never` | 最近备份状态 |
| `restore` | `restoring`, `success`, `failed`, `skipped`, `never` | 最近还原状态 |
| `update` | `updating`, `success`, `failed`, `never` | 最近更新状态 |
| `current_version` | 版本号 或 `unknown` | 当前安装的Node-RED版本 |
| `latest_version` | 版本号 或 `unknown` | 最新可用版本 |
| `update_info` | 更新摘要信息 | 最近更新的详细信息 |
| `message` | 描述性文本 | 当前状态的人性化描述 |
| `http_status` | `online`, `starting`, `offline` | HTTP接口状态 |
| `port` | 端口号 | Node-RED运行端口 |

## 10. 性能监控消息 (autocheck.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/autocheck/node-red/performance` | - | `{"cpu":"3.8","mem":"12.5","timestamp":1234567890}` | 性能数据上报 |
| `isg/status/node-red/performance` | - | `{"cpu":"3.8","mem":"12.5","timestamp":1234567890}` | 状态性能数据 |

## 11. 版本信息消息 (autocheck.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/autocheck/node-red/version` | - | `{"script_version":"1.0.0","latest_script_version":"1.0.0","nr_version":"4.0.9","latest_nr_version":"4.0.9","upgrade_dependencies":["node-red-contrib-dashboard@3.6.0"]}` | 版本信息上报 |

## 📋 消息总结统计

- **总主题数**: 4个基础主题 (install, run, status, backup, restore, update, autocheck)
- **标准状态值**: 4种核心状态 (installing/starting/restoring/updating, success, failed, skipped)
- **总消息类型数**: 约40种不同消息
- **特殊主题**: performance, version 子主题
- **Node-RED特色**: http_status, port 字段用于HTTP接口监控

## 🎯 状态值标准化

所有操作遵循统一的状态模式：
- **进行中**: `installing` / `starting` / `stopping` / `restoring` / `updating` / `backuping`
- **成功**: `success` / `running` / `stopped` / `healthy`
- **失败**: `failed` / `problem`  
- **跳过**: `skipped` / `disabled`

## 🔍 Node-RED 服务特点

### 与 Zigbee2MQTT 的主要差异

1. **端口监控**: 使用HTTP端口1880而非MQTT桥接状态
2. **配置结构**: 监控settings.js配置文件而非configuration.yaml
3. **数据目录**: 备份/还原~/.node-red用户数据目录
4. **包管理**: 使用npm/pnpm进行包管理和版本升级
5. **服务验证**: 通过HTTP接口可达性验证服务健康状态

### 监控重点

- **HTTP接口状态**: 通过nc检查1880端口可达性
- **进程工作目录**: 确认进程确实是Node-RED相关
- **用户数据完整性**: flows.json和settings.js文件存在性
- **包版本一致性**: package.json中的版本信息

## 🚀 扩展建议

考虑未来可能需要的监控点：

1. **流程状态**: 监控Node-RED flows的部署状态
2. **节点健康**: 检查关键节点的连接状态
3. **内存使用**: 监控Node.js进程内存泄漏
4. **插件管理**: 跟踪已安装的node-red-contrib-*插件版本

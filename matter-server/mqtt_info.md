# Matter Server 服务管理系统 - MQTT 消息上报列表

## 1. 安装相关消息 (install.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/install/matter-server/status` | `installing` | `{"status":"installing","message":"starting installation process","timestamp":1234567890}` | 开始安装 |
| `isg/install/matter-server/status` | `installing` | `{"status":"installing","message":"reading service dependencies from serviceupdate.json","timestamp":1234567890}` | 读取服务依赖 |
| `isg/install/matter-server/status` | `installing` | `{"status":"installing","message":"installing system dependencies","dependencies":["python3","python3-pip","python3-venv","build-essential","libssl-dev","libffi-dev","python3-dev","git","cmake","ninja-build"],"timestamp":1234567890}` | 安装依赖包 |
| `isg/install/matter-server/status` | `installing` | `{"status":"installing","message":"installing system dependencies in proot container","timestamp":1234567890}` | 安装系统依赖 |
| `isg/install/matter-server/status` | `installing` | `{"status":"installing","message":"checking python and pip versions","timestamp":1234567890}` | 检查环境版本 |
| `isg/install/matter-server/status` | `installing` | `{"status":"installing","message":"creating virtual environment","timestamp":1234567890}` | 创建虚拟环境 |
| `isg/install/matter-server/status` | `installing` | `{"status":"installing","message":"installing python dependencies","timestamp":1234567890}` | 安装Python依赖 |
| `isg/install/matter-server/status` | `installing` | `{"status":"installing","message":"installing python-matter-server","timestamp":1234567890}` | 安装Matter Server |
| `isg/install/matter-server/status` | `installing` | `{"status":"installing","message":"creating configuration files","timestamp":1234567890}` | 创建配置文件 |
| `isg/install/matter-server/status` | `installing` | `{"status":"installing","message":"registering service monitor","timestamp":1234567890}` | 注册服务监控 |
| `isg/install/matter-server/status` | `installing` | `{"status":"installing","message":"starting service for testing","timestamp":1234567890}` | 启动服务测试 |
| `isg/install/matter-server/status` | `installing` | `{"status":"installing","message":"waiting for service ready","timestamp":1234567890}` | 等待服务就绪 |
| `isg/install/matter-server/status` | `installing` | `{"status":"installing","message":"recording installation history","version":"6.6.0","timestamp":1234567890}` | 记录安装历史 |
| `isg/install/matter-server/status` | `installed` | `{"service":"matter-server","status":"installed","version":"6.6.0","duration":180,"timestamp":1234567890}` | 安装成功 |
| `isg/install/matter-server/status` | `failed` | `{"status":"failed","message":"dependency installation failed","dependencies":["python3","python3-pip"],"timestamp":1234567890}` | 依赖安装失败 |
| `isg/install/matter-server/status` | `failed` | `{"status":"failed","message":"python or pip not properly installed","timestamp":1234567890}` | 环境检查失败 |
| `isg/install/matter-server/status` | `failed` | `{"status":"failed","message":"service start timeout after installation","timeout":300,"timestamp":1234567890}` | 安装后启动超时 |

## 2. 卸载相关消息 (uninstall.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/install/matter-server/status` | `uninstalling` | `{"status":"uninstalling","message":"starting uninstall process","timestamp":1234567890}` | 开始卸载 |
| `isg/install/matter-server/status` | `uninstalling` | `{"status":"uninstalling","message":"stopping service","timestamp":1234567890}` | 停止服务 |
| `isg/install/matter-server/status` | `uninstalling` | `{"status":"uninstalling","message":"removing installation directory","timestamp":1234567890}` | 删除安装目录 |
| `isg/install/matter-server/status` | `uninstalled` | `{"status":"uninstalled","message":"matter-server completely removed","timestamp":1234567890}` | 卸载完成 |

## 3. 启动相关消息 (start.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/run/matter-server/status` | `starting` | `{"service":"matter-server","status":"starting","message":"starting service","timestamp":1234567890}` | 开始启动 |
| `isg/run/matter-server/status` | `starting` | `{"service":"matter-server","status":"starting","message":"removed down file to enable auto-start","timestamp":1234567890}` | 移除down文件 |
| `isg/run/matter-server/status` | `starting` | `{"service":"matter-server","status":"starting","message":"waiting for service ready","timestamp":1234567890}` | 等待服务就绪 |
| `isg/run/matter-server/status` | `success` | `{"service":"matter-server","status":"success","message":"service started successfully","timestamp":1234567890}` | 启动成功 |
| `isg/run/matter-server/status` | `failed` | `{"service":"matter-server","status":"failed","message":"supervise control file not found","timestamp":1234567890}` | 控制文件不存在 |
| `isg/run/matter-server/status` | `failed` | `{"service":"matter-server","status":"failed","message":"service failed to reach running state","timeout":150,"timestamp":1234567890}` | 启动超时 |

## 4. 停止相关消息 (stop.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/run/matter-server/status` | `stopping` | `{"service":"matter-server","status":"stopping","message":"stopping service","timestamp":1234567890}` | 开始停止 |
| `isg/run/matter-server/status` | `stopping` | `{"service":"matter-server","status":"stopping","message":"created down file to disable auto-start","timestamp":1234567890}` | 创建down文件 |
| `isg/run/matter-server/status` | `stopping` | `{"service":"matter-server","status":"stopping","message":"waiting for service to stop","timestamp":1234567890}` | 等待服务停止 |
| `isg/run/matter-server/status` | `success` | `{"service":"matter-server","status":"success","message":"service stopped and disabled","timestamp":1234567890}` | 停止成功 |
| `isg/run/matter-server/status` | `failed` | `{"service":"matter-server","status":"failed","message":"service still running after stop timeout","timeout":150,"timestamp":1234567890}` | 停止失败 |

## 5. 状态查询消息 (status.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/status/matter-server/status` | `running` | `{"service":"matter-server","status":"running","pid":1234,"runtime":"1:23:45","http_status":"online","port":"5580","install":true,"version":"6.6.0","timestamp":1234567890}` | 服务运行中 |
| `isg/status/matter-server/status` | `starting` | `{"service":"matter-server","status":"starting","pid":1234,"runtime":"0:01:30","http_status":"starting","port":"5580","install":true,"version":"6.6.0","timestamp":1234567890}` | 服务启动中 |
| `isg/status/matter-server/status` | `stopped` | `{"service":"matter-server","status":"stopped","message":"service not running","install":false,"timestamp":1234567890}` | 服务已停止 |

## 6. 备份相关消息 (backup.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/backup/matter-server/status` | `backuping` | `{"status":"backuping","message":"starting backup process","timestamp":1234567890}` | 开始备份 |
| `isg/backup/matter-server/status` | `backuping` | `{"status":"backuping","message":"collecting backup content","timestamp":1234567890}` | 收集备份内容 |
| `isg/backup/matter-server/status` | `backuping` | `{"status":"backuping","message":"creating archive","timestamp":1234567890}` | 创建压缩包 |
| `isg/backup/matter-server/status` | `skipped` | `{"status":"skipped","message":"service not running - backup skipped","timestamp":1234567890}` | 服务未运行跳过 |
| `isg/backup/matter-server/status` | `success` | `{"service":"matter-server","status":"success","file":"matter-server_backup_20250715.tar.gz","size_kb":2048,"duration":45,"message":"backup completed successfully","timestamp":1234567890}` | 备份成功 |
| `isg/backup/matter-server/status` | `failed` | `{"status":"failed","message":"archive creation failed","timestamp":1234567890}` | 备份失败 |

## 7. 还原相关消息 (restore.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/restore/matter-server/status` | `restoring` | `{"status":"restoring","method":"latest_backup","file":"matter-server_backup_20250715.tar.gz"}` | 使用最新备份文件还原 |
| `isg/restore/matter-server/status` | `restoring` | `{"status":"restoring","method":"user_specified","file":"/sdcard/Download/my_backup.tar.gz"}` | 用户指定tar.gz文件 |
| `isg/restore/matter-server/status` | `restoring` | `{"status":"restoring","method":"user_specified","file":"/sdcard/Download/backup.zip","converting_zip":true}` | 用户指定ZIP文件（需转换） |
| `isg/restore/matter-server/status` | `restoring` | `{"status":"restoring","method":"default_config","timestamp":1234567890}` | 无备份文件，生成默认配置 |
| `isg/restore/matter-server/status` | `success` | `{"service":"matter-server","status":"success","method":"latest_backup","file":"matter-server_backup_20250715.tar.gz","size_kb":2048,"duration":60,"timestamp":1234567890}` | 最新备份还原成功 |
| `isg/restore/matter-server/status` | `success` | `{"service":"matter-server","status":"success","method":"user_specified","original_file":"backup.zip","restore_file":"backup.tar.gz","size_kb":2048,"duration":75,"converted_from_zip":true,"timestamp":1234567890}` | 用户指定文件还原成功（含转换） |
| `isg/restore/matter-server/status` | `success` | `{"service":"matter-server","status":"success","method":"default_config","duration":90,"startup_time":25,"timestamp":1234567890}` | 默认配置生成成功 |
| `isg/restore/matter-server/status` | `failed` | `{"status":"failed","message":"user specified file not found","file":"/sdcard/nonexistent.tar.gz","timestamp":1234567890}` | 用户指定文件不存在 |
| `isg/restore/matter-server/status` | `failed` | `{"status":"failed","message":"unsupported file format. only .tar.gz and .zip are supported","file":"backup.rar","timestamp":1234567890}` | 不支持的文件格式 |
| `isg/restore/matter-server/status` | `failed` | `{"status":"failed","message":"service failed to start after restore","method":"user_specified","timestamp":1234567890}` | 还原后启动失败 |

## 8. 更新相关消息 (update.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/update/matter-server/status` | `updating` | `{"status":"updating","current_version":"6.5.0","message":"stopping service","timestamp":1234567890}` | 停止服务 |
| `isg/update/matter-server/status` | `updating` | `{"status":"updating","current_version":"6.5.0","message":"updating python-matter-server package","timestamp":1234567890}` | 更新Matter Server包 |
| `isg/update/matter-server/status` | `updating` | `{"status":"updating","current_version":"6.5.0","message":"starting service","timestamp":1234567890}` | 启动服务 |
| `isg/update/matter-server/status` | `updating` | `{"status":"updating","current_version":"6.5.0","message":"waiting for service ready","timestamp":1234567890}` | 等待服务就绪 |
| `isg/update/matter-server/status` | `updating` | `{"status":"updating","old_version":"6.5.0","new_version":"6.6.0","message":"recording update history","timestamp":1234567890}` | 记录更新历史 |
| `isg/update/matter-server/status` | `success` | `{"service":"matter-server","status":"success","old_version":"6.5.0","new_version":"6.6.0","duration":210,"timestamp":1234567890}` | 更新成功 |
| `isg/update/matter-server/status` | `failed` | `{"status":"failed","message":"upgrade dependencies installation failed","dependencies":["cryptography>=3.4.8"],"current_version":"6.5.0","timestamp":1234567890}` | 升级依赖安装失败 |
| `isg/update/matter-server/status` | `failed` | `{"status":"failed","message":"python-matter-server package update failed","current_version":"6.5.0","timestamp":1234567890}` | Matter Server包更新失败 |
| `isg/update/matter-server/status` | `failed` | `{"status":"failed","message":"service start timeout after update","old_version":"6.5.0","new_version":"6.6.0","timeout":300,"timestamp":1234567890}` | 更新后启动超时 |

## 9. 自检相关消息 (autocheck.sh)

### 9.1 自检过程消息

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/autocheck/matter-server/status` | `start` | `{"status":"start","run":"unknown","config":{},"install":"checking","current_version":"unknown","latest_version":"unknown","update":"checking","message":"starting autocheck process","timestamp":1234567890}` | 开始自检 |
| `isg/autocheck/matter-server/status` | `recovered` | `{"status":"recovered","message":"service recovered after restart attempts","timestamp":1234567890}` | 服务恢复成功 |

### 9.2 综合状态消息 (汇总所有脚本状态)

| 状态场景 | MQTT 消息内容 |
|---------|--------------|
| **服务被禁用** | `{"status":"disabled","run":"disabled","config":{"port":"5580","host":"0.0.0.0","log_level":"INFO","mqtt_enabled":false},"install":"success","backup":"success","restore":"success","update":"success","current_version":"6.6.0","latest_version":"6.6.0","update_info":"SUCCESS 2 hours ago (6.5.0 -> 6.6.0)","message":"service is disabled","timestamp":1234567890}` |
| **服务健康运行** | `{"status":"healthy","run":"running","config":{"port":"5580","host":"0.0.0.0","log_level":"INFO","mqtt_enabled":false},"install":"success","backup":"success","restore":"success","update":"success","current_version":"6.6.0","latest_version":"6.6.0","update_info":"SUCCESS 2 hours ago (6.5.0 -> 6.6.0)","message":"matter-server running for 2 hours","http_status":"online","port":"5580","timestamp":1234567890}` |
| **服务启动中** | `{"status":"healthy","run":"starting","config":{"port":"5580","host":"0.0.0.0","log_level":"INFO","mqtt_enabled":false},"install":"success","backup":"success","restore":"success","update":"success","current_version":"6.6.0","latest_version":"6.6.0","update_info":"SUCCESS 2 hours ago (6.5.0 -> 6.6.0)","message":"matter-server is starting up","http_status":"starting","port":"5580","timestamp":1234567890}` |
| **安装进行中** | `{"status":"healthy","run":"stopped","config":{},"install":"installing","backup":"success","restore":"success","update":"success","current_version":"unknown","latest_version":"6.6.0","update_info":"SUCCESS 1 day ago (6.4.0 -> 6.5.0)","message":"matter-server installation in progress","timestamp":1234567890}` |
| **更新进行中** | `{"status":"healthy","run":"running","config":{"port":"5580","host":"0.0.0.0","log_level":"INFO","mqtt_enabled":false},"install":"success","backup":"success","restore":"success","update":"updating","current_version":"6.5.0","latest_version":"6.6.0","update_info":"UPDATING 6.5.0 -> 6.6.0","message":"matter-server update in progress","timestamp":1234567890}` |
| **服务启动失败** | `{"status":"problem","run":"failed","config":{"port":"5580","host":"0.0.0.0","log_level":"INFO","mqtt_enabled":false},"install":"success","backup":"success","restore":"success","update":"success","current_version":"6.6.0","latest_version":"6.6.0","update_info":"SUCCESS 2 hours ago (6.5.0 -> 6.6.0)","message":"failed to start service after retries","timestamp":1234567890}` |
| **端口接口离线问题** | `{"status":"problem","run":"running","config":{"port":"5580","host":"0.0.0.0","log_level":"INFO","mqtt_enabled":false},"install":"success","backup":"success","restore":"success","update":"success","current_version":"6.6.0","latest_version":"6.6.0","update_info":"SUCCESS 2 hours ago (6.5.0 -> 6.6.0)","message":"service running but port interface offline","http_status":"starting","port":"5580","timestamp":1234567890}` |

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
| `current_version` | 版本号 或 `unknown` | 当前安装的Matter Server版本 |
| `latest_version` | 版本号 或 `unknown` | 最新可用版本 |
| `update_info` | 更新摘要信息 | 最近更新的详细信息 |
| `message` | 描述性文本 | 当前状态的人性化描述 |
| `http_status` | `online`, `starting`, `offline` | 端口接口状态 |
| `port` | 端口号 | Matter Server运行端口 |

## 10. 性能监控消息 (autocheck.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/autocheck/matter-server/performance` | - | `{"cpu":"3.8","mem":"12.5","timestamp":1234567890}` | 性能数据上报 |
| `isg/status/matter-server/performance` | - | `{"cpu":"3.8","mem":"12.5","timestamp":1234567890}` | 状态性能数据 |

## 11. 版本信息消息 (autocheck.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/autocheck/matter-server/version` | - | `{"script_version":"1.0.0","latest_script_version":"1.0.0","matter_version":"6.6.0","latest_matter_version":"6.6.0","upgrade_dependencies":["cryptography>=3.4.8"]}` | 版本信息上报 |

## 📋 消息总结统计

- **总主题数**: 4个基础主题 (install, run, status, backup, restore, update, autocheck)
- **标准状态值**: 4种核心状态 (installing/starting/restoring/updating, success, failed, skipped)
- **总消息类型数**: 约40种不同消息
- **特殊主题**: performance, version 子主题
- **Matter Server特色**: http_status, port 字段用于端口接口监控

## 🎯 状态值标准化

所有操作遵循统一的状态模式：
- **进行中**: `installing` / `starting` / `stopping` / `restoring` / `updating` / `backuping`
- **成功**: `success` / `running` / `stopped` / `healthy`
- **失败**: `failed` / `problem`  
- **跳过**: `skipped` / `disabled`

## 🔍 Matter Server 服务特点

### 与 Node-RED 的主要差异

1. **端口监控**: 使用Matter协议端口5580而非HTTP Web接口
2. **配置结构**: 监控config.yaml配置文件和matter.json存储文件
3. **数据目录**: 备份/还原/opt/matter-server/data数据目录
4. **包管理**: 使用pip在虚拟环境中进行包管理和版本升级
5. **服务验证**: 通过端口可达性验证服务健康状态

### 监控重点

- **端口状态**: 通过nc检查5580端口可达性
- **进程命令行**: 确认进程确实是matter-server相关
- **数据完整性**: config.yaml和matter.json文件存在性
- **虚拟环境**: Python虚拟环境和Matter Server包版本一致性

## 🚀 扩展建议

考虑未来可能需要的监控点：

1. **Matter设备状态**: 监控已配对的Matter设备连接状态
2. **网络状态**: 检查Matter网络的健康状况
3. **证书管理**: 监控Matter证书的有效性和过期时间
4. **MQTT桥接**: 如果启用MQTT功能，监控桥接状态
5. **存储使用**: 监控matter.json存储文件大小和设备数量5.0","message":"starting update process","timestamp":1234567890}` | 开始更新 |
| `isg/update/matter-server/status` | `updating` | `{"status":"updating","current_version":"6.5.0","message":"reading upgrade dependencies from serviceupdate.json","timestamp":1234567890}` | 读取升级依赖 |
| `isg/update/matter-server/status` | `updating` | `{"status":"updating","current_version":"6.5.0","message":"installing upgrade dependencies","dependencies":["cryptography>=3.4.8"],"timestamp":1234567890}` | 安装升级依赖 |
| `isg/update/matter-server/status` | `updating` | `{"status":"updating","current_version":"6.5.0","message":"stopping service","timestamp":1234567890}` | 停止服务 |
| `isg/update/matter-server/status` | `updating` | `{"status":"updating","current_version":"6.

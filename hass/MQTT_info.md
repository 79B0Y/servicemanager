# Home Assistant 服务管理系统 - MQTT 消息上报列表

## 1. 安装相关消息 (install.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/install/hass/status` | `installing` | `{"status":"installing","message":"starting installation process","timestamp":1234567890}` | 开始安装 |
| `isg/install/hass/status` | `installing` | `{"status":"installing","message":"reading service dependencies from serviceupdate.json","timestamp":1234567890}` | 读取服务依赖 |
| `isg/install/hass/status` | `installing` | `{"status":"installing","message":"installing required dependencies","dependencies":["python3","python3-pip","python3-venv","ffmpeg","libturbojpeg0-dev"],"timestamp":1234567890}` | 安装依赖包 |
| `isg/install/hass/status` | `installing` | `{"status":"installing","message":"installing system dependencies","timestamp":1234567890}` | 安装系统依赖 |
| `isg/install/hass/status` | `installing` | `{"status":"installing","message":"cleaning up old installation","timestamp":1234567890}` | 清理旧安装 |
| `isg/install/hass/status` | `installing` | `{"status":"installing","message":"creating virtual environment","timestamp":1234567890}` | 创建虚拟环境 |
| `isg/install/hass/status` | `installing` | `{"status":"installing","message":"installing python dependencies","timestamp":1234567890}` | 安装Python依赖 |
| `isg/install/hass/status` | `installing` | `{"status":"installing","message":"installing Home Assistant","version":"2025.7.1","timestamp":1234567890}` | 安装HA核心 |
| `isg/install/hass/status` | `installing` | `{"status":"installing","message":"generating initial configuration","timestamp":1234567890}` | 生成配置 |
| `isg/install/hass/status` | `installing` | `{"status":"installing","message":"starting service for testing","timestamp":1234567890}` | 启动服务测试 |
| `isg/install/hass/status` | `installing` | `{"status":"installing","message":"waiting for service ready","timestamp":1234567890}` | 等待服务就绪 |
| `isg/install/hass/status` | `installing` | `{"status":"installing","message":"stabilizing service for 5 minutes","timestamp":1234567890}` | 服务稳定化 |
| `isg/install/hass/status` | `installing` | `{"status":"installing","message":"installing acceleration libraries","timestamp":1234567890}` | 安装加速库 |
| `isg/install/hass/status` | `installing` | `{"status":"installing","message":"applying configuration optimizations","timestamp":1234567890}` | 配置优化 |
| `isg/install/hass/status` | `installing` | `{"status":"installing","message":"recording installation history","version":"2025.7.1","timestamp":1234567890}` | 记录安装历史 |
| `isg/install/hass/status` | `installing` | `{"status":"installing","message":"final startup verification","timestamp":1234567890}` | 最终启动验证 |
| `isg/install/hass/status` | `success` | `{"service":"hass","status":"success","version":"2025.7.1","duration":180,"timestamp":1234567890}` | 安装成功 |
| `isg/install/hass/status` | `failed` | `{"status":"failed","message":"dependency installation failed","dependencies":["python3","ffmpeg"],"timestamp":1234567890}` | 依赖安装失败 |
| `isg/install/hass/status` | `failed` | `{"status":"failed","message":"virtual environment creation failed","timestamp":1234567890}` | 虚拟环境创建失败 |
| `isg/install/hass/status` | `failed` | `{"status":"failed","message":"python dependencies installation failed","timestamp":1234567890}` | Python依赖安装失败 |
| `isg/install/hass/status` | `failed` | `{"status":"failed","message":"Home Assistant installation failed","timestamp":1234567890}` | HA安装失败 |
| `isg/install/hass/status` | `failed` | `{"status":"failed","message":"service start timeout after installation","timeout":300,"timestamp":1234567890}` | 安装后启动超时 |
| `isg/install/hass/status` | `failed` | `{"status":"failed","message":"service failed to start after installation","timestamp":1234567890}` | 最终验证失败 |

## 2. 卸载相关消息 (uninstall.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/install/hass/status` | `uninstalling` | `{"status":"uninstalling","message":"starting uninstall process","timestamp":1234567890}` | 开始卸载 |
| `isg/install/hass/status` | `uninstalling` | `{"status":"uninstalling","message":"stopping service","timestamp":1234567890}` | 停止服务 |
| `isg/install/hass/status` | `uninstalling` | `{"status":"uninstalling","message":"removing installation directory","timestamp":1234567890}` | 删除安装目录 |
| `isg/install/hass/status` | `uninstalled` | `{"status":"uninstalled","message":"Home Assistant completely removed","timestamp":1234567890}` | 卸载完成 |

## 3. 启动相关消息 (start.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/run/hass/status` | `starting` | `{"service":"hass","status":"starting","message":"starting service","timestamp":1234567890}` | 开始启动 |
| `isg/run/hass/status` | `starting` | `{"service":"hass","status":"starting","message":"removed down file to enable auto-start","timestamp":1234567890}` | 移除down文件 |
| `isg/run/hass/status` | `starting` | `{"service":"hass","status":"starting","message":"waiting for service ready","timestamp":1234567890}` | 等待服务就绪 |
| `isg/run/hass/status` | `success` | `{"service":"hass","status":"success","message":"service started successfully","timestamp":1234567890}` | 启动成功 |
| `isg/run/hass/status` | `failed` | `{"service":"hass","status":"failed","message":"supervise control file not found","timestamp":1234567890}` | 控制文件不存在 |
| `isg/run/hass/status` | `failed` | `{"service":"hass","status":"failed","message":"service failed to reach running state","timeout":150,"timestamp":1234567890}` | 启动超时 |

## 4. 停止相关消息 (stop.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/run/hass/status` | `stopping` | `{"service":"hass","status":"stopping","message":"stopping service","timestamp":1234567890}` | 开始停止 |
| `isg/run/hass/status` | `stopping` | `{"service":"hass","status":"stopping","message":"created down file to disable auto-start","timestamp":1234567890}` | 创建down文件 |
| `isg/run/hass/status` | `stopping` | `{"service":"hass","status":"stopping","message":"waiting for service to stop","timestamp":1234567890}` | 等待服务停止 |
| `isg/run/hass/status` | `success` | `{"service":"hass","status":"success","message":"service stopped and disabled","timestamp":1234567890}` | 停止成功 |
| `isg/run/hass/status` | `failed` | `{"service":"hass","status":"failed","message":"service still running after stop timeout","timeout":150,"timestamp":1234567890}` | 停止失败 |

## 5. 状态查询消息 (status.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/status/hass/status` | `running` | `{"service":"hass","status":"running","pid":1234,"runtime":"1:23:45","http_available":true,"timestamp":1234567890}` | 服务运行中 |
| `isg/status/hass/status` | `starting` | `{"service":"hass","status":"starting","pid":1234,"runtime":"0:01:30","http_available":false,"timestamp":1234567890}` | 服务启动中 |
| `isg/status/hass/status` | `stopped` | `{"service":"hass","status":"stopped","message":"service not running","timestamp":1234567890}` | 服务已停止 |

## 6. 备份相关消息 (backup.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/backup/hass/status` | `backuping` | `{"status":"backuping","message":"starting backup process","timestamp":1234567890}` | 开始备份 |
| `isg/backup/hass/status` | `backuping` | `{"status":"backuping","message":"creating archive","timestamp":1234567890}` | 创建压缩包 |
| `isg/backup/hass/status` | `skipped` | `{"status":"skipped","message":"service not running - backup skipped","timestamp":1234567890}` | 服务未运行跳过 |
| `isg/backup/hass/status` | `success` | `{"service":"hass","status":"success","file":"/sdcard/isgbackup/hass/backup.tar.gz","size_kb":2048,"duration":45,"message":"backup completed successfully","timestamp":1234567890}` | 备份成功 |
| `isg/backup/hass/status` | `failed` | `{"status":"failed","message":"tar command failed inside container","timestamp":1234567890}` | 备份失败 |

## 7. 还原相关消息 (restore.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/restore/hass/status` | `restoring` | `{"status":"restoring","method":"latest_backup","file":"homeassistant_backup_20250715.tar.gz"}` | 使用最新备份文件还原 |
| `isg/restore/hass/status` | `restoring` | `{"status":"restoring","method":"user_specified","file":"/sdcard/Download/my_backup.tar.gz"}` | 用户指定tar.gz文件 |
| `isg/restore/hass/status` | `restoring` | `{"status":"restoring","method":"user_specified","file":"/sdcard/Download/backup.zip","converting_zip":true}` | 用户指定ZIP文件（需转换） |
| `isg/restore/hass/status` | `restoring` | `{"status":"restoring","method":"default_config","timestamp":1234567890}` | 无备份文件，生成默认配置 |
| `isg/restore/hass/status` | `success` | `{"service":"hass","status":"success","method":"latest_backup","file":"homeassistant_backup_20250715.tar.gz","size_kb":2048,"duration":60,"timestamp":1234567890}` | 最新备份还原成功 |
| `isg/restore/hass/status` | `success` | `{"service":"hass","status":"success","method":"user_specified","original_file":"backup.zip","restore_file":"backup.tar.gz","size_kb":1024,"duration":90,"converted_from_zip":true,"timestamp":1234567890}` | 用户指定文件还原成功（含转换） |
| `isg/restore/hass/status` | `success` | `{"service":"hass","status":"success","method":"user_specified","file":"/sdcard/my_backup.tar.gz","size_kb":1536,"duration":45,"timestamp":1234567890}` | 用户指定tar.gz还原成功 |
| `isg/restore/hass/status` | `success` | `{"service":"hass","status":"success","method":"default_config","duration":180,"startup_time":45,"timestamp":1234567890}` | 默认配置生成成功 |
| `isg/restore/hass/status` | `failed` | `{"status":"failed","message":"user specified file not found","file":"/sdcard/nonexistent.tar.gz","timestamp":1234567890}` | 用户指定文件不存在 |
| `isg/restore/hass/status` | `failed` | `{"status":"failed","message":"failed to extract zip file","timestamp":1234567890}` | ZIP文件解压失败 |
| `isg/restore/hass/status` | `failed` | `{"status":"failed","message":"invalid zip structure","timestamp":1234567890}` | ZIP文件结构无效 |
| `isg/restore/hass/status` | `failed` | `{"status":"failed","message":"failed to create tar.gz from zip","timestamp":1234567890}` | ZIP转换失败 |
| `isg/restore/hass/status` | `failed` | `{"status":"failed","message":"unsupported file format. only .tar.gz and .zip are supported","file":"backup.rar","timestamp":1234567890}` | 不支持的文件格式 |
| `isg/restore/hass/status` | `failed` | `{"status":"failed","message":"service failed to start after restore","method":"user_specified","timestamp":1234567890}` | 还原后启动失败 |
| `isg/restore/hass/status` | `failed` | `{"status":"failed","message":"service failed to start after config generation","method":"default_config","timestamp":1234567890}` | 配置生成后启动失败 |
| `isg/restore/hass/status` | `failed` | `{"status":"failed","message":"restore failed inside proot container","timestamp":1234567890}` | 容器内还原失败 |

## 8. 更新相关消息 (update.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/update/hass/status` | `updating` | `{"status":"updating","current_version":"2025.5.3","target_version":"2025.7.1","message":"starting update process","timestamp":1234567890}` | 开始更新 |
| `isg/update/hass/status` | `updating` | `{"status":"updating","current_version":"2025.5.3","message":"reading upgrade dependencies from serviceupdate.json","timestamp":1234567890}` | 读取升级依赖 |
| `isg/update/hass/status` | `updating` | `{"status":"updating","current_version":"2025.5.3","message":"installing upgrade dependencies","dependencies":"click==8.1.7","timestamp":1234567890}` | 安装升级依赖 |
| `isg/update/hass/status` | `updating` | `{"status":"updating","current_version":"2025.5.3","message":"stopping service","timestamp":1234567890}` | 停止服务 |
| `isg/update/hass/status` | `updating` | `{"status":"updating","current_version":"2025.5.3","message":"installing new version","target_version":"2025.7.1","timestamp":1234567890}` | 安装新版本 |
| `isg/update/hass/status` | `updating` | `{"status":"updating","current_version":"2025.5.3","message":"starting service","new_version":"2025.7.1","timestamp":1234567890}` | 启动服务 |
| `isg/update/hass/status` | `updating` | `{"status":"updating","current_version":"2025.5.3","message":"waiting for service ready","new_version":"2025.7.1","timestamp":1234567890}` | 等待服务就绪 |
| `isg/update/hass/status` | `updating` | `{"status":"updating","old_version":"2025.5.3","new_version":"2025.7.1","message":"recording update history","timestamp":1234567890}` | 记录更新历史 |
| `isg/update/hass/status` | `success` | `{"service":"hass","status":"success","old_version":"2025.5.3","new_version":"2025.7.1","duration":240,"timestamp":1234567890}` | 更新成功 |
| `isg/update/hass/status` | `failed` | `{"status":"failed","message":"TARGET_VERSION not set and unable to get latest version","current_version":"2025.5.3","timestamp":1234567890}` | 无法确定目标版本 |
| `isg/update/hass/status` | `failed` | `{"status":"failed","message":"upgrade dependencies installation failed","dependencies":"click==8.1.7","current_version":"2025.5.3","timestamp":1234567890}` | 升级依赖安装失败 |
| `isg/update/hass/status` | `failed` | `{"status":"failed","message":"Home Assistant upgrade failed","current_version":"2025.5.3","target_version":"2025.7.1","timestamp":1234567890}` | HA升级失败 |
| `isg/update/hass/status` | `failed` | `{"status":"failed","message":"failed to get updated version","current_version":"2025.5.3","timestamp":1234567890}` | 获取版本失败 |
| `isg/update/hass/status` | `failed` | `{"status":"failed","message":"version mismatch","expected":"2025.7.1","actual":"2025.6.0","timestamp":1234567890}` | 版本不匹配 |
| `isg/update/hass/status` | `failed` | `{"status":"failed","message":"service start timeout after update","old_version":"2025.5.3","new_version":"2025.7.1","timeout":300,"timestamp":1234567890}` | 更新后启动超时 |

## 9. 自检相关消息 (autocheck.sh)

### 9.1 自检过程消息

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/autocheck/hass/status` | `start` | `{"status":"start","run":"unknown","config":{},"install":"checking","current_version":"unknown","latest_version":"unknown","update":"checking","message":"starting autocheck process","timestamp":1234567890}` | 开始自检 |
| `isg/autocheck/hass/status` | `recovered` | `{"status":"recovered","message":"service recovered after restart attempts","timestamp":1234567890}` | 服务恢复成功 |

### 9.2 综合状态消息 (汇总所有脚本状态)

#### 9.2.1 正常运行状态

| 状态场景 | MQTT 消息示例 |
|---------|-------------|
| **服务健康运行** | `{"status":"healthy","run":"running","config":{"http_port":8123,"db_url":"default","log_level":"warning","timezone":"Asia/Shanghai","name":"Home","frontend_enabled":true},"install":"success","backup":"success","restore":"success","update":"success","current_version":"2025.7.1","latest_version":"2025.7.1","update_info":"SUCCESS 2 hours ago (2025.5.3 -> 2025.7.1)","message":"Home Assistant running for 2 hours","http_available":"true","timestamp":1234567890}` |
| **服务启动中** | `{"status":"healthy","run":"starting","config":{"http_port":8123,"db_url":"default","log_level":"warning","timezone":"Asia/Shanghai","name":"Home","frontend_enabled":true},"install":"success","backup":"success","restore":"success","update":"success","current_version":"2025.7.1","latest_version":"2025.7.1","update_info":"SUCCESS 2 hours ago (2025.5.3 -> 2025.7.1)","message":"Home Assistant is starting up","http_available":"false","timestamp":1234567890}` |
| **服务被禁用** | `{"status":"disabled","run":"disabled","config":{"http_port":8123,"db_url":"default","log_level":"warning","timezone":"Asia/Shanghai","name":"Home","frontend_enabled":true},"install":"success","backup":"success","restore":"success","update":"success","current_version":"2025.7.1","latest_version":"2025.7.1","update_info":"SUCCESS 2 hours ago (2025.5.3 -> 2025.7.1)","message":"service is disabled","timestamp":1234567890}` |

#### 9.2.2 操作进行中状态

| 状态场景 | MQTT 消息示例 |
|---------|-------------|
| **安装进行中** | `{"status":"healthy","run":"stopped","config":{},"install":"installing","backup":"success","restore":"success","update":"success","current_version":"unknown","latest_version":"2025.7.1","update_info":"SUCCESS 1 day ago (2025.5.0 -> 2025.5.3)","message":"Home Assistant installation in progress","timestamp":1234567890}` |
| **更新进行中** | `{"status":"healthy","run":"running","config":{"http_port":8123,"db_url":"default","log_level":"warning","timezone":"Asia/Shanghai","name":"Home","frontend_enabled":true},"install":"success","backup":"success","restore":"success","update":"updating","current_version":"2025.5.3","latest_version":"2025.7.1","update_info":"UPDATING 2025.5.3 -> 2025.7.1","message":"Home Assistant update in progress","timestamp":1234567890}` |
| **备份进行中** | `{"status":"healthy","run":"running","config":{"http_port":8123,"db_url":"default","log_level":"warning","timezone":"Asia/Shanghai","name":"Home","frontend_enabled":true},"install":"success","backup":"backuping","restore":"success","update":"success","current_version":"2025.7.1","latest_version":"2025.7.1","update_info":"SUCCESS 2 hours ago (2025.5.3 -> 2025.7.1)","message":"Home Assistant backup in progress","timestamp":1234567890}` |
| **还原进行中** | `{"status":"healthy","run":"stopped","config":{},"install":"success","backup":"success","restore":"restoring","update":"success","current_version":"2025.7.1","latest_version":"2025.7.1","update_info":"SUCCESS 2 hours ago (2025.5.3 -> 2025.7.1)","message":"Home Assistant restore in progress","timestamp":1234567890}` |
| **卸载进行中** | `{"status":"healthy","run":"stopping","config":{},"install":"uninstalling","backup":"success","restore":"success","update":"success","current_version":"2025.7.1","latest_version":"2025.7.1","update_info":"SUCCESS 2 hours ago (2025.5.3 -> 2025.7.1)","message":"Home Assistant uninstall in progress","timestamp":1234567890}` |

#### 9.2.3 问题状态

| 状态场景 | MQTT 消息示例 |
|---------|-------------|
| **服务启动失败** | `{"status":"problem","run":"failed","config":{"http_port":8123,"db_url":"default","log_level":"warning","timezone":"Asia/Shanghai","name":"Home","frontend_enabled":true},"install":"success","backup":"success","restore":"success","update":"success","current_version":"2025.7.1","latest_version":"2025.7.1","update_info":"SUCCESS 2 hours ago (2025.5.3 -> 2025.7.1)","message":"failed to start service after retries","timestamp":1234567890}` |
| **安装失败** | `{"status":"problem","run":"stopped","config":{},"install":"failed","backup":"success","restore":"success","update":"success","current_version":"unknown","latest_version":"2025.7.1","update_info":"never updated","message":"installation failed","timestamp":1234567890}` |
| **更新失败** | `{"status":"problem","run":"running","config":{"http_port":8123,"db_url":"default","log_level":"warning","timezone":"Asia/Shanghai","name":"Home","frontend_enabled":true},"install":"success","backup":"success","restore":"success","update":"failed","current_version":"2025.5.3","latest_version":"2025.7.1","update_info":"FAILED 1 hour ago (2025.5.3 -> 2025.7.1) service start timeout","message":"recent update failed but service still running on old version","timestamp":1234567890}` |
| **HTTP端口不可用** | `{"status":"problem","run":"running","config":{"http_port":8123,"db_url":"default","log_level":"warning","timezone":"Asia/Shanghai","name":"Home","frontend_enabled":true},"install":"success","backup":"success","restore":"success","update":"success","current_version":"2025.7.1","latest_version":"2025.7.1","update_info":"SUCCESS 2 hours ago (2025.5.3 -> 2025.7.1)","message":"service running but HTTP port not available","http_available":"false","timestamp":1234567890}` |
| **服务可能重启** | `{"status":"problem","run":"running","config":{"http_port":8123,"db_url":"default","log_level":"warning","timezone":"Asia/Shanghai","name":"Home","frontend_enabled":true},"install":"success","backup":"success","restore":"success","update":"success","current_version":"2025.7.1","latest_version":"2025.7.1","update_info":"SUCCESS 2 hours ago (2025.5.3 -> 2025.7.1)","message":"service uptime less than interval, possible restart","http_available":"true","timestamp":1234567890}` |

## 10. 性能监控消息 (autocheck.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/autocheck/hass/performance` | - | `{"cpu":"12.5","mem":"15.2","timestamp":1234567890}` | 性能数据上报 |
| `isg/status/hass/performance` | - | `{"cpu":"12.5","mem":"15.2","timestamp":1234567890}` | 状态性能数据 |

## 11. 版本信息消息 (autocheck.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/autocheck/hass/version` | - | `{"script_version":"1.4.0","latest_script_version":"1.4.0","ha_version":"2025.7.1","latest_ha_version":"2025.7.1","upgrade_dependencies":["click==8.1.7"]}` | 版本信息上报 |

## 📋 消息总结统计

- **总主题数**: 5个基础主题 (install, run, status, backup, restore, update, autocheck)
- **标准状态值**: 4种核心状态 (installing/starting/restoring/updating, success, failed, skipped)
- **总消息类型数**: 约50种不同消息
- **特殊主题**: performance, version 子主题

## 🎯 状态值标准化

所有操作遵循统一的状态模式：
- **进行中**: `installing` / `starting` / `stopping` / `restoring` / `updating` / `backuping` / `uninstalling`
- **成功**: `success` / `running` / `stopped` / `healthy`
- **失败**: `failed` / `problem`  
- **跳过**: `skipped` / `disabled`
- **从未执行**: `never`

## 🔍 状态字段说明

| 字段名 | 可能值 | 说明 |
|-------|--------|------|
| `status` | `start`, `healthy`, `problem`, `disabled` | 总体健康状态 |
| `run` | `starting`, `stopping`, `running`, `stopped`, `failed`, `disabled` | 运行状态 (对应 start/stop 脚本状态) |
| `config` | JSON对象 或 `{}` | 当前配置信息，服务未安装时为空 |
| `install` | `installing`, `uninstalling`, `success`, `failed`, `never` | 安装状态 (对应 install/uninstall 脚本状态) |
| `backup` | `backuping`, `success`, `failed`, `never` | 最近备份状态 (对应 backup 脚本状态) |
| `restore` | `restoring`, `success`, `failed`, `never` | 最近还原状态 (对应 restore 脚本状态) |
| `update` | `updating`, `success`, `failed`, `never` | 最近更新状态 (对应 update 脚本状态) |
| `current_version` | 版本号 或 `unknown` | 当前安装的HA版本 |
| `latest_version` | 版本号 或 `unknown` | 最新可用版本 |
| `update_info` | 更新摘要信息 | 最近更新的详细信息 |
| `message` | 描述性文本 | 当前状态的人性化描述 |
| `http_available` | `true`, `false` | HTTP端口(8123)可用状态 |

## 🔍 配置信息字段说明

| 配置字段 | 含义 | 示例值 |
|---------|------|--------|
| `http_port` | HTTP服务端口 | `8123` |
| `db_url` | 数据库连接URL | `"sqlite:////root/.homeassistant/home-assistant_v2.db"` |
| `log_level` | 日志级别 | `"warning"`, `"info"`, `"debug"` |
| `timezone` | 时区设置 | `"Asia/Shanghai"` |
| `name` | 家庭名称 | `"Home"`, `"我的家"` |
| `frontend_enabled` | 前端是否启用 | `true`, `false` |

## 🌟 Home Assistant 特有消息特点

### 1. **HTTP 端口监控**
与 Zigbee2MQTT 的 MQTT 桥接状态类似，HA 监控 HTTP 端口(8123)可用性：
```json
{
  "http_available": true,
  "message": "Home Assistant running for 2 hours"
}
```

### 2. **虚拟环境管理**
HA 特有的 Python 虚拟环境创建和管理：
```json
{
  "status": "installing",
  "message": "creating virtual environment",
  "timestamp": 1234567890
}
```

### 3. **配置优化步骤**
HA 安装过程中的特殊配置优化：
```json
{
  "status": "installing", 
  "message": "installing acceleration libraries",
  "timestamp": 1234567890
}
```

### 4. **服务稳定化**
HA 安装后需要稳定运行检查：
```json
{
  "status": "installing",
  "message": "stabilizing service for 5 minutes", 
  "timestamp": 1234567890
}
```

### 5. **ZIP 文件支持**
HA 的还原功能支持 ZIP 文件自动转换：
```json
{
  "status": "restoring",
  "method": "user_specified",
  "file": "/sdcard/backup.zip",
  "converting_zip": true
}
```

## 🆚 与 Zigbee2MQTT 的差异对比

| 特性 | Zigbee2MQTT | Home Assistant |
|------|-------------|----------------|
| **核心端口** | 8080 (Web UI) | 8123 (HTTP) |
| **状态检查** | MQTT桥接状态 | HTTP端口可用性 |
| **配置格式** | YAML (串口配置) | YAML (完整HA配置) |
| **安装环境** | Node.js + pnpm | Python + venv |
| **特殊检测** | 串口设备扫描 | 配置文件解析 |
| **备份内容** | `/opt/zigbee2mqtt/data` | `/root/.homeassistant` |
| **版本管理** | Git pull + build | pip install |
| **启动时间** | 30-60秒 | 60-180秒 |
| **稳定化需求** | 无特殊要求 | 需要5分钟稳定期 |

## 🌟 共同的设计模式

### 1. **标准化 MQTT 主题结构**
```
isg/{operation}/{service_id}/status
isg/autocheck/{service_id}/{type}
```

### 2. **统一的状态字段**
```json
{
  "service": "hass|zigbee2mqtt",
  "status": "success|failed|installing|running",
  "message": "human readable description",
  "timestamp": 1234567890
}
```

### 3. **一致的脚本状态汇总**
```json
{
  "install": "success|failed|installing|never",
  "run": "running|stopped|starting|failed", 
  "backup": "success|failed|backuping|never",
  "restore": "success|failed|restoring|never",
  "update": "success|failed|updating|never"
}
```

### 4. **标准化历史记录格式**
```
2025-07-15 10:30:15 INSTALL SUCCESS 2025.7.1
2025-07-15 11:45:22 SUCCESS 2025.5.3 -> 2025.7.1
2025-07-15 12:20:10 FAILED 2025.7.1 -> 2025.8.0 (reason)
```

## 🎯 状态值含义说明

**`never`**: 表示该操作从未执行过
- `backup: "never"` - 从未执行过备份操作
- `restore: "never"` - 从未执行过还原操作  
- `update: "never"` - 从未执行过更新操作
- `install: "never"` - 从未安装过服务

**`success`**: 最近一次操作成功完成
**`failed`**: 最近一次操作执行失败
**进行中状态**: `installing`, `updating`, `backuping`, `restoring` 等表示操作正在执行

## 🚀 扩展建议

基于这两个服务的成功模式，未来扩展其他服务时可以考虑：

### 1. **MySQL/MariaDB 特有消息**
- 数据库连接状态检查
- 数据库大小和性能监控
- SQL 备份和还原进度

### 2. **SSH 服务特有消息**
- 连接尝试监控
- 密钥管理状态
- 安全日志分析

### 3. **Nginx 特有消息**
- 虚拟主机配置验证
- SSL 证书状态检查
- 访问统计和性能

### 4. **通用扩展功能**
- 服务间依赖关系检查
- 资源使用率预警
- 自动故障切换机制
- 服务编排和批量操作

## 💡 最佳实践总结

1. **保持消息格式一致性** - 所有服务使用相同的字段结构
2. **提供详细的进度反馈** - 长时间操作要有步骤提示
3. **包含足够的上下文信息** - 错误消息要包含具体原因
4. **支持多种数据格式** - 备份还原支持多种文件格式
5. **实现优雅的降级** - 组件不可用时提供备选方案
6. **记录完整的操作历史** - 便于问题排查和趋势分析

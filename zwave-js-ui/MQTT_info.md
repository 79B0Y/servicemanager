# Z-Wave JS UI 服务管理系统 - MQTT 消息上报列表

## 1. 安装相关消息 (install.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/install/zwave-js-ui/status` | `installing` | `{"status":"installing","message":"starting installation process","timestamp":1234567890}` | 开始安装 |
| `isg/install/zwave-js-ui/status` | `installing` | `{"status":"installing","message":"reading service dependencies from serviceupdate.json","timestamp":1234567890}` | 读取服务依赖 |
| `isg/install/zwave-js-ui/status` | `installing` | `{"status":"installing","message":"installing required dependencies","dependencies":["nodejs","git","make","g++","gcc","libsystemd-dev"],"timestamp":1234567890}` | 安装依赖包 |
| `isg/install/zwave-js-ui/status` | `installing` | `{"status":"installing","message":"installing system dependencies","timestamp":1234567890}` | 安装系统依赖 |
| `isg/install/zwave-js-ui/status` | `installing` | `{"status":"installing","message":"installing pnpm package manager","timestamp":1234567890}` | 安装pnpm |
| `isg/install/zwave-js-ui/status` | `installing` | `{"status":"installing","message":"initializing pnpm environment","timestamp":1234567890}` | 初始化pnpm环境 |
| `isg/install/zwave-js-ui/status` | `installing` | `{"status":"installing","message":"installing zwave-js-ui globally","timestamp":1234567890}` | 全局安装Z-Wave JS UI |
| `isg/install/zwave-js-ui/status` | `installing` | `{"status":"installing","message":"creating store directory","timestamp":1234567890}` | 创建存储目录 |
| `isg/install/zwave-js-ui/status` | `installing` | `{"status":"installing","message":"generating initial configuration","timestamp":1234567890}` | 生成配置 |
| `isg/install/zwave-js-ui/status` | `installing` | `{"status":"installing","message":"starting service for testing","timestamp":1234567890}` | 启动服务测试 |
| `isg/install/zwave-js-ui/status` | `installing` | `{"status":"installing","message":"waiting for service ready","timestamp":1234567890}` | 等待服务就绪 |
| `isg/install/zwave-js-ui/status` | `installing` | `{"status":"installing","message":"recording installation history","version":"9.9.1","timestamp":1234567890}` | 记录安装历史 |
| `isg/install/zwave-js-ui/status` | `installed` | `{"service":"zwave-js-ui","status":"installed","version":"9.9.1","duration":120,"timestamp":1234567890}` | 安装成功 |
| `isg/install/zwave-js-ui/status` | `failed` | `{"status":"failed","message":"dependency installation failed","dependencies":["nodejs","git"],"timestamp":1234567890}` | 依赖安装失败 |
| `isg/install/zwave-js-ui/status` | `failed` | `{"status":"failed","message":"pnpm installation failed","timestamp":1234567890}` | pnpm安装失败 |
| `isg/install/zwave-js-ui/status` | `failed` | `{"status":"failed","message":"pnpm environment initialization failed","timestamp":1234567890}` | pnpm环境初始化失败 |
| `isg/install/zwave-js-ui/status` | `failed` | `{"status":"failed","message":"zwave-js-ui installation failed","timestamp":1234567890}` | Z-Wave JS UI安装失败 |
| `isg/install/zwave-js-ui/status` | `failed` | `{"status":"failed","message":"service start timeout after installation","timeout":300,"timestamp":1234567890}` | 安装后启动超时 |

## 2. 卸载相关消息 (uninstall.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/install/zwave-js-ui/status` | `uninstalling` | `{"status":"uninstalling","message":"starting uninstall process","timestamp":1234567890}` | 开始卸载 |
| `isg/install/zwave-js-ui/status` | `uninstalling` | `{"status":"uninstalling","message":"stopping service","timestamp":1234567890}` | 停止服务 |
| `isg/install/zwave-js-ui/status` | `uninstalling` | `{"status":"uninstalling","message":"removing installation directory","timestamp":1234567890}` | 删除安装目录 |
| `isg/install/zwave-js-ui/status` | `uninstalled` | `{"status":"uninstalled","message":"zwave-js-ui completely removed","timestamp":1234567890}` | 卸载完成 |

## 3. 启动相关消息 (start.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/run/zwave-js-ui/status` | `starting` | `{"service":"zwave-js-ui","status":"starting","message":"starting service","timestamp":1234567890}` | 开始启动 |
| `isg/run/zwave-js-ui/status` | `starting` | `{"service":"zwave-js-ui","status":"starting","message":"removed down file to enable auto-start","timestamp":1234567890}` | 移除down文件 |
| `isg/run/zwave-js-ui/status` | `starting` | `{"service":"zwave-js-ui","status":"starting","message":"waiting for service ready","timestamp":1234567890}` | 等待服务就绪 |
| `isg/run/zwave-js-ui/status` | `success` | `{"service":"zwave-js-ui","status":"success","message":"service started successfully","timestamp":1234567890}` | 启动成功 |
| `isg/run/zwave-js-ui/status` | `failed` | `{"service":"zwave-js-ui","status":"failed","message":"supervise control file not found","timestamp":1234567890}` | 控制文件不存在 |
| `isg/run/zwave-js-ui/status` | `failed` | `{"service":"zwave-js-ui","status":"failed","message":"service failed to reach running state","timeout":150,"timestamp":1234567890}` | 启动超时 |

## 4. 停止相关消息 (stop.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/run/zwave-js-ui/status` | `stopping` | `{"service":"zwave-js-ui","status":"stopping","message":"stopping service","timestamp":1234567890}` | 开始停止 |
| `isg/run/zwave-js-ui/status` | `stopping` | `{"service":"zwave-js-ui","status":"stopping","message":"created down file to disable auto-start","timestamp":1234567890}` | 创建down文件 |
| `isg/run/zwave-js-ui/status` | `stopping` | `{"service":"zwave-js-ui","status":"stopping","message":"waiting for service to stop","timestamp":1234567890}` | 等待服务停止 |
| `isg/run/zwave-js-ui/status` | `success` | `{"service":"zwave-js-ui","status":"success","message":"service stopped and disabled","timestamp":1234567890}` | 停止成功 |
| `isg/run/zwave-js-ui/status` | `failed` | `{"service":"zwave-js-ui","status":"failed","message":"service still running after stop timeout","timeout":150,"timestamp":1234567890}` | 停止失败 |

## 5. 状态查询消息 (status.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/status/zwave-js-ui/status` | `running` | `{"service":"zwave-js-ui","status":"running","pid":1234,"runtime":"1:23:45","web_status":"online","port":"8091","timestamp":1234567890}` | 服务运行中 |
| `isg/status/zwave-js-ui/status` | `starting` | `{"service":"zwave-js-ui","status":"starting","pid":1234,"runtime":"0:01:30","web_status":"starting","port":"8091","timestamp":1234567890}` | 服务启动中 |
| `isg/status/zwave-js-ui/status` | `stopped` | `{"service":"zwave-js-ui","status":"stopped","message":"service not running","timestamp":1234567890}` | 服务已停止 |

## 6. 备份相关消息 (backup.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/backup/zwave-js-ui/status` | `backuping` | `{"status":"backuping","message":"starting backup process","timestamp":1234567890}` | 开始备份 |
| `isg/backup/zwave-js-ui/status` | `backuping` | `{"status":"backuping","message":"creating archive","timestamp":1234567890}` | 创建压缩包 |
| `isg/backup/zwave-js-ui/status` | `skipped` | `{"status":"skipped","message":"service not running - backup skipped","timestamp":1234567890}` | 服务未运行跳过 |
| `isg/backup/zwave-js-ui/status` | `success` | `{"service":"zwave-js-ui","status":"success","file":"/sdcard/isgbackup/zwave-js-ui/backup.tar.gz","size_kb":1024,"duration":30,"message":"backup completed successfully","timestamp":1234567890}` | 备份成功 |
| `isg/backup/zwave-js-ui/status` | `failed` | `{"status":"failed","message":"store directory not found","timestamp":1234567890}` | 存储目录不存在 |
| `isg/backup/zwave-js-ui/status` | `failed` | `{"status":"failed","message":"tar command failed inside container","timestamp":1234567890}` | 备份失败 |

## 7. 还原相关消息 (restore.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/restore/zwave-js-ui/status` | `restoring` | `{"status":"restoring","method":"latest_backup","file":"zwave-js-ui_backup_20250715.tar.gz"}` | 使用最新备份文件还原 |
| `isg/restore/zwave-js-ui/status` | `restoring` | `{"status":"restoring","method":"user_specified","file":"/sdcard/Download/my_backup.tar.gz"}` | 用户指定tar.gz文件 |
| `isg/restore/zwave-js-ui/status` | `restoring` | `{"status":"restoring","method":"user_specified","file":"/sdcard/Download/backup.zip","converting_zip":true}` | 用户指定ZIP文件（需转换） |
| `isg/restore/zwave-js-ui/status` | `restoring` | `{"status":"restoring","method":"default_config","zwave_devices_found":1}` | 无备份文件，生成默认配置 |
| `isg/restore/zwave-js-ui/status` | `success` | `{"service":"zwave-js-ui","status":"success","method":"latest_backup","file":"zwave-js-ui_backup_20250715.tar.gz","size_kb":1024,"duration":45,"timestamp":1234567890}` | 最新备份还原成功 |
| `isg/restore/zwave-js-ui/status` | `success` | `{"service":"zwave-js-ui","status":"success","method":"user_specified","original_file":"backup.zip","restore_file":"backup.tar.gz","size_kb":1024,"duration":60,"converted_from_zip":true,"timestamp":1234567890}` | 用户指定文件还原成功（含转换） |
| `isg/restore/zwave-js-ui/status` | `success` | `{"service":"zwave-js-ui","status":"success","method":"user_specified","file":"/sdcard/my_backup.tar.gz","size_kb":512,"duration":30,"timestamp":1234567890}` | 用户指定tar.gz还原成功 |
| `isg/restore/zwave-js-ui/status` | `success` | `{"service":"zwave-js-ui","status":"success","method":"default_config","zwave_devices_found":1,"duration":120,"startup_time":30,"timestamp":1234567890}` | 默认配置生成成功 |
| `isg/restore/zwave-js-ui/status` | `skipped` | `{"status":"skipped","message":"no zwave adapter found - cannot generate configuration","zwave_devices_detected":0}` | 无Z-Wave适配器跳过 |
| `isg/restore/zwave-js-ui/status` | `skipped` | `{"status":"skipped","message":"No backup file found and no Z-Wave adapter detected"}` | 无备份且无适配器跳过 |
| `isg/restore/zwave-js-ui/status` | `failed` | `{"status":"failed","message":"user specified file not found","file":"/sdcard/nonexistent.tar.gz","timestamp":1234567890}` | 用户指定文件不存在 |
| `isg/restore/zwave-js-ui/status` | `failed` | `{"status":"failed","message":"serial detection script not found","timestamp":1234567890}` | 检测脚本不存在 |
| `isg/restore/zwave-js-ui/status` | `failed` | `{"status":"failed","message":"serial detection failed - no result file","timestamp":1234567890}` | 串口检测失败 |
| `isg/restore/zwave-js-ui/status` | `failed` | `{"status":"failed","message":"failed to extract zip file","timestamp":1234567890}` | ZIP文件解压失败 |
| `isg/restore/zwave-js-ui/status` | `failed` | `{"status":"failed","message":"invalid zip structure","timestamp":1234567890}` | ZIP文件结构无效 |
| `isg/restore/zwave-js-ui/status` | `failed` | `{"status":"failed","message":"failed to create tar.gz from zip","timestamp":1234567890}` | ZIP转换失败 |
| `isg/restore/zwave-js-ui/status` | `failed` | `{"status":"failed","message":"unsupported file format. only .tar.gz and .zip are supported","file":"backup.rar","timestamp":1234567890}` | 不支持的文件格式 |
| `isg/restore/zwave-js-ui/status` | `failed` | `{"status":"failed","message":"service failed to start after restore","method":"user_specified","timestamp":1234567890}` | 还原后启动失败 |
| `isg/restore/zwave-js-ui/status` | `failed` | `{"status":"failed","message":"service failed to start after config generation","method":"default_config","timestamp":1234567890}` | 配置生成后启动失败 |
| `isg/restore/zwave-js-ui/status` | `failed` | `{"status":"failed","message":"restore failed inside proot container","timestamp":1234567890}` | 容器内还原失败 |

## 8. 更新相关消息 (update.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/update/zwave-js-ui/status` | `updating` | `{"status":"updating","current_version":"9.9.1","message":"starting update process","timestamp":1234567890}` | 开始更新 |
| `isg/update/zwave-js-ui/status` | `updating` | `{"status":"updating","current_version":"9.9.1","message":"reading upgrade dependencies from serviceupdate.json","timestamp":1234567890}` | 读取升级依赖 |
| `isg/update/zwave-js-ui/status` | `updating` | `{"status":"updating","current_version":"9.9.1","message":"installing upgrade dependencies","dependencies":["axios@1.6.0"],"timestamp":1234567890}` | 安装升级依赖 |
| `isg/update/zwave-js-ui/status` | `updating` | `{"status":"updating","current_version":"9.9.1","message":"stopping service","timestamp":1234567890}` | 停止服务 |
| `isg/update/zwave-js-ui/status` | `updating` | `{"status":"updating","current_version":"9.9.1","message":"updating pnpm","timestamp":1234567890}` | 更新pnpm |
| `isg/update/zwave-js-ui/status` | `updating` | `{"status":"updating","current_version":"9.9.1","message":"updating zwave-js-ui","timestamp":1234567890}` | 更新Z-Wave JS UI |
| `isg/update/zwave-js-ui/status` | `updating` | `{"status":"updating","current_version":"9.9.1","message":"starting service","timestamp":1234567890}` | 启动服务 |
| `isg/update/zwave-js-ui/status` | `updating` | `{"status":"updating","current_version":"9.9.1","message":"waiting for service ready","timestamp":1234567890}` | 等待服务就绪 |
| `isg/update/zwave-js-ui/status` | `updating` | `{"status":"updating","old_version":"9.9.1","new_version":"9.10.0","message":"recording update history","timestamp":1234567890}` | 记录更新历史 |
| `isg/update/zwave-js-ui/status` | `success` | `{"service":"zwave-js-ui","status":"success","old_version":"9.9.1","new_version":"9.10.0","duration":180,"timestamp":1234567890}` | 更新成功 |
| `isg/update/zwave-js-ui/status` | `failed` | `{"status":"failed","message":"pnpm update failed","current_version":"9.9.1","timestamp":1234567890}` | pnpm更新失败 |
| `isg/update/zwave-js-ui/status` | `failed` | `{"status":"failed","message":"zwave-js-ui update failed","current_version":"9.9.1","timestamp":1234567890}` | Z-Wave JS UI更新失败 |
| `isg/update/zwave-js-ui/status` | `failed` | `{"status":"failed","message":"failed to get updated version","current_version":"9.9.1","timestamp":1234567890}` | 获取版本失败 |
| `isg/update/zwave-js-ui/status` | `failed` | `{"status":"failed","message":"service start timeout after update","old_version":"9.9.1","new_version":"9.10.0","timeout":300,"timestamp":1234567890}` | 更新后启动超时 |

## 9. 自检相关消息 (autocheck.sh)

### 9.1 自检过程消息

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/autocheck/zwave-js-ui/status` | `start` | `{"status":"start","run":"unknown","config":{},"install":"checking","current_version":"unknown","latest_version":"unknown","update":"checking","message":"starting autocheck process","timestamp":1234567890}` | 开始自检 |
| `isg/autocheck/zwave-js-ui/status` | `recovered` | `{"status":"recovered","message":"service recovered after restart attempts","timestamp":1234567890}` | 服务恢复成功 |

### 9.2 综合状态消息 (汇总所有脚本状态)

| 状态场景 | MQTT 消息内容 |
|---------|--------------|
| **服务被禁用** | `{"status":"disabled","run":"disabled","config":{"port":"/dev/ttyUSB0","network_key":"configured","mqtt_enabled":true,"mqtt_host":"127.0.0.1","mqtt_port":1883,"web_port":8190},"install":"success","backup":"success","restore":"success","update":"success","current_version":"9.9.1","latest_version":"9.10.0","update_info":"SUCCESS 2 hours ago (9.9.0 -> 9.9.1)","message":"service is disabled","timestamp":1234567890}` |
| **服务健康运行** | `{"status":"healthy","run":"running","config":{"port":"/dev/ttyUSB0","network_key":"configured","mqtt_enabled":true,"mqtt_host":"127.0.0.1","mqtt_port":1883,"web_port":8091},"install":"success","backup":"success","restore":"success","update":"success","current_version":"9.9.1","latest_version":"9.10.0","update_info":"SUCCESS 2 hours ago (9.9.0 -> 9.9.1)","message":"zwave-js-ui running for 2 hours","web_state":"online","timestamp":1234567890}` |
| **服务启动中** | `{"status":"healthy","run":"starting","config":{"port":"/dev/ttyUSB0","network_key":"configured","mqtt_enabled":true,"mqtt_host":"127.0.0.1","mqtt_port":1883,"web_port":8091},"install":"success","backup":"success","restore":"success","update":"success","current_version":"9.9.1","latest_version":"9.10.0","update_info":"SUCCESS 2 hours ago (9.9.0 -> 9.9.1)","message":"zwave-js-ui is starting up","web_state":"starting","timestamp":1234567890}` |
| **安装进行中** | `{"status":"healthy","run":"stopped","config":{},"install":"installing","backup":"success","restore":"success","update":"success","current_version":"unknown","latest_version":"9.10.0","update_info":"SUCCESS 1 day ago (9.8.9 -> 9.9.0)","message":"zwave-js-ui installation in progress","timestamp":1234567890}` |
| **更新进行中** | `{"status":"healthy","run":"stopped","config":{"port":"/dev/ttyUSB0","network_key":"configured","mqtt_enabled":true,"mqtt_host":"127.0.0.1","mqtt_port":1883,"web_port":8091},"install":"success","backup":"success","restore":"success","update":"updating","current_version":"9.9.1","latest_version":"9.10.0","update_info":"UPDATING 9.9.1 -> 9.10.0","message":"zwave-js-ui update in progress","timestamp":1234567890}` |
| **备份进行中** | `{"status":"healthy","run":"running","config":{"port":"/dev/ttyUSB0","network_key":"configured","mqtt_enabled":true,"mqtt_host":"127.0.0.1","mqtt_port":1883,"web_port":8091},"install":"success","backup":"backuping","restore":"success","update":"success","current_version":"9.9.1","latest_version":"9.10.0","update_info":"SUCCESS 2 hours ago (9.9.0 -> 9.9.1)","message":"zwave-js-ui backup in progress","timestamp":1234567890}` |
| **还原进行中** | `{"status":"healthy","run":"stopped","config":{"error":"Config file not found"},"install":"success","backup":"success","restore":"restoring","update":"success","current_version":"9.9.1","latest_version":"9.10.0","update_info":"SUCCESS 2 hours ago (9.9.0 -> 9.9.1)","message":"zwave-js-ui restore in progress","timestamp":1234567890}` |
| **卸载进行中** | `{"status":"healthy","run":"stopping","config":{},"install":"uninstalling","backup":"success","restore":"success","update":"success","current_version":"9.9.1","latest_version":"9.10.0","update_info":"SUCCESS 2 hours ago (9.9.0 -> 9.9.1)","message":"zwave-js-ui uninstall in progress","timestamp":1234567890}` |
| **服务启动失败** | `{"status":"problem","run":"failed","config":{"port":"/dev/ttyUSB0","network_key":"configured","mqtt_enabled":true,"mqtt_host":"127.0.0.1","mqtt_port":1883,"web_port":8091},"install":"success","backup":"success","restore":"success","update":"success","current_version":"9.9.1","latest_version":"9.10.0","update_info":"SUCCESS 2 hours ago (9.9.0 -> 9.9.1)","message":"failed to start service after retries","timestamp":1234567890}` |
| **安装失败** | `{"status":"problem","run":"stopped","config":{"error":"Config file not found"},"install":"failed","backup":"success","restore":"success","update":"success","current_version":"unknown","latest_version":"9.10.0","update_info":"never updated","message":"installation failed","timestamp":1234567890}` |
| **更新失败** | `{"status":"problem","run":"running","config":{"port":"/dev/ttyUSB0","network_key":"configured","mqtt_enabled":true,"mqtt_host":"127.0.0.1","mqtt_port":1883,"web_port":8091},"install":"success","backup":"success","restore":"success","update":"failed","current_version":"9.9.1","latest_version":"9.10.0","update_info":"FAILED 1 hour ago (9.9.1 -> 9.10.0) service start timeout","message":"recent update failed but service still running on old version","timestamp":1234567890}` |
| **Web界面离线问题** | `{"status":"problem","run":"running","config":{"port":"/dev/ttyUSB0","network_key":"configured","mqtt_enabled":true,"mqtt_host":"127.0.0.1","mqtt_port":1883,"web_port":8091},"install":"success","backup":"success","restore":"success","update":"success","current_version":"9.9.1","latest_version":"9.10.0","update_info":"SUCCESS 2 hours ago (9.9.0 -> 9.9.1)","message":"service running but web interface offline","web_state":"offline","timestamp":1234567890}` |
| **服务可能重启** | `{"status":"problem","run":"running","config":{"port":"/dev/ttyUSB0","network_key":"configured","mqtt_enabled":true,"mqtt_host":"127.0.0.1","mqtt_port":1883,"web_port":8091},"install":"success","backup":"success","restore":"success","update":"success","current_version":"9.9.1","latest_version":"9.10.0","update_info":"SUCCESS 2 hours ago (9.9.0 -> 9.9.1)","message":"service uptime less than interval, possible restart","web_state":"online","timestamp":1234567890}` |

### 9.3 状态字段说明

| 字段名 | 可能值 | 说明 |
|-------|--------|------|
| `status` | `start`, `healthy`, `problem`, `disabled` | 总体健康状态 |
| `run` | `starting`, `stopping`, `running`, `stopped`, `failed`, `disabled` | 运行状态 (对应 start/stop 脚本状态) |
| `config` | JSON对象 或 `{}` | 当前配置信息，服务未安装时为空 |
| `install` | `installing`, `uninstalling`, `success`, `failed` | 安装状态 (对应 install/uninstall 脚本状态) |
| `backup` | `backuping`, `success`, `failed`, `skipped`, `never` | 最近备份状态 (对应 backup 脚本状态) |
| `restore` | `restoring`, `success`, `failed`, `skipped`, `never` | 最近还原状态 (对应 restore 脚本状态) |
| `update` | `updating`, `success`, `failed`, `never` | 最近更新状态 (对应 update 脚本状态) |
| `current_version` | 版本号 或 `unknown` | 当前安装的服务版本 |
| `latest_version` | 版本号 或 `unknown` | 最新可用版本 |
| `update_info` | 更新摘要信息 | 最近更新的详细信息 |
| `message` | 描述性文本 | 当前状态的人性化描述 |
| `web_state` | `online`, `starting`, `offline` | Web界面状态 (仅在相关时显示) |

### 9.4 配置字段说明 (config 对象)

| 字段名 | 可能值 | 说明 |
|-------|--------|------|
| `port` | 串口路径 | Z-Wave 适配器端口，如 "/dev/ttyUSB0" |
| `network_key` | `configured`, `not configured` | 网络安全密钥配置状态 |
| `mqtt_enabled` | `true`, `false` | MQTT 功能是否启用 |
| `mqtt_host` | 主机地址 | MQTT 代理服务器地址 |
| `mqtt_port` | 端口号 | MQTT 代理服务器端口 |
| `web_port` | 端口号 | Web 界面访问端口，通常为 8091 |

### 9.5 状态值含义说明

**`never`**: 表示该操作从未执行过
- `backup: "never"` - 从未执行过备份操作
- `restore: "never"` - 从未执行过还原操作  
- `update: "never"` - 从未执行过更新操作

**`success`**: 最近一次操作成功完成
**`failed`**: 最近一次操作执行失败
**`skipped`**: 最近一次操作被跳过（如备份时服务未运行）
**进行中状态**: `installing`, `updating`, `backuping`, `restoring` 等表示操作正在执行

## 10. 性能监控消息 (autocheck.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/autocheck/zwave-js-ui/performance` | - | `{"cpu":"5.2","mem":"8.1","timestamp":1234567890}` | 性能数据上报 |
| `isg/status/zwave-js-ui/performance` | - | `{"cpu":"5.2","mem":"8.1","timestamp":1234567890}` | 状态性能数据 |

## 11. 版本信息消息 (autocheck.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/autocheck/zwave-js-ui/version` | - | `{"script_version":"1.0.0","latest_script_version":"1.0.0","zwave_version":"9.9.1","latest_zwave_version":"9.10.0","upgrade_dependencies":[]}` | 版本信息上报 |

## 12. 串口检测相关消息 (detect_serial_adapters.py)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/serial/scan` | `running` | `{"status":"running","timestamp":"2025-07-15T12:00:00Z"}` | 开始串口扫描 |
| `isg/serial/scan` | `detecting` | `{"status":"detecting","port":"/dev/ttyUSB0","timestamp":"2025-07-15T12:00:00Z","busy":false}` | 正在检测特定端口 |
| `isg/serial/scan` | `zwave_detected` | `{"status":"zwave_detected","port":"/dev/ttyUSB0","type":"zwave","protocol":"zwave","raw_response":"01030015e9","baudrate":115200,"confidence":"medium","vid":1234,"pid":5678,"timestamp":"2025-07-15T12:00:00Z","busy":false}` | 检测到Z-Wave设备 |
| `isg/serial/scan` | `occupied` | `{"status":"occupied","port":"/dev/ttyUSB0","busy":true,"type":"error","error":"Device busy","timestamp":"2025-07-15T12:00:00Z"}` | 设备被占用 |
| `isg/serial/scan` | `complete` | `{"timestamp":"2025-07-15T12:00:00Z","ports":[{"port":"/dev/ttyUSB0","type":"zwave","protocol":"zwave","baudrate":115200,"confidence":"high","vid":1234,"pid":5678,"busy":false}],"added":[],"removed":[]}` | 扫描完成 |

## 📋 消息总结统计

- **总主题数**: 5个基础主题 (install, run, status, backup, restore, update, autocheck, serial)
- **标准状态值**: 4种核心状态 (installing/starting/restoring/updating, success, failed, skipped)
- **总消息类型数**: 约55种不同消息
- **特殊主题**: performance, version, serial scan 子主题

## 🎯 状态值标准化

所有操作遵循统一的状态模式：
- **进行中**: `installing` / `starting` / `stopping` / `restoring` / `updating` / `backuping` / `uninstalling`
- **成功**: `success` / `running` / `stopped` / `healthy` / `installed` / `uninstalled`
- **失败**: `failed` / `problem`  
- **跳过**: `skipped` / `disabled`

## 🔍 Z-Wave JS UI 特有消息特征

### 与 Zigbee2MQTT 的差异对比

| 特征 | Z-Wave JS UI | Zigbee2MQTT |
|------|-------------|-------------|
| **服务ID** | `zwave-js-ui` | `zigbee2mqtt` |
| **主端口** | 8190 | 8080 |
| **状态检测** | `web_state` (online/starting/offline) | `bridge_state` (online/offline) |
| **配置格式** | JSON (`settings.json`) | YAML (`configuration.yaml`) |
| **安装方式** | pnpm 全局安装 | Git 克隆 + 构建 |
| **存储路径** | `/root/.pnpm-global/.../store` | `/opt/zigbee2mqtt/data` |
| **备份文件名** | `zwave-js-ui_backup_*.tar.gz` | `zigbee2mqtt_backup_*.tar.gz` |
| **设备类型** | Z-Wave dongles | Zigbee adapters |
| **网络密钥** | `network_key` 字段 | 自动生成网络密钥 |

### Z-Wave 特有配置字段

```json
{
  "config": {
    "port": "/dev/ttyUSB0",
    "network_key": "configured",
    "mqtt_enabled": true,
    "mqtt_host": "127.0.0.1", 
    "mqtt_port": 1883,
    "web_port": 8190
  }
}
```

### Z-Wave 特有错误消息

| 错误类型 | 消息示例 |
|---------|---------|
| **pnpm 安装失败** | `"pnpm installation failed"` |
| **pnpm 环境初始化失败** | `"pnpm environment initialization failed"` |
| **Z-Wave JS UI 安装失败** | `"zwave-js-ui installation failed"` |
| **存储目录不存在** | `"store directory not found"` |
| **Web 界面离线** | `"service running but web interface offline"` |
| **Z-Wave 适配器未找到** | `"no zwave adapter found - cannot generate configuration"` |

## 🚀 使用建议

### 监控重点关注的主题

1. **核心服务状态**: `isg/autocheck/zwave-js-ui/status`
2. **实时运行状态**: `isg/status/zwave-js-ui/status`
3. **安装部署状态**: `isg/install/zwave-js-ui/status`
4. **性能监控**: `isg/autocheck/zwave-js-ui/performance`

### 告警触发条件

- `status: "problem"` - 服务存在问题需要关注
- `web_state: "offline"` 且 `run: "running"` - Web界面异常
- `install: "failed"` - 安装失败
- `update: "failed"` - 更新失败
- CPU/内存使用率持续过高

### 自动化建议

- 当检测到 `status: "problem"` 时自动触发重启
- 定期监控 `backup: "success"` 确保数据安全
- 版本更新提醒基于 `current_version` vs `latest_version`
- 串口设备变化监控通过 `isg/serial/scan` 主题

这套 MQTT 消息系统为 Z-Wave JS UI 提供了完整的状态监控和管理能力，与现有的 Zigbee2MQTT 系统保持了良好的一致性和兼容性。

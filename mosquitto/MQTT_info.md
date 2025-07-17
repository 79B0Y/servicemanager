# Mosquitto 服务管理系统 - MQTT 消息上报列表

## 1. 安装相关消息 (install.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/install/mosquitto/status` | `installing` | `{"status":"installing","message":"starting installation process","timestamp":1234567890}` | 开始安装 |
| `isg/install/mosquitto/status` | `installing` | `{"status":"installing","message":"reading service dependencies from serviceupdate.json","timestamp":1234567890}` | 读取服务依赖 |
| `isg/install/mosquitto/status` | `installing` | `{"status":"installing","message":"installing required dependencies","dependencies":[],"timestamp":1234567890}` | 安装依赖包 |
| `isg/install/mosquitto/status` | `installing` | `{"status":"installing","message":"updating package manager","timestamp":1234567890}` | 更新包管理器 |
| `isg/install/mosquitto/status` | `installing` | `{"status":"installing","message":"installing mosquitto package","timestamp":1234567890}` | 安装mosquitto包 |
| `isg/install/mosquitto/status` | `installing` | `{"status":"installing","message":"creating configuration directory","timestamp":1234567890}` | 创建配置目录 |
| `isg/install/mosquitto/status` | `installing` | `{"status":"installing","message":"generating default configuration file","timestamp":1234567890}` | 生成配置文件 |
| `isg/install/mosquitto/status` | `installing` | `{"status":"installing","message":"creating user password file","timestamp":1234567890}` | 创建密码文件 |
| `isg/install/mosquitto/status` | `installing` | `{"status":"installing","message":"creating service monitor directory","timestamp":1234567890}` | 创建服务监控目录 |
| `isg/install/mosquitto/status` | `installing` | `{"status":"installing","message":"starting service for testing","timestamp":1234567890}` | 启动服务测试 |
| `isg/install/mosquitto/status` | `installing` | `{"status":"installing","message":"waiting for service ready","timestamp":1234567890}` | 等待服务就绪 |
| `isg/install/mosquitto/status` | `installing` | `{"status":"installing","message":"recording installation history","version":"2.0.18","timestamp":1234567890}` | 记录安装历史 |
| `isg/install/mosquitto/status` | `installed` | `{"service":"mosquitto","status":"installed","version":"2.0.18","duration":120,"timestamp":1234567890}` | 安装成功 |
| `isg/install/mosquitto/status` | `failed` | `{"status":"failed","message":"dependency installation failed","dependency":"some-package","timestamp":1234567890}` | 依赖安装失败 |
| `isg/install/mosquitto/status` | `failed` | `{"status":"failed","message":"package manager update failed","timestamp":1234567890}` | 包管理器更新失败 |
| `isg/install/mosquitto/status` | `failed` | `{"status":"failed","message":"mosquitto installation failed","timestamp":1234567890}` | mosquitto安装失败 |
| `isg/install/mosquitto/status` | `failed` | `{"status":"failed","message":"service start timeout after installation","timeout":300,"timestamp":1234567890}` | 安装后启动超时 |

## 2. 卸载相关消息 (uninstall.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/install/mosquitto/status` | `uninstalling` | `{"status":"uninstalling","message":"starting uninstall process","timestamp":1234567890}` | 开始卸载 |
| `isg/install/mosquitto/status` | `uninstalling` | `{"status":"uninstalling","message":"stopping service","timestamp":1234567890}` | 停止服务 |
| `isg/install/mosquitto/status` | `uninstalling` | `{"status":"uninstalling","message":"creating final backup","timestamp":1234567890}` | 创建最终备份 |
| `isg/install/mosquitto/status` | `uninstalling` | `{"status":"uninstalling","message":"removing service monitor directory","timestamp":1234567890}` | 删除服务监控目录 |
| `isg/install/mosquitto/status` | `uninstalling` | `{"status":"uninstalling","message":"uninstalling mosquitto package","timestamp":1234567890}` | 卸载mosquitto包 |
| `isg/install/mosquitto/status` | `uninstalling` | `{"status":"uninstalling","message":"cleaning up configuration files","timestamp":1234567890}` | 清理配置文件 |
| `isg/install/mosquitto/status` | `uninstalled` | `{"status":"uninstalled","message":"mosquitto completely removed","timestamp":1234567890}` | 卸载完成 |

## 3. 启动相关消息 (start.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/run/mosquitto/status` | `starting` | `{"service":"mosquitto","status":"starting","message":"starting service","timestamp":1234567890}` | 开始启动 |
| `isg/run/mosquitto/status` | `starting` | `{"service":"mosquitto","status":"starting","message":"removed down file to enable auto-start","timestamp":1234567890}` | 移除down文件 |
| `isg/run/mosquitto/status` | `starting` | `{"service":"mosquitto","status":"starting","message":"waiting for service ready","timestamp":1234567890}` | 等待服务就绪 |
| `isg/run/mosquitto/status` | `success` | `{"service":"mosquitto","status":"success","message":"service started successfully","timestamp":1234567890}` | 启动成功 |
| `isg/run/mosquitto/status` | `failed` | `{"service":"mosquitto","status":"failed","message":"supervise control file not found","timestamp":1234567890}` | 控制文件不存在 |
| `isg/run/mosquitto/status` | `failed` | `{"service":"mosquitto","status":"failed","message":"service failed to reach running state","timeout":150,"timestamp":1234567890}` | 启动超时 |

## 4. 停止相关消息 (stop.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/run/mosquitto/status` | `stopping` | `{"service":"mosquitto","status":"stopping","message":"stopping service","timestamp":1234567890}` | 开始停止 |
| `isg/run/mosquitto/status` | `stopping` | `{"service":"mosquitto","status":"stopping","message":"created down file to disable auto-start","timestamp":1234567890}` | 创建down文件 |
| `isg/run/mosquitto/status` | `stopping` | `{"service":"mosquitto","status":"stopping","message":"waiting for service to stop","timestamp":1234567890}` | 等待服务停止 |
| `isg/run/mosquitto/status` | `success` | `{"service":"mosquitto","status":"success","message":"service stopped and disabled","timestamp":1234567890}` | 停止成功 |
| `isg/run/mosquitto/status` | `failed` | `{"service":"mosquitto","status":"failed","message":"service still running after stop timeout","timeout":150,"timestamp":1234567890}` | 停止失败 |

## 5. 状态查询消息 (status.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/status/mosquitto/status` | `running` | `{"service":"mosquitto","status":"running","pid":1234,"runtime":"1:23:45","port_status":"listening","ws_port_status":"listening","timestamp":1234567890}` | 服务运行中 |
| `isg/status/mosquitto/status` | `starting` | `{"service":"mosquitto","status":"starting","pid":1234,"runtime":"0:01:30","port_status":"closed","ws_port_status":"closed","timestamp":1234567890}` | 服务启动中 |
| `isg/status/mosquitto/status` | `stopped` | `{"service":"mosquitto","status":"stopped","message":"service not running","timestamp":1234567890}` | 服务已停止 |

## 6. 备份相关消息 (backup.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/backup/mosquitto/status` | `backuping` | `{"status":"backuping","message":"starting backup process","timestamp":1234567890}` | 开始备份 |
| `isg/backup/mosquitto/status` | `backuping` | `{"status":"backuping","message":"preparing backup files","timestamp":1234567890}` | 准备备份文件 |
| `isg/backup/mosquitto/status` | `backuping` | `{"status":"backuping","message":"creating archive","timestamp":1234567890}` | 创建压缩包 |
| `isg/backup/mosquitto/status` | `skipped` | `{"status":"skipped","message":"service not running - backup skipped","timestamp":1234567890}` | 服务未运行跳过 |
| `isg/backup/mosquitto/status` | `success` | `{"service":"mosquitto","status":"success","file":"/sdcard/isgbackup/mosquitto/backup.tar.gz","size_kb":1024,"duration":30,"message":"backup completed successfully","timestamp":1234567890}` | 备份成功 |
| `isg/backup/mosquitto/status` | `failed` | `{"status":"failed","message":"tar command failed","timestamp":1234567890}` | 备份失败 |

## 7. 还原相关消息 (restore.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/restore/mosquitto/status` | `restoring` | `{"status":"restoring","method":"latest_backup","file":"mosquitto_backup_20250716.tar.gz"}` | 使用最新备份还原 |
| `isg/restore/mosquitto/status` | `restoring` | `{"status":"restoring","method":"user_specified","file":"/sdcard/Download/my_backup.tar.gz"}` | 用户指定tar.gz文件 |
| `isg/restore/mosquitto/status` | `restoring` | `{"status":"restoring","method":"user_specified","file":"/sdcard/Download/backup.zip","converting_zip":true}` | 用户指定ZIP文件（需转换） |
| `isg/restore/mosquitto/status` | `restoring` | `{"status":"restoring","method":"default_config","timestamp":1234567890}` | 无备份文件，生成默认配置 |
| `isg/restore/mosquitto/status` | `success` | `{"service":"mosquitto","status":"success","method":"latest_backup","file":"mosquitto_backup_20250716.tar.gz","size_kb":1024,"duration":45,"timestamp":1234567890}` | 最新备份还原成功 |
| `isg/restore/mosquitto/status` | `success` | `{"service":"mosquitto","status":"success","method":"user_specified","original_file":"backup.zip","restore_file":"backup.tar.gz","size_kb":1024,"duration":60,"converted_from_zip":true,"timestamp":1234567890}` | 用户指定文件还原成功（含转换） |
| `isg/restore/mosquitto/status` | `success` | `{"service":"mosquitto","status":"success","method":"user_specified","file":"/sdcard/my_backup.tar.gz","size_kb":512,"duration":30,"timestamp":1234567890}` | 用户指定tar.gz还原成功 |
| `isg/restore/mosquitto/status` | `success` | `{"service":"mosquitto","status":"success","method":"default_config","duration":120,"startup_time":30,"timestamp":1234567890}` | 默认配置生成成功 |
| `isg/restore/mosquitto/status` | `failed` | `{"status":"failed","message":"user specified file not found","file":"/sdcard/nonexistent.tar.gz","timestamp":1234567890}` | 用户指定文件不存在 |
| `isg/restore/mosquitto/status` | `failed` | `{"status":"failed","message":"unsupported file format. only .tar.gz and .zip are supported","file":"backup.rar","timestamp":1234567890}` | 不支持的文件格式 |
| `isg/restore/mosquitto/status` | `failed` | `{"status":"failed","message":"failed to extract zip file","timestamp":1234567890}` | ZIP文件解压失败 |
| `isg/restore/mosquitto/status` | `failed` | `{"status":"failed","message":"invalid zip structure","timestamp":1234567890}` | ZIP文件结构无效 |
| `isg/restore/mosquitto/status` | `failed` | `{"status":"failed","message":"failed to create tar.gz from zip","timestamp":1234567890}` | ZIP转tar.gz失败 |
| `isg/restore/mosquitto/status` | `failed` | `{"status":"failed","message":"service failed to start after restore","method":"user_specified","timestamp":1234567890}` | 还原后启动失败 |
| `isg/restore/mosquitto/status` | `failed` | `{"status":"failed","message":"service failed to start after config generation","method":"default_config","timestamp":1234567890}` | 配置生成后启动失败 |
| `isg/restore/mosquitto/status` | `failed` | `{"status":"failed","message":"restore failed - could not extract backup","timestamp":1234567890}` | 备份文件解压失败 |

## 8. 更新相关消息 (update.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/update/mosquitto/status` | `updating` | `{"status":"updating","current_version":"2.0.15","message":"starting update process","timestamp":1234567890}` | 开始更新 |
| `isg/update/mosquitto/status` | `updating` | `{"status":"updating","current_version":"2.0.15","message":"reading upgrade dependencies from serviceupdate.json","timestamp":1234567890}` | 读取升级依赖 |
| `isg/update/mosquitto/status` | `updating` | `{"status":"updating","current_version":"2.0.15","message":"installing upgrade dependencies","dependencies":[],"timestamp":1234567890}` | 安装升级依赖 |
| `isg/update/mosquitto/status` | `updating` | `{"status":"updating","current_version":"2.0.15","message":"backing up current configuration","timestamp":1234567890}` | 备份当前配置 |
| `isg/update/mosquitto/status` | `updating` | `{"status":"updating","current_version":"2.0.15","message":"stopping service","timestamp":1234567890}` | 停止服务 |
| `isg/update/mosquitto/status` | `updating` | `{"status":"updating","current_version":"2.0.15","message":"updating package list","timestamp":1234567890}` | 更新包列表 |
| `isg/update/mosquitto/status` | `updating` | `{"status":"updating","current_version":"2.0.15","message":"upgrading mosquitto","timestamp":1234567890}` | 升级mosquitto |
| `isg/update/mosquitto/status` | `updating` | `{"status":"updating","current_version":"2.0.15","message":"verifying configuration file","timestamp":1234567890}` | 验证配置文件 |
| `isg/update/mosquitto/status` | `updating` | `{"status":"updating","current_version":"2.0.15","message":"starting service","timestamp":1234567890}` | 启动服务 |
| `isg/update/mosquitto/status` | `updating` | `{"status":"updating","current_version":"2.0.15","message":"waiting for service ready","timestamp":1234567890}` | 等待服务就绪 |
| `isg/update/mosquitto/status` | `updating` | `{"status":"updating","old_version":"2.0.15","new_version":"2.0.18","message":"recording update history","timestamp":1234567890}` | 记录更新历史 |
| `isg/update/mosquitto/status` | `success` | `{"service":"mosquitto","status":"success","old_version":"2.0.15","new_version":"2.0.18","duration":180,"timestamp":1234567890}` | 更新成功 |
| `isg/update/mosquitto/status` | `failed` | `{"status":"failed","message":"upgrade dependencies installation failed","dependency":"some-package","current_version":"2.0.15","timestamp":1234567890}` | 升级依赖安装失败 |
| `isg/update/mosquitto/status` | `failed` | `{"status":"failed","message":"package list update failed","current_version":"2.0.15","timestamp":1234567890}` | 包列表更新失败 |
| `isg/update/mosquitto/status` | `failed` | `{"status":"failed","message":"mosquitto upgrade failed","current_version":"2.0.15","timestamp":1234567890}` | mosquitto升级失败 |
| `isg/update/mosquitto/status` | `failed` | `{"status":"failed","message":"failed to get updated version","current_version":"2.0.15","timestamp":1234567890}` | 获取版本失败 |
| `isg/update/mosquitto/status` | `failed` | `{"status":"failed","message":"service start timeout after update","old_version":"2.0.15","new_version":"2.0.18","timeout":300,"timestamp":1234567890}` | 更新后启动超时 |

## 9. 自检相关消息 (autocheck.sh)

### 9.1 自检过程消息

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/autocheck/mosquitto/status` | `start` | `{"status":"start","run":"unknown","config":{},"install":"checking","current_version":"unknown","latest_version":"unknown","update":"checking","message":"starting autocheck process","timestamp":1234567890}` | 开始自检 |
| `isg/autocheck/mosquitto/status` | `recovered` | `{"status":"recovered","message":"service recovered after restart attempts","timestamp":1234567890}` | 服务恢复成功 |

### 9.2 综合状态消息 (汇总所有脚本状态)

| 状态场景 | MQTT 消息内容 |
|---------|--------------|
| **服务被禁用** | `{"status":"disabled","run":"disabled","config":{"port":"1883","bind_address":"0.0.0.0","allow_anonymous":"false","password_file":"/data/data/com.termux/files/usr/etc/mosquitto/passwd","log_dest":"file","persistence":"true"},"install":"success","backup":"success","restore":"success","update":"success","current_version":"2.0.18","latest_version":"2.0.18","update_info":"SUCCESS 2 hours ago (2.0.15 -> 2.0.18)","message":"service is disabled","timestamp":1234567890}` |
| **服务健康运行** | `{"status":"healthy","run":"running","config":{"port":"1883","bind_address":"0.0.0.0","allow_anonymous":"false","password_file":"/data/data/com.termux/files/usr/etc/mosquitto/passwd","log_dest":"file","persistence":"true"},"install":"success","backup":"success","restore":"success","update":"success","current_version":"2.0.18","latest_version":"2.0.18","update_info":"SUCCESS 2 hours ago (2.0.15 -> 2.0.18)","message":"mosquitto running for 2 hours","port_listening":true,"ws_port_listening":true,"config_valid":true,"timestamp":1234567890}` |
| **服务启动中** | `{"status":"healthy","run":"starting","config":{"port":"1883","bind_address":"0.0.0.0","allow_anonymous":"false","password_file":"/data/data/com.termux/files/usr/etc/mosquitto/passwd","log_dest":"file","persistence":"true"},"install":"success","backup":"success","restore":"success","update":"success","current_version":"2.0.18","latest_version":"2.0.18","update_info":"SUCCESS 2 hours ago (2.0.15 -> 2.0.18)","message":"mosquitto starting up","port_listening":false,"ws_port_listening":false,"config_valid":true,"timestamp":1234567890}` |
| **安装进行中** | `{"status":"healthy","run":"running","config":{"port":"1883","bind_address":"0.0.0.0","allow_anonymous":"false","password_file":"/data/data/com.termux/files/usr/etc/mosquitto/passwd","log_dest":"file","persistence":"true"},"install":"installing","backup":"success","restore":"success","update":"success","current_version":"2.0.15","latest_version":"2.0.18","update_info":"SUCCESS 1 day ago (2.0.12 -> 2.0.15)","message":"mosquitto installation in progress","port_listening":true,"ws_port_listening":true,"config_valid":true,"timestamp":1234567890}` |
| **更新进行中** | `{"status":"healthy","run":"running","config":{"port":"1883","bind_address":"0.0.0.0","allow_anonymous":"false","password_file":"/data/data/com.termux/files/usr/etc/mosquitto/passwd","log_dest":"file","persistence":"true"},"install":"success","backup":"success","restore":"success","update":"updating","current_version":"2.0.15","latest_version":"2.0.18","update_info":"UPDATING 2.0.15 -> 2.0.18","message":"mosquitto update in progress","port_listening":true,"ws_port_listening":true,"config_valid":true,"timestamp":1234567890}` |
| **备份进行中** | `{"status":"healthy","run":"running","config":{"port":"1883","bind_address":"0.0.0.0","allow_anonymous":"false","password_file":"/data/data/com.termux/files/usr/etc/mosquitto/passwd","log_dest":"file","persistence":"true"},"install":"success","backup":"backuping","restore":"success","update":"success","current_version":"2.0.18","latest_version":"2.0.18","update_info":"SUCCESS 2 hours ago (2.0.15 -> 2.0.18)","message":"mosquitto backup in progress","port_listening":true,"ws_port_listening":true,"config_valid":true,"timestamp":1234567890}` |
| **还原进行中** | `{"status":"healthy","run":"running","config":{"port":"1883","bind_address":"0.0.0.0","allow_anonymous":"false","password_file":"/data/data/com.termux/files/usr/etc/mosquitto/passwd","log_dest":"file","persistence":"true"},"install":"success","backup":"success","restore":"restoring","update":"success","current_version":"2.0.18","latest_version":"2.0.18","update_info":"SUCCESS 2 hours ago (2.0.15 -> 2.0.18)","message":"mosquitto restore in progress","port_listening":true,"ws_port_listening":true,"config_valid":true,"timestamp":1234567890}` |
| **卸载进行中** | `{"status":"healthy","run":"stopping","config":{},"install":"uninstalling","backup":"success","restore":"success","update":"success","current_version":"2.0.18","latest_version":"2.0.18","update_info":"SUCCESS 2 hours ago (2.0.15 -> 2.0.18)","message":"mosquitto uninstall in progress","port_listening":false,"ws_port_listening":false,"config_valid":false,"timestamp":1234567890}` |
| **服务启动失败** | `{"status":"problem","run":"failed","config":{"port":"1883","bind_address":"0.0.0.0","allow_anonymous":"false","password_file":"/data/data/com.termux/files/usr/etc/mosquitto/passwd","log_dest":"file","persistence":"true"},"install":"success","backup":"success","restore":"success","update":"success","current_version":"2.0.18","latest_version":"2.0.18","update_info":"SUCCESS 2 hours ago (2.0.15 -> 2.0.18)","message":"failed to start service after retries","port_listening":false,"ws_port_listening":false,"config_valid":true,"timestamp":1234567890}` |
| **安装失败** | `{"status":"problem","run":"failed","config":{},"install":"failed","backup":"success","restore":"success","update":"success","current_version":"unknown","latest_version":"2.0.18","update_info":"never updated","message":"installation failed","port_listening":false,"ws_port_listening":false,"config_valid":false,"timestamp":1234567890}` |
| **更新失败** | `{"status":"problem","run":"running","config":{"port":"1883","bind_address":"0.0.0.0","allow_anonymous":"false","password_file":"/data/data/com.termux/files/usr/etc/mosquitto/passwd","log_dest":"file","persistence":"true"},"install":"success","backup":"success","restore":"success","update":"failed","current_version":"2.0.15","latest_version":"2.0.18","update_info":"FAILED 1 hour ago (2.0.15 -> 2.0.18) service start timeout","message":"recent update failed but service still running on old version","port_listening":true,"ws_port_listening":true,"config_valid":true,"timestamp":1234567890}` |
| **端口监听问题** | `{"status":"problem","run":"running","config":{"port":"1883","bind_address":"0.0.0.0","allow_anonymous":"false","password_file":"/data/data/com.termux/files/usr/etc/mosquitto/passwd","log_dest":"file","persistence":"true"},"install":"success","backup":"success","restore":"success","update":"success","current_version":"2.0.18","latest_version":"2.0.18","update_info":"SUCCESS 2 hours ago (2.0.15 -> 2.0.18)","message":"service running but port not listening","port_listening":false,"ws_port_listening":false,"config_valid":true,"timestamp":1234567890}` |
| **配置文件问题** | `{"status":"problem","run":"running","config":{"error":"Config file not found"},"install":"success","backup":"success","restore":"success","update":"success","current_version":"2.0.18","latest_version":"2.0.18","update_info":"SUCCESS 2 hours ago (2.0.15 -> 2.0.18)","message":"service running but config invalid","port_listening":true,"ws_port_listening":true,"config_valid":false,"timestamp":1234567890}` |
| **服务可能重启** | `{"status":"problem","run":"running","config":{"port":"1883","bind_address":"0.0.0.0","allow_anonymous":"false","password_file":"/data/data/com.termux/files/usr/etc/mosquitto/passwd","log_dest":"file","persistence":"true"},"install":"success","backup":"success","restore":"success","update":"success","current_version":"2.0.18","latest_version":"2.0.18","update_info":"SUCCESS 2 hours ago (2.0.15 -> 2.0.18)","message":"service uptime less than interval, possible restart","port_listening":true,"ws_port_listening":true,"config_valid":true,"timestamp":1234567890}` |

### 9.3 状态字段说明

| 字段名 | 可能值 | 说明 |
|-------|--------|------|
| `status` | `start`, `healthy`, `problem`, `disabled` | 总体健康状态 |
| `run` | `starting`, `stopping`, `running`, `stopped`, `failed`, `disabled` | 运行状态 (对应 start/stop 脚本状态) |
| `config` | JSON对象 或 `{}` | 当前配置信息，包含端口、绑定地址等 |
| `install` | `installing`, `uninstalling`, `success`, `failed` | 安装状态 (对应 install/uninstall 脚本状态) |
| `backup` | `backuping`, `success`, `failed`, `skipped`, `never` | 最近备份状态 (对应 backup 脚本状态) |
| `restore` | `restoring`, `success`, `failed`, `skipped`, `never` | 最近还原状态 (对应 restore 脚本状态) |
| `update` | `updating`, `success`, `failed`, `never` | 最近更新状态 (对应 update 脚本状态) |
| `current_version` | 版本号 或 `unknown` | 当前安装的mosquitto版本 |
| `latest_version` | 版本号 或 `unknown` | 最新可用版本 |
| `update_info` | 更新摘要信息 | 最近更新的详细信息 |
| `message` | 描述性文本 | 当前状态的人性化描述 |
| `port_listening` | `true`, `false` | MQTT端口(1883)监听状态 |
| `ws_port_listening` | `true`, `false` | WebSocket端口(9001)监听状态 |
| `config_valid` | `true`, `false` | 配置文件有效性 |

### 9.4 状态值含义说明

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
| `isg/autocheck/mosquitto/performance` | - | `{"cpu":"2.1","mem":"4.5","timestamp":1234567890}` | 性能数据上报 |
| `isg/status/mosquitto/performance` | - | `{"cpu":"2.1","mem":"4.5","timestamp":1234567890}` | 状态性能数据 |

## 11. 版本信息消息 (autocheck.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/autocheck/mosquitto/version` | - | `{"script_version":"1.0.0","latest_script_version":"1.0.0","mosquitto_version":"2.0.18","latest_mosquitto_version":"2.0.18","upgrade_dependencies":[]}` | 版本信息上报 |

## 📋 消息总结统计

- **总主题数**: 4个基础主题 (install, run, status, backup, restore, update, autocheck)
- **标准状态值**: 4种核心状态 (installing/starting/restoring/updating, success, failed, skipped)
- **总消息类型数**: 约55种不同消息
- **特殊主题**: performance, version 子主题

## 🎯 状态值标准化

所有操作遵循统一的状态模式：
- **进行中**: `installing` / `starting` / `stopping` / `restoring` / `updating` / `backuping`
- **成功**: `success` / `running` / `stopped` / `healthy`
- **失败**: `failed` / `problem`  
- **跳过**: `skipped` / `disabled`

## 🔍 Mosquitto特有字段

相比Zigbee2MQTT，Mosquitto服务增加了以下特有监控字段：

### 1. 端口监听状态
- **`port_listening`**: MQTT端口(1883)监听状态
- **`ws_port_listening`**: WebSocket端口(9001)监听状态

### 2. 配置有效性
- **`config_valid`**: 通过 `mosquitto -c config -t` 验证配置文件有效性

### 3. 配置信息详细字段
- **`port`**: 监听端口
- **`bind_address`**: 绑定地址
- **`allow_anonymous`**: 是否允许匿名访问
- **`password_file`**: 密码文件路径
- **`log_dest`**: 日志输出目标
- **`persistence`**: 是否启用持久化

## 🚀 性能特点

- **轻量级监控**: Mosquitto相比Zigbee2MQTT资源占用更低
- **双端口监控**: 同时监控MQTT和WebSocket端口
- **配置验证**: 实时验证配置文件语法正确性
- **多格式备份**: 支持tar.gz和zip格式的备份还原

## 📊 与Zigbee2MQTT消息体系的对比

### 相同点
1. **消息结构**: 完全相同的JSON格式和字段命名规范
2. **状态流转**: 相同的 installing→success→failed 状态机制
3. **操作分类**: 相同的 install/run/status/backup/restore/update/autocheck 分类
4. **时间戳**: 统一的 timestamp 字段格式

### 差异点
1. **桥接状态**: Mosquitto无需 `bridge_state` 字段
2. **端口监控**: 增加 `port_listening` 和 `ws_port_listening` 字段
3. **配置验证**: 增加 `config_valid` 字段
4. **设备检测**: 无需串口设备相关的消息和字段

## 🔄 消息流转示例

### 正常安装流程
```
isg/install/mosquitto/status: {"status":"installing","message":"starting installation process"}
↓
isg/install/mosquitto/status: {"status":"installing","message":"updating package manager"}
↓
isg/install/mosquitto/status: {"status":"installing","message":"installing mosquitto package"}
↓
isg/install/mosquitto/status: {"status":"installing","message":"generating default configuration file"}
↓
isg/install/mosquitto/status: {"status":"installing","message":"starting service for testing"}
↓
isg/install/mosquitto/status: {"service":"mosquitto","status":"installed","version":"2.0.18","duration":120}
```

### 健康检查流程
```
isg/autocheck/mosquitto/status: {"status":"start","run":"unknown","install":"checking"}
↓
isg/autocheck/mosquitto/performance: {"cpu":"2.1","mem":"4.5"}
↓
isg/autocheck/mosquitto/version: {"script_version":"1.0.0","mosquitto_version":"2.0.18"}
↓
isg/autocheck/mosquitto/status: {"status":"healthy","run":"running","port_listening":true,"ws_port_listening":true,"config_valid":true}
```

### 故障恢复流程
```
isg/autocheck/mosquitto/status: {"status":"problem","run":"stopped","port_listening":false}
↓
isg/run/mosquitto/status: {"service":"mosquitto","status":"starting","message":"starting service"}
↓
isg/autocheck/mosquitto/status: {"status":"recovered","message":"service recovered after restart attempts"}
↓
isg/autocheck/mosquitto/status: {"status":"healthy","run":"running","port_listening":true}
```

## 🎯 使用场景示例

### 监控仪表板集成
```javascript
// 监听Mosquitto服务状态
mqtt.subscribe('isg/autocheck/mosquitto/status', (message) => {
  const status = JSON.parse(message);
  updateDashboard({
    service: 'mosquitto',
    health: status.status,
    running: status.run === 'running',
    mqttPort: status.port_listening,
    wsPort: status.ws_port_listening,
    configValid: status.config_valid,
    version: status.current_version
  });
});
```

### 自动化运维集成
```bash
# 检查服务健康状态并自动恢复
if [[ $(mosquitto_sub -t "isg/autocheck/mosquitto/status" -C 1 | jq -r '.status') == "problem" ]]; then
  # 触发服务重启
  bash /data/data/com.termux/files/home/servicemanager/mosquitto/start.sh
fi
```

### 告警集成
```yaml
# Prometheus AlertManager 规则示例
- alert: MosquittoServiceDown
  expr: mosquitto_port_listening == 0
  labels:
    severity: critical
    service: mosquitto
  annotations:
    summary: "Mosquitto MQTT服务端口未监听"
    description: "Mosquitto服务的1883端口未正常监听，可能影响MQTT通信"
```

## 📈 消息频率和数据量估算

### 正常运行时
- **autocheck.sh**: 每5-10分钟执行一次，产生3条消息（status + performance + version）
- **status.sh**: 按需调用，每次1条消息
- **性能数据**: 约50字节/条
- **状态数据**: 约500-1000字节/条

### 操作执行时
- **install.sh**: 约10-15条消息，总计约2KB
- **update.sh**: 约12-18条消息，总计约3KB  
- **backup.sh**: 约5-8条消息，总计约1KB
- **restore.sh**: 约8-12条消息，总计约2KB

### 每日数据量估算
- **正常监控**: ~288条消息/天 × 500字节 ≈ 144KB/天
- **包含操作**: +操作消息 ≈ 额外10-20KB/次操作
- **总计**: 通常 < 200KB/天/服务

这个完整的MQTT消息体系为Mosquitto服务提供了全面的状态监控和操作跟踪能力，确保了与现有servicemanager体系的完美集成。
# Zigbee2MQTT 服务管理系统 - MQTT 消息上报列表

## 1. 安装相关消息 (install.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/install/zigbee2mqtt/status` | `installing` | `{"status":"installing","message":"starting installation process","timestamp":1234567890}` | 开始安装 |
| `isg/install/zigbee2mqtt/status` | `installing` | `{"status":"installing","message":"reading service dependencies from serviceupdate.json","timestamp":1234567890}` | 读取服务依赖 |
| `isg/install/zigbee2mqtt/status` | `installing` | `{"status":"installing","message":"installing required dependencies","dependencies":["nodejs","git","make","g++","gcc","libsystemd-dev"],"timestamp":1234567890}` | 安装依赖包 |
| `isg/install/zigbee2mqtt/status` | `installing` | `{"status":"installing","message":"installing system dependencies","timestamp":1234567890}` | 安装系统依赖 |
| `isg/install/zigbee2mqtt/status` | `installing` | `{"status":"installing","message":"installing pnpm package manager","timestamp":1234567890}` | 安装pnpm |
| `isg/install/zigbee2mqtt/status` | `installing` | `{"status":"installing","message":"downloading source code","timestamp":1234567890}` | 下载源码 |
| `isg/install/zigbee2mqtt/status` | `installing` | `{"status":"installing","message":"building zigbee2mqtt application","timestamp":1234567890}` | 构建应用 |
| `isg/install/zigbee2mqtt/status` | `installing` | `{"status":"installing","message":"creating data directory","timestamp":1234567890}` | 创建数据目录 |
| `isg/install/zigbee2mqtt/status` | `installing` | `{"status":"installing","message":"generating initial configuration","timestamp":1234567890}` | 生成配置 |
| `isg/install/zigbee2mqtt/status` | `installing` | `{"status":"installing","message":"starting service for testing","timestamp":1234567890}` | 启动服务测试 |
| `isg/install/zigbee2mqtt/status` | `installing` | `{"status":"installing","message":"waiting for service ready","timestamp":1234567890}` | 等待服务就绪 |
| `isg/install/zigbee2mqtt/status` | `installing` | `{"status":"installing","message":"recording installation history","version":"2.5.1","timestamp":1234567890}` | 记录安装历史 |
| `isg/install/zigbee2mqtt/status` | `installed` | `{"service":"zigbee2mqtt","status":"installed","version":"2.5.1","duration":120,"timestamp":1234567890}` | 安装成功 |
| `isg/install/zigbee2mqtt/status` | `failed` | `{"status":"failed","message":"failed to read serviceupdate.json","timestamp":1234567890}` | 读取依赖配置失败 |
| `isg/install/zigbee2mqtt/status` | `failed` | `{"status":"failed","message":"dependency installation failed","dependencies":["nodejs","git"],"timestamp":1234567890}` | 依赖安装失败 |
| `isg/install/zigbee2mqtt/status` | `failed` | `{"status":"failed","message":"service start timeout after installation","timeout":120,"timestamp":1234567890}` | 安装后启动超时 |

## 2. 卸载相关消息 (uninstall.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/install/zigbee2mqtt/status` | `uninstalling` | `{"status":"uninstalling","message":"starting uninstall process","timestamp":1234567890}` | 开始卸载 |
| `isg/install/zigbee2mqtt/status` | `uninstalling` | `{"status":"uninstalling","message":"stopping service","timestamp":1234567890}` | 停止服务 |
| `isg/install/zigbee2mqtt/status` | `uninstalling` | `{"status":"uninstalling","message":"removing installation directory","timestamp":1234567890}` | 删除安装目录 |
| `isg/install/zigbee2mqtt/status` | `uninstalled` | `{"status":"uninstalled","message":"zigbee2mqtt completely removed","timestamp":1234567890}` | 卸载完成 |

## 3. 启动相关消息 (start.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/run/zigbee2mqtt/status` | `starting` | `{"service":"zigbee2mqtt","status":"starting","message":"starting service","timestamp":1234567890}` | 开始启动 |
| `isg/run/zigbee2mqtt/status` | `starting` | `{"service":"zigbee2mqtt","status":"starting","message":"removed down file to enable auto-start","timestamp":1234567890}` | 移除down文件 |
| `isg/run/zigbee2mqtt/status` | `starting` | `{"service":"zigbee2mqtt","status":"starting","message":"waiting for service ready","timestamp":1234567890}` | 等待服务就绪 |
| `isg/run/zigbee2mqtt/status` | `success` | `{"service":"zigbee2mqtt","status":"success","message":"service started successfully","timestamp":1234567890}` | 启动成功 |
| `isg/run/zigbee2mqtt/status` | `failed` | `{"service":"zigbee2mqtt","status":"failed","message":"supervise control file not found","timestamp":1234567890}` | 控制文件不存在 |
| `isg/run/zigbee2mqtt/status` | `failed` | `{"service":"zigbee2mqtt","status":"failed","message":"service failed to reach running state","timeout":150,"timestamp":1234567890}` | 启动超时 |

## 4. 停止相关消息 (stop.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/run/zigbee2mqtt/status` | `stopping` | `{"service":"zigbee2mqtt","status":"stopping","message":"stopping service","timestamp":1234567890}` | 开始停止 |
| `isg/run/zigbee2mqtt/status` | `stopping` | `{"service":"zigbee2mqtt","status":"stopping","message":"created down file to disable auto-start","timestamp":1234567890}` | 创建down文件 |
| `isg/run/zigbee2mqtt/status` | `stopping` | `{"service":"zigbee2mqtt","status":"stopping","message":"waiting for service to stop","timestamp":1234567890}` | 等待服务停止 |
| `isg/run/zigbee2mqtt/status` | `success` | `{"service":"zigbee2mqtt","status":"success","message":"service stopped and disabled","timestamp":1234567890}` | 停止成功 |
| `isg/run/zigbee2mqtt/status` | `failed` | `{"service":"zigbee2mqtt","status":"failed","message":"service still running after stop timeout","timeout":150,"timestamp":1234567890}` | 停止失败 |

## 5. 状态查询消息 (status.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/status/zigbee2mqtt/status` | `running` | `{"service":"zigbee2mqtt","status":"running","pid":1234,"runtime":"1:23:45","bridge_state":"online","timestamp":1234567890}` | 服务运行中 |
| `isg/status/zigbee2mqtt/status` | `starting` | `{"service":"zigbee2mqtt","status":"starting","pid":1234,"runtime":"0:01:30","bridge_state":"offline","timestamp":1234567890}` | 服务启动中 |
| `isg/status/zigbee2mqtt/status` | `stopped` | `{"service":"zigbee2mqtt","status":"stopped","message":"service not running","timestamp":1234567890}` | 服务已停止 |

## 6. 备份相关消息 (backup.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/backup/zigbee2mqtt/status` | `backuping` | `{"status":"backuping","message":"starting backup process","timestamp":1234567890}` | 开始备份 |
| `isg/backup/zigbee2mqtt/status` | `backuping` | `{"status":"backuping","message":"creating archive","timestamp":1234567890}` | 创建压缩包 |
| `isg/backup/zigbee2mqtt/status` | `skipped` | `{"status":"skipped","message":"service not running - backup skipped","timestamp":1234567890}` | 服务未运行跳过 |
| `isg/backup/zigbee2mqtt/status` | `success` | `{"service":"zigbee2mqtt","status":"success","file":"/sdcard/isgbackup/zigbee2mqtt/backup.tar.gz","size_kb":1024,"duration":30,"message":"backup completed successfully","timestamp":1234567890}` | 备份成功 |
| `isg/backup/zigbee2mqtt/status` | `failed` | `{"status":"failed","message":"tar command failed inside container","timestamp":1234567890}` | 备份失败 |

## 7. 还原相关消息 (restore.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/restore/zigbee2mqtt/status` | `restoring` | `{"status":"restoring","method":"latest_backup","file":"zigbee2mqtt_backup_20250713.tar.gz"}` | 使用最新备份文件还原 |
| `isg/restore/zigbee2mqtt/status` | `restoring` | `{"status":"restoring","method":"user_specified","file":"/sdcard/Download/my_backup.tar.gz"}` | 用户指定tar.gz文件 |
| `isg/restore/zigbee2mqtt/status` | `restoring` | `{"status":"restoring","method":"user_specified","file":"/sdcard/Download/backup.zip","converting_zip":true}` | 用户指定ZIP文件（需转换） |
| `isg/restore/zigbee2mqtt/status` | `restoring` | `{"status":"restoring","method":"default_config","zigbee_devices_found":1}` | 无备份文件，生成默认配置 |
| `isg/restore/zigbee2mqtt/status` | `success` | `{"service":"zigbee2mqtt","status":"success","method":"latest_backup","file":"zigbee2mqtt_backup_20250713.tar.gz","size_kb":1024,"duration":45,"timestamp":1234567890}` | 最新备份还原成功 |
| `isg/restore/zigbee2mqtt/status` | `success` | `{"service":"zigbee2mqtt","status":"success","method":"user_specified","original_file":"backup.zip","restore_file":"backup.tar.gz","size_kb":1024,"duration":60,"converted_from_zip":true,"timestamp":1234567890}` | 用户指定文件还原成功（含转换） |
| `isg/restore/zigbee2mqtt/status` | `success` | `{"service":"zigbee2mqtt","status":"success","method":"user_specified","file":"/sdcard/my_backup.tar.gz","size_kb":512,"duration":30,"timestamp":1234567890}` | 用户指定tar.gz还原成功 |
| `isg/restore/zigbee2mqtt/status` | `success` | `{"service":"zigbee2mqtt","status":"success","method":"default_config","zigbee_devices_found":1,"duration":120,"startup_time":30,"timestamp":1234567890}` | 默认配置生成成功 |
| `isg/restore/zigbee2mqtt/status` | `skipped` | `{"status":"skipped","message":"No Zigbee adapter found - cannot generate configuration","zigbee_devices_detected":0}` | 无Zigbee适配器跳过 |
| `isg/restore/zigbee2mqtt/status` | `skipped` | `{"status":"skipped","message":"No backup file found and no Zigbee adapter detected"}` | 无备份且无适配器跳过 |
| `isg/restore/zigbee2mqtt/status` | `failed` | `{"status":"failed","message":"User specified file not found","file":"/sdcard/nonexistent.tar.gz","timestamp":1234567890}` | 用户指定文件不存在 |
| `isg/restore/zigbee2mqtt/status` | `failed` | `{"status":"failed","message":"Serial detection script not found","timestamp":1234567890}` | 检测脚本不存在 |
| `isg/restore/zigbee2mqtt/status` | `failed` | `{"status":"failed","message":"Unsupported file format. Only .tar.gz and .zip are supported","file":"backup.rar","timestamp":1234567890}` | 不支持的文件格式 |
| `isg/restore/zigbee2mqtt/status` | `failed` | `{"status":"failed","message":"Service failed to start after restore","method":"user_specified","timestamp":1234567890}` | 还原后启动失败 |
| `isg/restore/zigbee2mqtt/status` | `failed` | `{"status":"failed","message":"Service failed to start after config generation","method":"default_config","timestamp":1234567890}` | 配置生成后启动失败 |

## 8. 更新相关消息 (update.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/update/zigbee2mqtt/status` | `updating` | `{"status":"updating","current_version":"2.5.0","message":"starting update process","timestamp":1234567890}` | 开始更新 |
| `isg/update/zigbee2mqtt/status` | `updating` | `{"status":"updating","current_version":"2.5.0","message":"reading upgrade dependencies from serviceupdate.json","timestamp":1234567890}` | 读取升级依赖 |
| `isg/update/zigbee2mqtt/status` | `updating` | `{"status":"updating","current_version":"2.5.0","message":"installing upgrade dependencies","dependencies":["mqtt==2.0.0","axios@1.6.0"],"timestamp":1234567890}` | 安装升级依赖 |
| `isg/update/zigbee2mqtt/status` | `updating` | `{"status":"updating","current_version":"2.5.0","message":"stopping service","timestamp":1234567890}` | 停止服务 |
| `isg/update/zigbee2mqtt/status` | `updating` | `{"status":"updating","current_version":"2.5.0","message":"git pull","timestamp":1234567890}` | Git拉取代码 |
| `isg/update/zigbee2mqtt/status` | `updating` | `{"status":"updating","current_version":"2.5.0","message":"installing dependencies","timestamp":1234567890}` | 安装依赖 |
| `isg/update/zigbee2mqtt/status` | `updating` | `{"status":"updating","current_version":"2.5.0","message":"building application","timestamp":1234567890}` | 构建应用 |
| `isg/update/zigbee2mqtt/status` | `updating` | `{"status":"updating","current_version":"2.5.0","message":"starting service","timestamp":1234567890}` | 启动服务 |
| `isg/update/zigbee2mqtt/status` | `updating` | `{"status":"updating","current_version":"2.5.0","message":"waiting for service ready","timestamp":1234567890}` | 等待服务就绪 |
| `isg/update/zigbee2mqtt/status` | `updating` | `{"status":"updating","old_version":"2.5.0","new_version":"2.5.1","message":"recording update history","timestamp":1234567890}` | 记录更新历史 |
| `isg/update/zigbee2mqtt/status` | `success` | `{"service":"zigbee2mqtt","status":"success","old_version":"2.5.0","new_version":"2.5.1","duration":180,"timestamp":1234567890}` | 更新成功 |
| `isg/update/zigbee2mqtt/status` | `failed` | `{"status":"failed","message":"failed to read serviceupdate.json","current_version":"2.5.0","timestamp":1234567890}` | 读取升级配置失败 |
| `isg/update/zigbee2mqtt/status` | `failed` | `{"status":"failed","message":"upgrade dependencies installation failed","dependencies":["mqtt==2.0.0"],"current_version":"2.5.0","timestamp":1234567890}` | 升级依赖安装失败 |
| `isg/update/zigbee2mqtt/status` | `failed` | `{"status":"failed","message":"failed to get updated version","current_version":"2.5.0","timestamp":1234567890}` | 获取版本失败 |
| `isg/update/zigbee2mqtt/status` | `failed` | `{"status":"failed","message":"git pull failed","current_version":"2.5.0","timestamp":1234567890}` | Git拉取失败 |
| `isg/update/zigbee2mqtt/status` | `failed` | `{"status":"failed","message":"dependency installation failed","current_version":"2.5.0","timestamp":1234567890}` | 依赖安装失败 |
| `isg/update/zigbee2mqtt/status` | `failed` | `{"status":"failed","message":"build failed","current_version":"2.5.0","timestamp":1234567890}` | 构建失败 |
| `isg/update/zigbee2mqtt/status` | `failed` | `{"status":"failed","message":"service start timeout after update","old_version":"2.5.0","new_version":"2.5.1","timeout":300,"timestamp":1234567890}` | 更新后启动超时 |

## 9. 自检相关消息 (autocheck.sh)

### 9.1 自检过程消息

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/autocheck/zigbee2mqtt/status` | `start` | `{"status":"start","run":"unknown","config":{},"install":"checking","current_version":"unknown","latest_version":"unknown","update":"checking","message":"starting autocheck process","timestamp":1234567890}` | 开始自检 |
| `isg/autocheck/zigbee2mqtt/status` | `recovered` | `{"status":"recovered","message":"service recovered after restart attempts","timestamp":1234567890}` | 服务恢复成功 |

### 9.2 综合状态消息 (汇总所有脚本状态)

| 状态场景 | MQTT 消息内容 |
|---------|--------------|
| **服务被禁用** | `{"status":"disabled","run":"disabled","config":{"base_topic":"zigbee2mqtt","password":"admin","server":"mqtt://127.0.0.1:1883","user":"admin","adapter":"ezsp","baudrate":"115200","port":"/dev/ttyAS3"},"install":"success","backup":"success","restore":"success","update":"success","current_version":"2.5.1","latest_version":"2.5.1","update_info":"SUCCESS 2 hours ago (2.5.0 -> 2.5.1)","message":"service is disabled","timestamp":1234567890}` |
| **服务健康运行** | `{"status":"healthy","run":"success","config":{"base_topic":"zigbee2mqtt","password":"admin","server":"mqtt://127.0.0.1:1883","user":"admin","adapter":"ezsp","baudrate":"115200","port":"/dev/ttyAS3"},"install":"success","backup":"success","restore":"success","update":"success","current_version":"2.5.1","latest_version":"2.5.1","update_info":"SUCCESS 2 hours ago (2.5.0 -> 2.5.1)","message":"zigbee2mqtt running for 2 hours","bridge_state":"online","timestamp":1234567890}` |
| **服务启动中** | `{"status":"healthy","run":"starting","config":{"base_topic":"zigbee2mqtt","password":"admin","server":"mqtt://127.0.0.1:1883","user":"admin","adapter":"ezsp","baudrate":"115200","port":"/dev/ttyAS3"},"install":"success","backup":"success","restore":"success","update":"success","current_version":"2.5.1","latest_version":"2.5.1","update_info":"SUCCESS 2 hours ago (2.5.0 -> 2.5.1)","message":"zigbee2mqtt starting up","bridge_state":"offline","timestamp":1234567890}` |
| **安装进行中** | `{"status":"healthy","run":"success","config":{"base_topic":"zigbee2mqtt","password":"admin","server":"mqtt://127.0.0.1:1883","user":"admin","adapter":"ezsp","baudrate":"115200","port":"/dev/ttyAS3"},"install":"installing","backup":"success","restore":"success","update":"success","current_version":"2.5.0","latest_version":"2.5.1","update_info":"SUCCESS 1 day ago (2.4.9 -> 2.5.0)","message":"zigbee2mqtt installation in progress","timestamp":1234567890}` |
| **更新进行中** | `{"status":"healthy","run":"success","config":{"base_topic":"zigbee2mqtt","password":"admin","server":"mqtt://127.0.0.1:1883","user":"admin","adapter":"ezsp","baudrate":"115200","port":"/dev/ttyAS3"},"install":"success","backup":"success","restore":"success","update":"updating","current_version":"2.5.0","latest_version":"2.5.1","update_info":"UPDATING 2.5.0 -> 2.5.1","message":"zigbee2mqtt update in progress","timestamp":1234567890}` |
| **备份进行中** | `{"status":"healthy","run":"success","config":{"base_topic":"zigbee2mqtt","password":"admin","server":"mqtt://127.0.0.1:1883","user":"admin","adapter":"ezsp","baudrate":"115200","port":"/dev/ttyAS3"},"install":"success","backup":"backuping","restore":"success","update":"success","current_version":"2.5.1","latest_version":"2.5.1","update_info":"SUCCESS 2 hours ago (2.5.0 -> 2.5.1)","message":"zigbee2mqtt backup in progress","timestamp":1234567890}` |
| **还原进行中** | `{"status":"healthy","run":"success","config":{"base_topic":"zigbee2mqtt","password":"admin","server":"mqtt://127.0.0.1:1883","user":"admin","adapter":"ezsp","baudrate":"115200","port":"/dev/ttyAS3"},"install":"success","backup":"success","restore":"restoring","update":"success","current_version":"2.5.1","latest_version":"2.5.1","update_info":"SUCCESS 2 hours ago (2.5.0 -> 2.5.1)","message":"zigbee2mqtt restore in progress","timestamp":1234567890}` |
| **卸载进行中** | `{"status":"healthy","run":"stopping","config":{},"install":"uninstalling","backup":"success","restore":"success","update":"success","current_version":"2.5.1","latest_version":"2.5.1","update_info":"SUCCESS 2 hours ago (2.5.0 -> 2.5.1)","message":"zigbee2mqtt uninstall in progress","timestamp":1234567890}` |
| **服务启动失败** | `{"status":"problem","run":"failed","config":{"base_topic":"zigbee2mqtt","password":"admin","server":"mqtt://127.0.0.1:1883","user":"admin","adapter":"ezsp","baudrate":"115200","port":"/dev/ttyAS3"},"install":"success","backup":"success","restore":"success","update":"success","current_version":"2.5.1","latest_version":"2.5.1","update_info":"SUCCESS 2 hours ago (2.5.0 -> 2.5.1)","message":"failed to start service after retries","timestamp":1234567890}` |
| **安装失败** | `{"status":"problem","run":"failed","config":{},"install":"failed","backup":"success","restore":"success","update":"success","current_version":"unknown","latest_version":"2.5.1","update_info":"never updated","message":"installation failed","timestamp":1234567890}` |
| **更新失败** | `{"status":"problem","run":"success","config":{"base_topic":"zigbee2mqtt","password":"admin","server":"mqtt://127.0.0.1:1883","user":"admin","adapter":"ezsp","baudrate":"115200","port":"/dev/ttyAS3"},"install":"success","backup":"success","restore":"success","update":"failed","current_version":"2.5.0","latest_version":"2.5.1","update_info":"FAILED 1 hour ago (2.5.0 -> 2.5.1) service start timeout","message":"recent update failed but service still running on old version","timestamp":1234567890}` |
| **桥接离线问题** | `{"status":"problem","run":"success","config":{"base_topic":"zigbee2mqtt","password":"admin","server":"mqtt://127.0.0.1:1883","user":"admin","adapter":"ezsp","baudrate":"115200","port":"/dev/ttyAS3"},"install":"success","backup":"success","restore":"success","update":"success","current_version":"2.5.1","latest_version":"2.5.1","update_info":"SUCCESS 2 hours ago (2.5.0 -> 2.5.1)","message":"service running but bridge offline","bridge_state":"offline","timestamp":1234567890}` |
| **服务可能重启** | `{"status":"problem","run":"success","config":{"base_topic":"zigbee2mqtt","password":"admin","server":"mqtt://127.0.0.1:1883","user":"admin","adapter":"ezsp","baudrate":"115200","port":"/dev/ttyAS3"},"install":"success","backup":"success","restore":"success","update":"success","current_version":"2.5.1","latest_version":"2.5.1","update_info":"SUCCESS 2 hours ago (2.5.0 -> 2.5.1)","message":"service uptime less than interval, possible restart","bridge_state":"online","timestamp":1234567890}` |

### 9.3 状态字段说明

| 字段名 | 可能值 | 说明 |
|-------|--------|------|
| `status` | `start`, `healthy`, `problem`, `disabled` | 总体健康状态 |
| `run` | `starting`, `stopping`, `success`, `failed`, `disabled` | 运行状态 (对应 start/stop 脚本状态) |
| `config` | JSON对象 或 `{}` | 当前配置信息，服务未安装时为空 |
| `install` | `installing`, `uninstalling`, `success`, `failed` | 安装状态 (对应 install/uninstall 脚本状态) |
| `backup` | `backuping`, `success`, `failed`, `skipped`, `never` | 最近备份状态 (对应 backup 脚本状态) |
| `restore` | `restoring`, `success`, `failed`, `skipped`, `never` | 最近还原状态 (对应 restore 脚本状态) |
| `update` | `updating`, `success`, `failed`, `never` | 最近更新状态 (对应 update 脚本状态) |
| `current_version` | 版本号 或 `unknown` | 当前安装的服务版本 |
| `latest_version` | 版本号 或 `unknown` | 最新可用版本 |
| `update_info` | 更新摘要信息 | 最近更新的详细信息 |
| `message` | 描述性文本 | 当前状态的人性化描述 |
| `bridge_state` | `online`, `offline` | MQTT桥接状态 (仅在相关时显示) |

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
| `isg/autocheck/zigbee2mqtt/performance` | - | `{"cpu":"5.2","mem":"8.1","timestamp":1234567890}` | 性能数据上报 |
| `isg/status/zigbee2mqtt/performance` | - | `{"cpu":"5.2","mem":"8.1","timestamp":1234567890}` | 状态性能数据 |

## 11. 版本信息消息 (autocheck.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/autocheck/zigbee2mqtt/version` | - | `{"script_version":"1.1.0","latest_script_version":"1.1.0","z2m_version":"2.5.1","latest_z2m_version":"2.5.1","upgrade_dependencies":["mqtt==2.0.0"]}` | 版本信息上报 |

## 📋 消息总结统计

- **总主题数**: 4个基础主题 (install, run, status, backup, restore, update, autocheck)
- **标准状态值**: 4种核心状态 (installing/starting/restoring/updating, success, failed, skipped)
- **总消息类型数**: 约45种不同消息
- **特殊主题**: performance, version 子主题

## 🎯 状态值标准化

所有操作遵循统一的状态模式：
- **进行中**: `installing` / `starting` / `stopping` / `restoring` / `updating` / `backuping`
- **成功**: `success` / `running` / `stopped` / `healthy`
- **失败**: `failed` / `problem`  
- **跳过**: `skipped` / `disabled`

## 🔍 可能遗漏的消息

根据最佳实践，建议补充以下消息：

1. **系统级消息** (autocheckall.sh相关)
   - `isg/system/runit/status` - runit系统状态
   - `isg/system/isgservicemonitor/status` - 监控程序状态
   - `isg/status/versions` - 全局版本汇总

2. **串口检测消息** (detect_serial_adapters.py相关)
   - `isg/serial/scan` - 串口扫描状态和结果

3. **错误恢复消息**
   - `isg/recovery/zigbee2mqtt/status` - 自动恢复操作状态

4. **配置变更消息**
   - `isg/config/zigbee2mqtt/status` - 配置文件修改状态

你觉得是否需要补充这些消息？

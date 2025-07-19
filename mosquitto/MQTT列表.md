# Mosquitto 服务 MQTT 消息字段表

## 主状态消息: `isg/autocheck/mosquitto/status`

| 字段名 | 可能值 | 说明 |
|-------|--------|------|
| `status` | `start`, `healthy`, `problem`, `disabled`, `credentials_updated`, `credentials_synced` | 总体健康状态 |
| `run` | `starting`, `stopping`, `running`, `stopped`, `failed`, `disabled` | 运行状态 |
| `install` | `installing`, `uninstalling`, `success`, `failed` | 安装状态 |
| `backup` | `backuping`, `success`, `failed`, `never` | 备份状态 |
| `restore` | `restoring`, `success`, `never` | 还原状态 |
| `update` | `updating`, `success`, `failed`, `never` | 更新状态 |
| `current_version` | 版本号 或 `unknown` | 当前 Mosquitto 版本 |
| `latest_version` | 版本号 或 `unknown` | 最新可用版本 |
| `connectivity` | `connected`, `auth_failed`, `offline`, `unknown` | MQTT 连接状态 |
| `message` | 描述文本 | 状态描述，如 "mosquitto running for 2 hours" |
| `config` | JSON对象 | 配置信息（端口、用户、认证等） |
| `restart_detected` | `true`, `false` | 是否检测到重启 |
| `credentials_consistent` | `true`, `false` | 凭据一致性 |
| `credentials_updated` | `true`, `false` | 凭据是否更新 |
| `update_info` | 文本描述 | 更新历史，如 "SUCCESS 3 hours ago (2.0.15 -> 2.0.18)" |
| `timestamp` | Unix时间戳 | 消息时间 |

## 性能监控: `isg/autocheck/mosquitto/performance`

| 字段名 | 可能值 | 说明 |
|-------|--------|------|
| `cpu` | 百分比数字 | CPU 使用率 |
| `mem` | 百分比数字 | 内存使用率 |
| `timestamp` | Unix时间戳 | 采集时间 |

## 版本信息: `isg/autocheck/mosquitto/version`

| 字段名 | 可能值 | 说明 |
|-------|--------|------|
| `script_version` | 版本号 | 脚本版本 |
| `latest_script_version` | 版本号 | 最新脚本版本 |
| `mosquitto_version` | 版本号 | Mosquitto 版本 |
| `latest_mosquitto_version` | 版本号 | 最新 Mosquitto 版本 |
| `upgrade_dependencies` | JSON数组 | 升级依赖包 |

## 其他操作消息主题

### 服务控制: `isg/run/mosquitto/status`
- `status`: `starting`, `stopping`, `success`, `failed`
- `message`: 操作描述

### 安装管理: `isg/install/mosquitto/status`  
- `status`: `installing`, `uninstalling`, `installed`, `uninstalled`, `failed`
- `version`: 安装版本
- `duration`: 操作耗时

### 备份操作: `isg/backup/mosquitto/status`
- `status`: `backuping`, `success`, `failed`, `skipped`
- `file`: 备份文件名
- `size_kb`: 文件大小

### 还原操作: `isg/restore/mosquitto/status`
- `status`: `restoring`, `success`, `failed`
- `method`: `latest_backup`, `user_specified`, `default_config`
- `file`: 还原文件名

### 更新操作: `isg/update/mosquitto/status`
- `status`: `updating`, `success`, `failed`
- `old_version`: 更新前版本
- `new_version`: 更新后版本
- `duration`: 更新耗时

### 状态查询: `isg/status/mosquitto/status`
- `status`: `running`, `starting`, `stopped`
- `pid`: 进程ID
- `runtime`: 运行时间
- `port_status`: `listening_global`, `listening_local`, `not_listening`

## config 对象结构

| 字段 | 说明 |
|------|------|
| `bind_address` | 监听地址 (0.0.0.0 或 127.0.0.1) |
| `port` | MQTT 端口 (默认 1883) |
| `allow_anonymous` | 是否允许匿名 |
| `current_user` | 当前用户名 |
| `user_count` | 用户数量 |
| `users_list` | 用户列表 |

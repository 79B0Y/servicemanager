# LinknLink 嵌入式服务全生命周期管理系统介绍

## 一、项目背景与目标

随着智能家庭、能源管理等场景对本地服务稳定性与可维护性的要求不断提高，LinknLink 推出了基于 Android + Termux + Proot Ubuntu 的轻量级嵌入式服务管理系统，旨在实现如下四大核心目标：

* ✅ **持续自愈运行**：确保所有核心服务（如 Home Assistant、Zigbee2MQTT、Z-Wave JS UI 等）始终在线，出现故障自动修复重启；
* 🧰 **统一生命周器工具链**：所有服务具备标准化的安装、启动、监控、备份、升级、回滚、卸载脚本；
* 📡 **状态与版本可观测**：通过 MQTT 实时上报每个服务的运行状态与版本，供安卓端或 Web Dashboard 直观查看；
* ☁️ **云端持续交付**：脚本包通过云端注册表发布，终端自动发现、下载、更新，实现真正的无人值守。

---

## 二、系统架构与部署方式

本系统运行于 Root 权限的 Android 设备中，借助 Termux 提供类 Linux 环境，并在 Proot Ubuntu 容器中运行各类服务。主要模块包括：

```
Σ 云端注册表 + CDN 脚本包
  │
HTTPS
  │
▼
Android App (MQTT + SSH)
  │
MQTT 状态/版本/日志
  │
▼
Termux → Proot Ubuntu → servicemanager/<service_id>/
        install/start/stop/autocheck/update/等脚本
```

---

## 三、服务生命周期管理

### 标准组件

* `install.sh`：安装服务和依赖。
* `start.sh` / `stop.sh`：通过 supervise 启停服务，带 MQTT 状态上报。
* `status.sh`：检测进程、端口、运行时长，上报 running/starting/stopped 等状态。
* `autocheck.sh`：自愈自检入口，支持故障重试、自动升级。
* `backup.sh` / `restore.sh`：配置数据 tar.gz 备份和还原，保留最新3份。
* `update.sh`：根据 TARGET\_VERSION 进行 pip 升级/降级，完成后上报 success 或 failed。
* `uninstall.sh`：一键卸载并创建 `.disabled` 阻止自动重进程。

---

## 四、云端注册与转应

### 注册表 registry.json

云端维护服务列表，启用后终端可根据 `latest_version` 自动更新：

```json
{
  "id": "home_assistant",
  "latest_version": "1.3.2",
  "package_url": "https://dl.linknlink.com/services/hass-scripts-1.3.2.tar.gz"
}
```

转应流程：

1. 下载 serviceupdate.sh 更新本地 servicelist.json
2. 校验 SHA256 后解压脚本包
3. `autocheck.sh` 启动自检、升级、重启
4. MQTT 全线状态上报，方便控制端查看

---

## 五、自愈与监控机制

### 🌐 autocheck.sh

* 一键合并培育：检查安装 → 检查配置 → 启动 → 升级
* 状态 MQTT 上报： `running` / `recovered` / `failed` / `permanent_failed`
* 全过程并可变环境变量

### 📦 autocheckall.sh

* 每 30s 执行一次，检测所有 service\_id
* 调用对应 autocheck.sh
* 合并上报 isg/status/versions

---

## 六、安全与可靠性

| 风险类别     | 加固策略                                  |
| -------- | ------------------------------------- |
| 脚本被综改    | HTTPS + SHA256 校验，选择 GPG 签名           |
| SSH 暴力破解 | 限制用户，只允许密钥登陆                          |
| 版本回滚失败   | 保留 5 份压缩包，支持本地上升级/降级                  |
| 服务启动失败   | autocheck.sh 进行统计重试，超过阈值重新 install.sh |
| 并发间纠     | 全线脚本采用 flock 不可重复执行                   |

---

## 七、服务接入流程

1. 准备第一版 7 大脚本 + VERSION 文件
2. 压缩成 tar.gz 并上传至 CDN
3. 在 registry.json 中添加服务列表
4. 终端自动发现 → 下载 → 安装 → 运行

---

如需生成英文版、软件教程或报告PPT，我可以提供辅助。

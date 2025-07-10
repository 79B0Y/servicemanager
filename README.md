## LinknLink 嵌入式服务全生命周期管理系统

### 系统概述

LinknLink 提供一套适用于嵌入式环境（如 Android Termux + Proot Ubuntu 架构）的服务生命周期管理框架，旨在实现“持续运行、自愈重启、可视化监控、远程升级”全流程自动化控制。

本系统支持 Home Assistant、Zigbee2MQTT、Z-Wave JS UI、BLE 网关等多种服务，并可扩展至任意用户定义服务。所有服务遵循统一的七段式生命周期管理模型。

---

### 核心特性

* **统一目录结构**：每个服务位于 `~/servicemanager/<service_id>/`，内含标准的 `install.sh`, `start.sh`, `stop.sh`, `status.sh`, `backup.sh`, `restore.sh`, `update.sh`, `autocheck.sh`, `VERSION.yaml` 等文件。

* **自动自愈机制**：通过 `autocheck.sh` 结合 `autocheckall.sh` 实现定时巡检、自动恢复、版本对比升级、失败计数重装，保障服务稳定运行。

* **MQTT 状态上报**：所有脚本均通过 mosquitto\_pub 向主题 `isg/<模块>/<服务ID>/status` 上报运行状态、版本、异常信息，便于 Android 控制端与 Web Dashboard 实时展示。

* **统一日志策略**：所有脚本输出统一汇聚至 `~/isgbackup/<service_id>/logs/<脚本名>.log`，仅保留最近 100 条，兼顾调试与存储控制。

* **安装与升级自动化**：结合云端 `registry.json` 与服务 tar 包，可实现终端自动检测新版本、下载覆盖、环境校验、配置保留。

* **可选持久化备份**：支持配置文件自动打包存储与恢复，适用于版本回退或系统迁移场景。

* **多服务共管**：所有已安装服务统一受 `autocheckall.sh` 调度，通过 `flock` 实现互斥执行，保证并发安全性。

---

### 使用环境要求

* Android 已 root
* Termux 安装完成，支持 proot-distro 安装 Ubuntu 容器
* 安装 mosquitto\_pub 命令行工具
* Python 安装 PyYAML（如需读取 configuration.yaml）

---

### 适用场景

* iSG 网关服务部署与自动维护
* 智能家居设备边缘计算服务自动运行
* 企业级嵌入式服务自动升级与监控
* 容器化嵌入式测试环境统一服务运维管理

---

如需接入新服务，请准备完整生命周期脚本，命名规范为 `service_id-scripts-<版本>.tar.gz`，上传至注册表后将自动部署生效。

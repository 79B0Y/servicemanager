## 通用提示词
1. 将引用的参数从common_path.sh里提取出来，合并到 XXX 脚本里
2. 修改脚本的错误，确保能正确 XXX
3. 启动停止命令
   启动：echo u > /data/data/com.termux/files/usr/var/service/node-red/supervise/control
   停止：echo d > /data/data/com.termux/files/usr/var/service/node-red/supervise/control
4. 禁用启用命令
   禁用自启动: touch /data/data/com.termux/files/usr/var/service/node-red/down
   启用自启动: rm -f /data/data/com.termux/files/usr/var/service/node-red/down
5. mqtt信息
   从 /data/data/com.termux/files/home/servicemanager/configuration.yaml里的mqtt信息里获取
6. 按照原脚本的流程和功能，不要删减
7. 按照原脚本的MQTT信息上报，不要遗漏
8. 关键步骤加上中文注释

   
### install.sh
1. 不用runit来看护服务,注册servicemonitor服务看护
   mkdir -p "/data/data/com.termux/files/usr/var/service/<service_id>/"
   验证service_id>启动命令：
   echo '<service_id>启动命令 2>&1' > "/data/data/com.termux/files/usr/var/service/<service_id>/run"
   禁用自启动: touch /data/data/com.termux/files/usr/var/service/<service_id>/down
   chmod +x /data/data/com.termux/files/usr/var/service/<service_id>/run
2. 调用脚本包里的start.sh脚本来启动<service_id>
   调用脚本包里的stop.sh脚本来停止<service_id>


=============================================================================
通用服务状态查询脚本设计提示词
=============================================================================

🎯 目标
编写一个适用于所有服务的 Bash 状态查询脚本，支持多模式、MQTT 上报、日志记录与 JSON 输出。
 1️⃣ 基础配置
 - SERVICE_ID: 服务标识
 - SERVICE_PORT: 监听端口
 - SERVICE_INSTALL_PATH: proot 安装路径
 - HTTP_TIMEOUT: HTTP 检查超时秒数

 2️⃣ 状态模式控制 (通过环境变量 STATUS_MODE)
 - 0: 检查运行状态和安装状态
 - 1: 只检查运行状态，若 running 则自动判定 install=true, version=running
 - 2: 只检查安装状态，不检测运行状态

 3️⃣ 检查流程
 - get_service_pid(): netstat 检查端口监听，ps 获取 runtime
 - HTTP 健康检查: nc 或 curl 检查 TCP/HTTP 服务可用性
 - proot 中检查 SERVICE_INSTALL_PATH，存在则提取版本

 4️⃣ 输出 JSON 结构:
 {
   "service": "service_id",
   "status": "running|starting|stopped",
   "pid": "PID",
   "runtime": "x",
   "http_status": "online|offline|starting",
   "port": PORT,
   "install": true/false,
   "version": "x.y.z or unknown",
   "timestamp": epoch
 }

 5️⃣ MQTT 上报
 - 配置来源: configuration.yaml
 - 主题: isg/status/$SERVICE_ID/status

 6️⃣ 日志记录
 - 所有操作记录至 LOG_FILE，时间戳追踪

 7️⃣ 退出码
 - 0: running
 - 1: stopped
 - 2: starting

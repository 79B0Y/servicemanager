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


   

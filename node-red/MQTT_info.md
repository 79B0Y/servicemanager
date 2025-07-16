# Node-RED 服务管理系统 - MQTT 消息上报列表

## 1. 安装相关消息 (install.sh)

| MQTT 主题 | 状态值 | 消息内容 | 触发时机 |
|----------|--------|----------|----------|
| `isg/install/node-red/status` | `installing` | `{"status":"installing","message":"starting installation process","timestamp":1234567890}` | 开始安装 |
| `isg/install/node-red/status` | `installing` | `{"status":"installing","message":"reading service dependencies from serviceupdate.json","timestamp":1234567890}` | 读取服务依赖 |
| `isg/install/node-red/status` | `installing` | `{"status":"installing","message":"installing required dependencies","dependencies":["nodejs","npm"],"timestamp":1234567890}` | 安装依赖包 |
| `isg/install/node-red/status` | `installing` | `{"status":"installing","message":"installing system dependencies","timestamp":1234567890}` | 安装系统依赖 |
| `isg/install/node-red/status` | `installing` | `{"status":"installing","message":"checking node.js and npm versions","timestamp":1234567890}` | 检查环境版本 |
| `isg/install/node-red/status` | `installing` | `{"status":"installing","message":"installing pnpm package manager","timestamp":1234567890}` | 安装pnpm |
| `isg/install/node-red/status` | `installing` | `{"status":"installing","message":"installing node-red application","timestamp":1234567890}` | 安装Node-RED |
| `isg/install/node-red/status` | `installing` | `{"status":"installing","message":"generating package.json","timestamp":1234567890}` | 生成package.json |
| `isg/install/node-red/status` | `installing` | `{"status":"installing","message":"creating data directory","timestamp":1234567890}` | 创建数据目录 |
| `isg/install/node-red/status` | `installing` | `{"status":"installing","message":"registering service monitor","timestamp":1234567890}` | 注册服务监控 |
| `isg/install/node-red/status` | `installing` | `{"status":"installing","message":"starting service for testing","timestamp":1234567890}` | 启动服务测试 |
| `isg/install/node-red/status` | `installing` | `{"status":"installing","message":"waiting for service ready","timestamp":1234567890}` | 等待服务就绪 |
| `isg/install/node-red/status` | `installing` | `{"status":"installing","message":"recording installation history","version":"4.0.9","timestamp":1234567890}` | 记录安装历史 |
| `isg/install/node-red/status` | `installed` | `{"service":"node-red","status":"installed","version":"4.0.9","duration":180,"timestamp":1234567890}` | 安装成功 |
| `isg/install/node-red/status` | `failed` | `{"status":"failed","message":"dependency installation failed","dependencies":["nodejs","npm"],"timestamp":1234567890}` | 依赖安装失败 |
| `isg/install/node-red/status` | `failed` | `{"status":"failed","message":"node.js or npm not properly installed","timestamp":1234567890}` | 环境检查失败 |
| `isg/install/node-red/status` | `failed` | `{"status":"failed","message":"service start timeout after installation","timeout":300,"timestamp":1234567890}` | 安装后启动超时 |

## 2. 卸载相关消息 (uninstall.sh)

| MQTT 主题 | 状态值 | 消息内容 |

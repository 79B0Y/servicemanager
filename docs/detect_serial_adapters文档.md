# detect_serial_adapters.py 文档

## 功能描述
此脚本扫描系统串口，探测是否为 Zigbee（EZSP 或 VID/PID 匹配）或 Z-Wave 设备，并通过 MQTT 上报及控制台 JSON 输出，结果也会保存到指定文件。

## 路径配置
- BASE_DIR：脚本及配置文件基础目录
- CONFIG_FILE：MQTT broker 配置文件
- SERIAL_RESULT_FILE：探测结果持久化文件路径
- ZIGBEE_DB_FILE：已知 Zigbee VID/PID 对照表

## 探测流程
1. **加载历史探测结果**：
   - 若 `SERIAL_RESULT_FILE` 不存在，视所有串口为新设备。

2. **列出当前串口**：
   - 依据 `/dev/ttyUSB*`, `/dev/ttyACM*` 等路径匹配。

3. **对每个串口收集 USB 信息**：
   - 获取 VID、PID、Serial Number、Manufacturer、Product。

4. **判断是否需要探测**：
   - 新串口、上次 busy、或者串口信息变化时需重新探测。

5. **探测流程**：
   - 遍历常用波特率（115200、57600、38400、19200、9600）：
     - **Z-Wave 探测**：发送指令，响应前缀 01 或 06 判定。
     - **Zigbee EZSP 探测**：发送指令，响应前缀 11 判定。
   - 若以上失败，再通过 VID/PID 与数据库比对。

6. **结果保存与 MQTT 上报**：
   - 结果写入 `SERIAL_RESULT_FILE`
   - MQTT 发布至 `isg/serial/scan`
   - 控制台输出 JSON 结果

## 返回结果结构
- status：multi_detect_complete
- timestamp：UTC 时间戳
- new_ports：本次需要探测的串口数量
- results：探测结果数组，包含：
  - port
  - vid/pid
  - serial_number
  - manufacturer
  - product
  - type：zigbee/zwave/unknown_device/error
  - protocol
  - baudrate
  - busy
  - previous_busy
  - raw_response
  - error
  - confidence：low / medium / high

## 控制台 JSON 输出示例
```json
{
  "status": "multi_detect_complete",
  "timestamp": "2025-07-20T12:00:00Z",
  "new_ports": 2,
  "results": [
    {
      "port": "/dev/ttyUSB0",
      "type": "zigbee",
      "protocol": "ezsp",
      "baudrate": 115200,
      "confidence": "medium",
      "raw_response": "11abcd...",
      "vid": 1234,
      "pid": 5678,
      "serial_number": "ABCDEF123456",
      "manufacturer": "LinknLink",
      "product": "Zigbee Dongle"
    }
  ]
}
```

## MQTT 上报示例
- Topic：`isg/serial/scan`
- Payload：与控制台 JSON 输出一致

## 日志信息
- 记录串口变化、busy 重试、信息变更、探测响应、探测结果保存路径
- MQTT 上报成功与失败日志

## 可扩展
- 支持配置动态 MQTT topic
- 支持 CLI 参数如 --force 全量扫描
- 支持历史探测文件清理与版本管理

## 执行命令
```
python detect_serial_adapters.py
```

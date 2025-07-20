import serial
import serial.tools.list_ports
import glob
import time
import datetime
import logging
import json
import sys
import yaml
import os
import subprocess

# 定义路径和配置文件
BASE_DIR = "/data/data/com.termux/files/home/servicemanager"
CONFIG_FILE = f"{BASE_DIR}/configuration.yaml"
SERIAL_RESULT_FILE = "/sdcard/isgbackup/serialport/latest.json"
ZIGBEE_DB_FILE = f"{BASE_DIR}/zigbee_known.yaml"
LOG_FILE = f"{BASE_DIR}/serial_detect.log"

# 探测使用的波特率列表
common_baudrates = [115200, 57600, 38400, 19200, 9600]
serial_timeout = 1
probe_sleep = 0.5

# 日志配置，输出到文件和控制台
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler(sys.stdout)
    ]
)

def load_yaml(path):
    # 加载 YAML 文件
    with open(path, 'r') as f:
        return yaml.safe_load(f)

def mqtt_report(topic, message):
    # 通过 mosquitto_pub 命令发布 MQTT 消息
    mqtt_config = load_yaml(CONFIG_FILE).get('mqtt', {})
    host = mqtt_config.get('host', '127.0.0.1')
    port = mqtt_config.get('port', 1883)
    username = mqtt_config.get('username', 'admin')
    password = mqtt_config.get('password', 'admin')

    cmd = [
        'mosquitto_pub',
        '-h', str(host),
        '-p', str(port),
        '-t', topic,
        '-u', username,
        '-P', password,
        '-r',
        '-m', json.dumps(message, ensure_ascii=False)
    ]

    logging.info(f"MQTT 上报到 {topic}: {json.dumps(message, ensure_ascii=False)}")
    try:
        subprocess.run(cmd, check=True)
    except Exception as e:
        logging.error(f"MQTT 发布失败: {e}")

def list_serial_ports():
    # 查找所有可用串口
    patterns = ["/dev/ttyUSB*", "/dev/ttyACM*", "/dev/ttyAS*", "/dev/ttyS*", "/dev/ttyAMA*"]
    ports = []
    for pattern in patterns:
        ports.extend(glob.glob(pattern))
    return sorted(set(ports))

def load_previous_results():
    # 读取上次的探测结果
    if os.path.exists(SERIAL_RESULT_FILE):
        with open(SERIAL_RESULT_FILE, 'r') as f:
            return json.load(f).get('results', [])
    logging.info("历史探测记录文件不存在，所有串口将被视为新设备")
    return []

def collect_port_info(port):
    # 收集串口的 VID/PID 等 USB 信息
    info = next((p for p in serial.tools.list_ports.comports() if p.device == port), None)
    return {
        "port": port,
        "vid": int(info.vid) if info and info.vid else None,
        "pid": int(info.pid) if info and info.pid else None,
        "serial_number": info.serial_number if info else None,
        "manufacturer": info.manufacturer if info else None,
        "product": info.product if info else None,
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat()
    }

def is_port_changed(new_info, old_info):
    # 检查端口信息是否发生变化
    keys = ['vid', 'pid', 'serial_number', 'manufacturer', 'product']
    return any(new_info.get(k) != old_info.get(k) for k in keys)

def try_protocol(port, baudrate, command, startswith):
    # 尝试指定协议命令探测
    try:
        with serial.Serial(port=port, baudrate=baudrate, timeout=serial_timeout) as ser:
            ser.reset_input_buffer()
            ser.write(command)
            time.sleep(probe_sleep)
            raw = ser.read(64).hex()
            logging.info(f"探测 {port} @ {baudrate}: 响应={raw}")
            return raw if raw.startswith(startswith) else None
    except Exception as e:
        logging.warning(f"串口 {port} 波特率 {baudrate} 探测异常: {e}")
        return None

def detect_device(port_info):
    port = port_info['port']
    logging.info(f"开始探测设备: {port}")

    result = port_info.copy()
    result.update({"type": None, "protocol": None, "baudrate": None, "confidence": "low",
                   "busy": False, "previous_busy": port_info.get('previous_busy', False),
                   "error": None, "raw_response": None})

    try:
        # 尝试探测 Z-Wave 协议
        for baudrate in common_baudrates:
            raw = try_protocol(port, baudrate, b"\x01\x03\x00\x15\xE9", ('01', '06'))
            if raw:
                logging.info(f"Z-Wave 设备识别成功: {port} @ {baudrate}")
                result.update({"type": "zwave", "protocol": "zwave", "baudrate": baudrate,
                               "confidence": "medium", "raw_response": raw})
                return result

        # 尝试探测 Zigbee EZSP 协议
        for baudrate in common_baudrates:
            raw = try_protocol(port, baudrate, b"\x1A\xC0\x38\xBC\x7E", ('11',))
            if raw:
                logging.info(f"Zigbee EZSP 设备识别成功: {port} @ {baudrate}")
                result.update({"type": "zigbee", "protocol": "ezsp", "baudrate": baudrate,
                               "confidence": "medium", "raw_response": raw})
                return result

        # 通过 VID/PID 数据库识别 Zigbee
        zigbee_db = load_yaml(ZIGBEE_DB_FILE)
        for item in zigbee_db:
            if item['vid'] == result['vid'] and item['pid'] == result['pid']:
                logging.info(f"Zigbee 设备通过 VID/PID 识别: {port}")
                result.update({"type": "zigbee", "protocol": item.get('type', 'unknown'),
                               "baudrate": item.get('baudrate', 115200), "confidence": "high"})
                return result

        logging.info(f"端口 {port} 未识别为已知设备")
        result.update({"type": "unknown_device"})

    except serial.SerialException as e:
        logging.warning(f"串口 {port} 打开失败: {e}")
        result.update({"busy": True, "error": str(e), "type": "error"})

    return result

def main():
    previous = load_previous_results()
    current_ports = list_serial_ports()
    results = []

    logging.info("开始串口扫描")

    for port in current_ports:
        port_info = collect_port_info(port)
        old_info = next((item for item in previous if item['port'] == port), None)

        need_detect = False

        if old_info is None:
            need_detect = True
            logging.info(f"发现新串口: {port}")
        elif old_info.get('busy'):
            need_detect = True
            port_info['previous_busy'] = True
            logging.info(f"重试上次 busy 的串口: {port}")
        elif is_port_changed(port_info, old_info):
            need_detect = True
            logging.info(f"端口 {port} 设备信息变更，触发重探测")

        if need_detect:
            detected = detect_device(port_info)
            results.append(detected)
        else:
            results.append(old_info)

    final_result = {
        "status": "multi_detect_complete",
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "new_ports": len(results),
        "results": results
    }

    # 保存探测结果
    with open(SERIAL_RESULT_FILE, 'w') as f:
        json.dump(final_result, f, ensure_ascii=False, indent=2)
    logging.info(f"探测结果已保存到 {SERIAL_RESULT_FILE}")

    # MQTT 上报
    mqtt_report("isg/serial/scan", final_result)

    # 控制台输出 JSON
    print(json.dumps(final_result, ensure_ascii=False))

if __name__ == "__main__":
    main()

import serial
import time
import logging
import sys
import glob
import os
import yaml
import json
import subprocess
import serial.tools.list_ports
import datetime

# 配置日志
LOG_FILE = '/data/data/com.termux/files/home/servicemanager/serial_detect.log'
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler(sys.stdout)
    ]
)

# 探测参数
timeout = 2
probe_sleep = 0.5
retry_delay = 1
common_baudrates = [115200, 57600, 38400, 19200, 9600]

# 协议指令
ezsp_cmd = b"\x1A\xC0\x38\xBC\x7E"
zwave_cmd = b"\x01\x03\x00\x15\xE9"

BASE_DIR = "/data/data/com.termux/files/home/servicemanager"
CONFIG_FILE = f"{BASE_DIR}/configuration.yaml"
SERIAL_RESULT_FILE = "/sdcard/isgbackup/serialport/latest.json"

# 加载MQTT配置
def load_mqtt_config():
    with open(CONFIG_FILE, 'r') as f:
        config = yaml.safe_load(f)
    return config.get('mqtt', {})

mqtt_config = load_mqtt_config()

# MQTT 上报方法
def mqtt_report(topic, message):
    cmd = [
        'mosquitto_pub',
        '-h', str(mqtt_config.get('host', '127.0.0.1')),
        '-p', str(mqtt_config.get('port', 1883)),
        '-u', mqtt_config.get('username', 'admin'),
        '-P', mqtt_config.get('password', 'admin'),
        '-t', topic,
        '-m', json.dumps(message, ensure_ascii=False),
        '-r'
    ]
    try:
        subprocess.run(cmd, check=True)
        logging.info(f"MQTT 上报至 {topic}: {json.dumps(message, ensure_ascii=False)}")
    except Exception as e:
        logging.error(f"MQTT 上报失败: {e}")

def ensure_ports_available(chmod_mode="777", patterns=None, graceful_wait=0.5):
    """
    1) 对匹配的串口设备用 su 授权（使用 echo 'cmd' | su 的方式，兼容不支持 -c 的 su）
    2) 使用 fuser 找出占用端口的 PID，先 SIGTERM，再 SIGKILL（如果需要）
    参数:
      chmod_mode: 字符串, 比如 "777" 或 "666"
      patterns: 列表, glob 模式列表, eg ["/dev/ttyUSB*", "/dev/ttyACM*"]
      graceful_wait: 在发送 SIGTERM 后等待多少秒再判断是否需要 SIGKILL
    """
    if patterns is None:
        patterns = ["/dev/ttyUSB*", "/dev/ttyACM*"]

    # 1) chmod via su (echo pipe)
    for pat in patterns:
        for dev in sorted(glob.glob(pat)):
            try:
                cmd = f"echo 'chmod {chmod_mode} {dev}' | su"
                logging.info(f"授权设备 {dev} -> {chmod_mode}")
                subprocess.run(["sh", "-c", cmd], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            except subprocess.CalledProcessError as e:
                logging.warning(f"给 {dev} 授权失败: {e}; stdout={e.stdout} stderr={e.stderr}")

    # 2) fuser -> kill
    for pat in patterns:
        for dev in sorted(glob.glob(pat)):
            try:
                # fuser 输出 pid 列表（也可能返回 non-zero if none）
                ps = subprocess.run(["fuser", dev], capture_output=True, text=True)
                stdout = ps.stdout.strip()
                stderr = ps.stderr.strip()
                if ps.returncode != 0 and not stdout:
                    logging.debug(f"fuser: {dev} 没有占用进程 (returncode={ps.returncode}, stderr={stderr})")
                    continue

                # fuser 输出格式示例: "1234 2345"
                pids = [pid for pid in shlex.split(stdout) if pid.isdigit()]
                if not pids:
                    logging.debug(f"fuser 未返回有效 pid: '{stdout}'")
                    continue

                logging.info(f"设备 {dev} 被如下 PID 占用: {pids}，尝试优雅终止 (SIGTERM)")
                for pid in pids:
                    try:
                        # 先尝试优雅退出
                        subprocess.run(["kill", "-TERM", pid], check=False)
                    except Exception as e:
                        logging.warning(f"向 PID {pid} 发送 TERM 失败: {e}")

                # 等待短暂时间看进程是否退出
                time.sleep(graceful_wait)

                # 检查进程是否还存在，若存在则强制 SIGKILL
                for pid in pids:
                    if os.path.exists(f"/proc/{pid}"):
                        logging.info(f"PID {pid} 仍存在，发送 SIGKILL")
                        try:
                            subprocess.run(["kill", "-KILL", pid], check=False)
                        except Exception as e:
                            logging.error(f"向 PID {pid} 发送 KILL 失败: {e}")
                    else:
                        logging.info(f"PID {pid} 已退出")
            except Exception as e:
                logging.error(f"处理设备 {dev} 时出错: {e}")


def check_port_usage(port):
    try:
        output = subprocess.check_output(['fuser', port], text=True).strip()
        if output:
            pids = output.split()
            processes = {}
            for pid in pids:
                try:
                    cmdline = subprocess.check_output(['cat', f'/proc/{pid}/cmdline'], text=True)
                    cmdline = cmdline.replace('\0', ' ').strip()
                    processes[pid] = cmdline
                except Exception as e:
                    processes[pid] = f"Error retrieving cmdline: {e}"
            return processes
    except subprocess.CalledProcessError:
        pass
    return {}

def list_serial_ports():
    patterns = ["/dev/ttyUSB*", "/dev/ttyACM*", "/dev/ttyAS*", "/dev/ttyS*", "/dev/ttyAMA*"]
    ports = []
    for pattern in patterns:
        ports.extend(glob.glob(pattern))
    ports = [p for p in ports if p not in ('/dev/ttyAS0', '/dev/ttyAS1')]
    return sorted(set(ports))

def read_serial(ser, label):
    raw = ser.read(64)
    hex_data = raw.hex()
    logging.info(f"{label} 响应长度: {len(raw)} bytes, 内容: {hex_data}")
    return hex_data

def collect_port_info(port):
    info = next((p for p in serial.tools.list_ports.comports() if p.device == port), None)
    port_info = {
        "port": port,
        "vid": int(info.vid) if info and info.vid else None,
        "pid": int(info.pid) if info and info.pid else None,
        "serial_number": info.serial_number if info else None,
        "manufacturer": info.manufacturer if info else None,
        "product": info.product if info else None,
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat()
    }
    return port_info

def probe_device(port_info):
    port = port_info['port']
    logging.info(f"开始探测端口: {port}")

    mqtt_report("isg/serial/scan", {**port_info, "status": "detecting"})

    result = {**port_info, 'type': 'unknown', 'busy': False, 'raw_response': ''}

    for baudrate in common_baudrates:
        logging.info(f"尝试波特率 {baudrate} 探测 Z-Wave 指令")
        try:
            with serial.Serial(port=port, baudrate=baudrate, timeout=timeout) as ser:
                ser.reset_input_buffer()
                ser.write(zwave_cmd)
                logging.info(f"已发送 Z-Wave 指令: {zwave_cmd.hex()}")
                time.sleep(probe_sleep)
                response = read_serial(ser, "Z-Wave")
                if response and response.startswith(('01', '06')):
                    logging.info(f"Z-Wave 设备识别成功 @ {baudrate} 波特率")
                    result.update({'type': 'zwave', 'baudrate': baudrate, 'raw_response': response})
                    break
        except Exception as e:
            logging.error(f"Z-Wave 探测异常 @ {baudrate} 波特率: {e}")

    if result['type'] == 'unknown':
        time.sleep(retry_delay)
        for baudrate in common_baudrates:
            logging.info(f"尝试波特率 {baudrate} 探测 EZSP (Zigbee) 指令")
            try:
                with serial.Serial(port=port, baudrate=baudrate, timeout=timeout) as ser:
                    ser.reset_input_buffer()
                    ser.write(ezsp_cmd)
                    logging.info(f"已发送 EZSP 指令: {ezsp_cmd.hex()}")
                    time.sleep(probe_sleep)
                    response = read_serial(ser, "EZSP")
                    if response and '11' in response[:4]:
                        logging.info(f"EZSP Zigbee 设备识别成功 @ {baudrate} 波特率")
                        result.update({'type': 'zigbee', 'protocol': 'ezsp', 'baudrate': baudrate, 'raw_response': response})
                        break
            except Exception as e:
                logging.error(f"EZSP 探测异常 @ {baudrate} 波特率: {e}")

    if not result['raw_response']:
        result['busy'] = True
        occupied = check_port_usage(port)
        result['occupied_processes'] = occupied

        # 如果被占用的进程包含 zwave-js-ui，直接标记为 zwave
        for cmdline in occupied.values():
            if 'zwave-js-ui' in cmdline:
                result['type'] = 'zwave'
                logging.info(f"通过进程占用识别为 Z-Wave: {port}")
                break

    mqtt_report("isg/serial/scan", {**result, "status": result['type'] + '_detected' if result['type'] != 'unknown' else 'unknown_device'})
    return result

def save_results(results):
    final_result = {
        "status": "multi_detect_complete",
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "results": results
    }
    with open(SERIAL_RESULT_FILE, 'w') as f:
        json.dump(final_result, f, ensure_ascii=False, indent=2)
    logging.info(f"探测结果已保存到 {SERIAL_RESULT_FILE}")
    mqtt_report("isg/serial/scan", final_result)

def main():
    ensure_ports_available(chmod_mode="777", patterns=["/dev/ttyUSB*", "/dev/ttyACM*"])
    ports = list_serial_ports()
    if not ports:
        logging.error("未找到任何串口设备")
        sys.exit(1)

    results = []
    for port in ports:
        port_info = collect_port_info(port)
        result = probe_device(port_info)
        results.append(result)

    save_results(results)
    logging.info("全部串口探测完成")

if __name__ == "__main__":
    main()

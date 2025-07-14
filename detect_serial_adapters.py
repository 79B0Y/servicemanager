#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import json
import time
import serial
import serial.tools.list_ports
import logging
import yaml
import glob
import datetime
import subprocess
from pathlib import Path

# ========== 配置区域 ==========
CONFIG_FILE = '/data/data/com.termux/files/home/servicemanager/configuration.yaml'
zigbee_db_path = "/data/data/com.termux/files/home/servicemanager/zigbee_known.yaml"
output_dir = Path("/sdcard/isgbackup/serialport")
log_file = output_dir / "serial_detect.log"

common_baudrates = [115200, 57600, 38400, 9600, 230400]
zwave_version_cmd = bytes.fromhex("01030015E9")

mqtt_config = {}

def load_mqtt_conf():
    global mqtt_config
    with open(CONFIG_FILE, 'r') as f:
        config = yaml.safe_load(f)
    mqtt_conf = config.get('mqtt', {})
    mqtt_config = {
        'broker': mqtt_conf.get('host', '127.0.0.1'),
        'port': mqtt_conf.get('port', 1883),
        'user': mqtt_conf.get('username', 'admin'),
        'pass': mqtt_conf.get('password', 'admin'),
        'topic': mqtt_conf.get('topic', 'isg/serial/scan')
    }

# ========== 日志设置 ==========
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    handlers=[
        logging.FileHandler(log_file, encoding='utf-8'),
        logging.StreamHandler()
    ]
)

# ========== MQTT 上报 ==========
def mqtt_report(topic, payload):
    cmd = [
        'mosquitto_pub',
        '-h', mqtt_config['broker'],
        '-p', str(mqtt_config['port']),
        '-u', mqtt_config['user'],
        '-P', mqtt_config['pass'],
        '-t', topic,
        '-m', json.dumps(payload),
        '-r'
    ]
    try:
        subprocess.run(cmd, check=True)
        logging.info(f"📡 MQTT 上报成功 → {topic}")
    except Exception as e:
        logging.error(f"MQTT 发送失败: {e}")

# ========== Zigbee 识别逻辑 ==========
def load_zigbee_db():
    if Path(zigbee_db_path).exists():
        with open(zigbee_db_path, "r") as f:
            return yaml.safe_load(f)
    return []

def check_known_zigbee(vid, pid):
    db = load_zigbee_db()
    for entry in db:
        if vid == entry.get("vid") and pid == entry.get("pid"):
            return entry
    return None

# ========== 设备探测逻辑 ==========
def list_serial_ports():
    patterns = ["/dev/ttyUSB*", "/dev/ttyACM*", "/dev/ttyAS*", "/dev/ttyS*", "/dev/ttyAMA*"]
    all_ports = []
    for pattern in patterns:
        all_ports.extend(glob.glob(pattern))
    return sorted(set(all_ports))

def detect_device(port):
    result = {
        "port": port,
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "busy": False
    }

    mqtt_report(mqtt_config['topic'], {"status": "detecting", **result})
    logging.info(f"🔎 正在探测 {port}")

    try:
        info = next((p for p in serial.tools.list_ports.comports() if p.device == port), None)
        vid = int(info.vid) if info and info.vid else None
        pid = int(info.pid) if info and info.pid else None

        for baudrate in common_baudrates:
            try:
                with serial.Serial(port=port, baudrate=baudrate, timeout=1) as ser:
                    ser.reset_input_buffer()
                    ser.write(zwave_version_cmd)
                    time.sleep(0.5)
                    raw = ser.read(64).hex()
                    if raw.startswith("01") or raw.startswith("06"):
                        result.update({
                            "type": "zwave",
                            "protocol": "zwave",
                            "raw_response": raw,
                            "baudrate": baudrate,
                            "confidence": "medium",
                            "vid": vid,
                            "pid": pid
                        })
                        mqtt_report(mqtt_config['topic'], {"status": "zwave_detected", **result})
                        return result
            except Exception:
                continue

        if vid and pid:
            zigbee = check_known_zigbee(vid, pid)
            if zigbee:
                result.update({
                    "type": "zigbee",
                    "protocol": zigbee.get("type", "unknown"),
                    "baudrate": zigbee.get("baudrate", 115200),
                    "confidence": "high",
                    "vid": vid,
                    "pid": pid
                })
                mqtt_report(mqtt_config['topic'], {"status": "zigbee_detected", **result})
                return result

        for baudrate in common_baudrates:
            try:
                with serial.Serial(port=port, baudrate=baudrate, timeout=1) as ser:
                    ser.reset_input_buffer()
                    ser.write(b"\x1A\xC0\x38\xBC\x7E")
                    time.sleep(0.5)
                    raw = ser.read(64).hex()
                    if raw.startswith("11"):
                        result.update({
                            "type": "zigbee",
                            "protocol": "ezsp",
                            "raw_response": raw,
                            "baudrate": baudrate,
                            "confidence": "medium",
                            "vid": vid,
                            "pid": pid
                        })
                        mqtt_report(mqtt_config['topic'], {"status": "zigbee_detected", **result})
                        return result
            except Exception:
                continue

        result.update({"type": "unknown"})
        return result

    except serial.SerialException as e:
        result.update({"busy": True, "type": "error", "error": str(e)})
        mqtt_report(mqtt_config['topic'], {"status": "occupied", **result})
        return result

# ========== 主程序 ==========
def main():
    load_mqtt_conf()
    now = datetime.datetime.now(datetime.timezone.utc).isoformat()
    mqtt_report(mqtt_config['topic'], {"status": "running", "timestamp": now})
    ports = list_serial_ports()
    logging.info(f"🔍 共发现 {len(ports)} 个串口设备")

    results = [detect_device(p) for p in ports]

    timestamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d%H%M%S")
    output_dir.mkdir(parents=True, exist_ok=True)
    output_file = output_dir / f"serial_ports_{timestamp}.json"

    with open(output_file, "w") as f:
        json.dump({"timestamp": now, "ports": results}, f, indent=2)

    latest_path = output_dir / "latest.json"
    with open(latest_path, "w") as f:
        json.dump({"timestamp": now, "ports": results}, f, indent=2)

    files = sorted(output_dir.glob("serial_ports_*.json"), key=os.path.getmtime, reverse=True)
    for f in files[3:]:
        f.unlink()

    mqtt_report(mqtt_config['topic'], {"timestamp": now, "ports": results, "added": [], "removed": []})
    logging.info("✅ 串口识别流程完成")

if __name__ == "__main__":
    main()

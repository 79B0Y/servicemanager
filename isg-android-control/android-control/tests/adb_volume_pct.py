#!/usr/bin/env python3
"""
adb_volume_pct.py - Set Android volume using ADB, verify, and optionally report via MQTT.

Primary set method:
  adb shell cmd media_session volume --show --stream <code> --set <index>
Fallback (older ROMs):
  adb shell media volume --stream <code> --set <index>

Environment variables
=====================
# --- Required target (二选一) ---
  PCT                目标音量百分比 (0..100)。与 INDEX 互斥，如果两者都提供，则优先生效 INDEX。
  INDEX              目标音量“档位 index”(0..Max)。若同时提供 PCT 和 INDEX，优先 INDEX。

# --- Optional stream/device/adb ---
  STREAM             流名称: music(默认), ring, alarm, notification, system, voice_call
  ADB_SERIAL         指定设备序列号给 "adb -s <serial>"
  ADB                adb 可执行路径 (默认: adb)
  DRY_RUN            "1" 则仅打印命令不执行
  SHOW_PANEL         "1" 显示系统音量面板(默认 1)

# --- Optional MQTT reporting ---
  REPORT             "1" 开启上报
  REPORT_HA          "1" 以 Home Assistant state 结构上报到 <BASE_TOPIC>/state
  MQTT_HOST          MQTT 主机 (默认: localhost)
  MQTT_PORT          MQTT 端口 (默认: 1883)
  MQTT_USER          用户名 (可选)
  MQTT_PASS          密码   (可选)
  BASE_TOPIC         HA 上报需要，如 isg/android
  REPORT_TOPIC       事件上报自定义主题(默认 <BASE_TOPIC>/events 或 android/volume_test)
  RETAIN             "1" 发送保留消息 (默认 0)

Usage
=====
  # 设“音乐流”40%，并以 HA state 结构上报
  PCT=40 REPORT=1 REPORT_HA=1 BASE_TOPIC=isg/android MQTT_HOST=127.0.0.1 python3 adb_volume_pct.py

  # 按 index 设“来电流”
  INDEX=12 STREAM=ring python3 adb_volume_pct.py

  # 多设备
  PCT=55 ADB_SERIAL=emulator-5554 REPORT=1 REPORT_HA=1 BASE_TOPIC=isg/android python3 adb_volume_pct.py
"""

import os
import re
import shlex
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from typing import Optional, Tuple
import json

# -------------------------- Stream mapping --------------------------
STREAM_MAP = {
    "voice_call": (0, "STREAM_VOICE_CALL"),
    "system":     (1, "STREAM_SYSTEM"),
    "ring":       (2, "STREAM_RING"),
    "music":      (3, "STREAM_MUSIC"),
    "alarm":      (4, "STREAM_ALARM"),
    "notification": (5, "STREAM_NOTIFICATION"),
}

# For HA-style payload path names
HA_AUDIO_KEY = {
    "music": "music",
    "ring": "ring",
    "alarm": "alarm",
    "notification": "notification",
    "system": "system",
    "voice_call": "voice_call",
}

# -------------------------- Utils --------------------------
def env(name: str, default: Optional[str] = None) -> Optional[str]:
    v = os.environ.get(name)
    return v if v is not None and v != "" else default

def clamp(n, lo: int, hi: int) -> int:
    try:
        n = int(round(float(n)))
    except Exception:
        raise SystemExit(f"[ERR] Invalid integer value: {n!r}")
    return max(lo, min(hi, n))

def run(cmd: list[str], check: bool = True) -> Tuple[int, str, str]:
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    out, err = proc.communicate()
    if check and proc.returncode != 0:
        raise subprocess.CalledProcessError(proc.returncode, cmd, out, err)
    return proc.returncode, out, err

def adb_cmd_prefix() -> list[str]:
    adb = env("ADB", "adb")
    serial = env("ADB_SERIAL")
    return [adb, "-s", serial] if serial else [adb]

def check_adb_available() -> None:
    prefix = adb_cmd_prefix()
    try:
        run(prefix + ["version"], check=True)
    except Exception as e:
        raise SystemExit(f"[ERR] adb not available or not in PATH. Detail: {e}")

def check_device_connected() -> None:
    prefix = adb_cmd_prefix()
    code, out, _ = run(prefix + ["get-state"], check=False)
    if code != 0 or "device" not in out.strip():
        raise SystemExit(f"[ERR] No device connected or unauthorized. Try: {shlex.join(prefix + ['devices'])}")

def dumpsys_audio() -> str:
    prefix = adb_cmd_prefix()
    code, out, err = run(prefix + ["shell", "dumpsys", "audio"], check=False)
    if code != 0:
        raise SystemExit(f"[ERR] dumpsys audio failed: rc={code} err={err}")
    return out

def parse_max_for_stream(dumpsys_out: str, stream_key: str) -> Optional[int]:
    pattern = rf"{re.escape(stream_key)}.*?(?:Max:\s*(\d+))"
    m = re.search(pattern, dumpsys_out, flags=re.DOTALL)
    return int(m.group(1)) if m else None

def parse_index_for_stream(dumpsys_out: str, stream_key: str) -> Optional[int]:
    pattern = rf"{re.escape(stream_key)}.*?(?:Index:\s*(\d+))"
    m = re.search(pattern, dumpsys_out, flags=re.DOTALL)
    return int(m.group(1)) if m else None

def get_max_index(stream_key: str) -> int:
    out = dumpsys_audio()
    max_idx = parse_max_for_stream(out, stream_key)
    return max_idx if (isinstance(max_idx, int) and max_idx > 0) else 25

def get_current_index(stream_key: str) -> Optional[int]:
    out = dumpsys_audio()
    return parse_index_for_stream(out, stream_key)

def set_volume_index(stream_code: int, idx: int, *, dry_run: bool = False, show_panel: bool = True) -> None:
    prefix = adb_cmd_prefix()
    primary = prefix + ["shell", "cmd", "media_session", "volume"]
    if show_panel:
        primary += ["--show"]
    primary += ["--stream", str(stream_code), "--set", str(idx)]
    print("[CMD]", shlex.join(primary))
    if not dry_run:
        code, out, err = run(primary, check=False)
        if code != 0:
            fallback = prefix + ["shell", "media", "volume", "--stream", str(stream_code), "--set", str(idx)]
            print("[FALLBACK]", shlex.join(fallback))
            code2, out2, err2 = run(fallback, check=False)
            if code2 != 0:
                raise SystemExit(f"[ERR] Failed to set volume.\nprimary rc={code}, err={err}\nfallback rc={code2}, err={err2}")
        elif out.strip():
            print("[OUT]", out.strip())

# -------------------------- MQTT reporting --------------------------
class Reporter:
    def __init__(self) -> None:
        self.enabled = env("REPORT", "0") == "1"
        self.ha = env("REPORT_HA", "0") == "1"
        self.host = env("MQTT_HOST", "localhost")
        self.port = int(env("MQTT_PORT", "1883"))
        self.user = env("MQTT_USER")
        self.password = env("MQTT_PASS")
        self.base_topic = env("BASE_TOPIC")
        self.topic = env("REPORT_TOPIC")
        self.retain = env("RETAIN", "0") == "1"
        if not self.topic:
            self.topic = f"{self.base_topic}/state" if (self.ha and self.base_topic) else (f"{self.base_topic}/events" if self.base_topic else "android/volume_test")
        self.impl = None
        self._init_impl()

    def _init_impl(self) -> None:
        if not self.enabled:
            return
        try:
            import paho.mqtt.client as mqtt  # type: ignore
            self.mqtt = mqtt.Client()
            if self.user and self.password:
                self.mqtt.username_pw_set(self.user, self.password)
            self.mqtt.connect(self.host, self.port, 60)
            try:
                self.mqtt.loop_start()
            except Exception:
                pass
            self.impl = "paho"
            return
        except Exception:
            pass
        if shutil.which("mosquitto_pub"):
            self.impl = "mosquitto"
            return
        print("[WARN] REPORT=1 but no MQTT client available (paho/mosquitto_pub). Will print payload only.")
        self.impl = None

    def _publish_paho(self, topic: str, payload: str) -> None:
        self.mqtt.publish(topic, payload, retain=self.retain)

    def _publish_mosquitto(self, topic: str, payload: str) -> None:
        cmd = ["mosquitto_pub", "-h", self.host, "-p", str(self.port), "-t", topic, "-m", payload]
        if self.retain: cmd.append("-r")
        if self.user:   cmd += ["-u", self.user]
        if self.password: cmd += ["-P", self.password]
        print("[PUB]", shlex.join(cmd))
        run(cmd, check=False)

    def publish(self, topic: str, payload: str) -> None:
        if not self.enabled:
            return
        if self.impl == "paho":
            self._publish_paho(topic, payload)
        elif self.impl == "mosquitto":
            self._publish_mosquitto(topic, payload)
        else:
            print(f"[REPORT] topic={topic}\npayload={payload}")

# -------------------------- Main --------------------------
def main() -> None:
    # 读取环境变量
    pct_str   = env("PCT")
    index_str = env("INDEX")
    stream    = env("STREAM", "music").lower()
    dry_run   = env("DRY_RUN", "0") == "1"
    show_panel= env("SHOW_PANEL", "1") == "1"

    if stream not in STREAM_MAP:
        valid = ", ".join(sorted(STREAM_MAP.keys()))
        raise SystemExit(f"[ERR] Invalid STREAM={stream!r}. Valid: {valid}")

    stream_code, stream_key = STREAM_MAP[stream]

    # 基础检查
    check_adb_available()
    check_device_connected()

    # 解析最大档 & 目标 index
    max_idx = get_max_index(stream_key)
    desired_idx: Optional[int] = None
    desired_pct: Optional[int] = None

    if index_str is not None:
        desired_idx = clamp(index_str, 0, max_idx)
        desired_pct = round(desired_idx * 100.0 / max_idx)
    elif pct_str is not None:
        desired_pct = clamp(pct_str, 0, 100)
        desired_idx = round(desired_pct * max_idx / 100.0)
    else:
        raise SystemExit("[ERR] Missing PCT or INDEX. Provide one of them.")

    print(f"[INFO] Target STREAM={stream} (code={stream_code}, key={stream_key}), "
          f"PCT={desired_pct}% → index≈{desired_idx} (max={max_idx})")

    # 设置音量
    set_volume_index(stream_code, desired_idx, dry_run=dry_run, show_panel=show_panel)

    # 校验（短暂等待再读取）
    time.sleep(0.2)
    current_idx = get_current_index(stream_key)
    ok = (current_idx == desired_idx)
    current_pct = round(current_idx * 100.0 / max_idx) if current_idx is not None else None
    print(f"[VERIFY] desired index={desired_idx}, current index={current_idx}, ok={ok}")

    # 上报
    r = Reporter()
    ts = datetime.now(timezone.utc).isoformat()
    serial = env("ADB_SERIAL") or "(default)"

    if env("REPORT_HA", "0") == "1" and env("BASE_TOPIC") is None:
        print("[WARN] REPORT_HA=1 but BASE_TOPIC is missing; fallback to event payload.")

    if r.enabled and r.ha and r.base_topic:
        key = HA_AUDIO_KEY.get(stream, stream)
        payload = {
            "audio": {
                key: {
                    "index": current_idx,
                    "percent": current_pct,
                }
            },
            "meta": {
                "ts": ts,
                "ok": ok,
                "desired": {"index": desired_idx, "percent": desired_pct, "max": max_idx},
                "device": {"serial": serial},
            }
        }
    else:
        payload = {
            "event": "volume_set",
            "stream": stream,
            "ok": ok,
            "desired": {"index": desired_idx, "percent": desired_pct, "max": max_idx},
            "reported": {"index": current_idx, "percent": current_pct},
            "device": {"serial": serial},
            "ts": ts,
        }

    payload_str = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    r.publish(r.topic, payload_str)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass

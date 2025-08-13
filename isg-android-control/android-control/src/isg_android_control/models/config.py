from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Optional

import yaml


CONFIG_DIR = Path(__file__).resolve().parents[3] / "configs"


@dataclass
class MQTTConfig:
    host: str = "127.0.0.1"
    port: int = 1883
    username: Optional[str] = None
    password: Optional[str] = None
    discovery_prefix: str = "homeassistant"
    base_topic: str = "isg/android"


@dataclass
class DeviceConfig:
    adb_host: str = "127.0.0.1"
    adb_port: int = 5555
    adb_serial: Optional[str] = None  # overrides host:port if set
    screenshots_dir: Path = Path("var/screenshots")
    logs_dir: Path = Path("var/log")
    run_dir: Path = Path("var/run")
    has_battery: bool = False
    has_cellular: bool = False
    camera_enabled: bool = True
    camera_interval: int = 10  # seconds (deprecated; use screenshot_interval)
    screenshot_interval: int = 10  # seconds
    screenshot_keep: int = 3
    # MQTT camera behavior
    camera_max_bytes: int = 600000  # skip MQTT publish if larger
    camera_retain: bool = False     # do not retain large images by default
    # Compression settings
    camera_compress: bool = True
    camera_format: str = "jpeg"     # jpeg or png
    camera_quality: int = 70         # for jpeg
    camera_max_width: Optional[int] = None
    camera_max_height: Optional[int] = None
    device_id: str = "isg_android_controller"
    device_name: str = "ISG Android Controller"
    # Foreground app tracking
    app_watch_enabled: bool = True
    app_poll_interval: int = 2  # seconds


@dataclass
class AppConfig:
    apps: Dict[str, str] = field(default_factory=dict)  # display_name -> package
    visible: Optional[list[str]] = field(default_factory=list)  # optional subset of display names


@dataclass
class APIConfig:
    host: str = "0.0.0.0"
    port: int = 8000


@dataclass
class Settings:
    mqtt: MQTTConfig = field(default_factory=MQTTConfig)
    api: APIConfig = field(default_factory=APIConfig)
    device: DeviceConfig = field(default_factory=DeviceConfig)
    appmap: AppConfig = field(default_factory=AppConfig)

    @classmethod
    def load(cls) -> "Settings":
        mqtt_cfg = CONFIG_DIR / "mqtt.yaml"
        api_cfg = CONFIG_DIR / "api.yaml"
        dev_cfg = CONFIG_DIR / "device.yaml"
        apps_cfg = CONFIG_DIR / "apps.yaml"

        mqtt = MQTTConfig()
        api = APIConfig()
        device = DeviceConfig()
        appmap = AppConfig()

        if mqtt_cfg.exists():
            with open(mqtt_cfg, "r", encoding="utf-8") as f:
                d = yaml.safe_load(f) or {}
                mqtt = MQTTConfig(**{k: v for k, v in d.items() if k in MQTTConfig.__annotations__})

        if api_cfg.exists():
            with open(api_cfg, "r", encoding="utf-8") as f:
                d = yaml.safe_load(f) or {}
                api = APIConfig(**{k: v for k, v in d.items() if k in APIConfig.__annotations__})

        if dev_cfg.exists():
            with open(dev_cfg, "r", encoding="utf-8") as f:
                d = yaml.safe_load(f) or {}
                # handle path fields
                if "screenshots_dir" in d:
                    d["screenshots_dir"] = Path(d["screenshots_dir"]) 
                if "logs_dir" in d:
                    d["logs_dir"] = Path(d["logs_dir"]) 
                if "run_dir" in d:
                    d["run_dir"] = Path(d["run_dir"]) 
                device = DeviceConfig(**{k: v for k, v in d.items() if k in DeviceConfig.__annotations__})

        if apps_cfg.exists():
            with open(apps_cfg, "r", encoding="utf-8") as f:
                d = yaml.safe_load(f) or {}
                vis = d.get("visible") or d.get("options") or []
                appmap = AppConfig(apps=d.get("apps", {}), visible=vis)

        # env overrides from .env and environment
        env = _load_env()
        if env.get("MQTT_HOST"):
            mqtt.host = env["MQTT_HOST"]
        if env.get("MQTT_PORT"):
            try:
                mqtt.port = int(env["MQTT_PORT"])  
            except Exception:
                pass
        if env.get("MQTT_USERNAME"):
            mqtt.username = env["MQTT_USERNAME"]
        if env.get("MQTT_PASSWORD"):
            mqtt.password = env["MQTT_PASSWORD"]
        if env.get("MQTT_DISCOVERY_PREFIX"):
            mqtt.discovery_prefix = env["MQTT_DISCOVERY_PREFIX"]
        if env.get("MQTT_BASE_TOPIC"):
            mqtt.base_topic = env["MQTT_BASE_TOPIC"]

        if env.get("API_HOST"):
            api.host = env["API_HOST"]
        if env.get("API_PORT"):
            try:
                api.port = int(env["API_PORT"])  
            except Exception:
                pass

        if env.get("ADB_HOST"):
            device.adb_host = env["ADB_HOST"]
        if env.get("ADB_PORT"):
            try:
                device.adb_port = int(env["ADB_PORT"])  
            except Exception:
                pass
        if env.get("ADB_SERIAL"):
            device.adb_serial = env["ADB_SERIAL"]
        if env.get("SCREENSHOTS_DIR"):
            device.screenshots_dir = Path(env["SCREENSHOTS_DIR"])  
        if env.get("LOGS_DIR"):
            device.logs_dir = Path(env["LOGS_DIR"])  
        if env.get("RUN_DIR"):
            device.run_dir = Path(env["RUN_DIR"])  
        if env.get("DEVICE_ID"):
            device.device_id = env["DEVICE_ID"]
        if env.get("DEVICE_NAME"):
            device.device_name = env["DEVICE_NAME"]
        if env.get("CAMERA_MAX_BYTES"):
            try:
                device.camera_max_bytes = int(env["CAMERA_MAX_BYTES"])  
            except Exception:
                pass
        if env.get("CAMERA_RETAIN"):
            v = env["CAMERA_RETAIN"].strip().lower()
            device.camera_retain = v in {"1","true","yes","on"}
        if env.get("CAMERA_COMPRESS"):
            v = env["CAMERA_COMPRESS"].strip().lower()
            device.camera_compress = v in {"1","true","yes","on"}
        if env.get("CAMERA_FORMAT"):
            device.camera_format = env["CAMERA_FORMAT"].strip().lower()
        if env.get("CAMERA_QUALITY"):
            try:
                device.camera_quality = int(env["CAMERA_QUALITY"])  
            except Exception:
                pass
        if env.get("CAMERA_MAX_WIDTH"):
            try:
                device.camera_max_width = int(env["CAMERA_MAX_WIDTH"])  
            except Exception:
                pass
        if env.get("CAMERA_MAX_HEIGHT"):
            try:
                device.camera_max_height = int(env["CAMERA_MAX_HEIGHT"])  
            except Exception:
                pass
        if env.get("APP_WATCH_ENABLED"):
            v = env["APP_WATCH_ENABLED"].strip().lower()
            device.app_watch_enabled = v in {"1","true","yes","on"}
        if env.get("APP_POLL_INTERVAL"):
            try:
                device.app_poll_interval = int(env["APP_POLL_INTERVAL"])  
            except Exception:
                pass

        # ensure dirs exist
        for p in [device.screenshots_dir, device.logs_dir, device.run_dir]:
            (Path.cwd() / p).mkdir(parents=True, exist_ok=True)

        return Settings(mqtt=mqtt, api=api, device=device, appmap=appmap)


def _load_env() -> Dict[str, str]:
    data: Dict[str, str] = {}
    env_path = Path.cwd() / ".env"
    try:
        if env_path.exists():
            for raw in env_path.read_text(encoding="utf-8").splitlines():
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                v = v.strip().strip('"').strip("'")
                data[k.strip()] = v
    except Exception:
        pass
    import os

    for k, v in os.environ.items():
        if k.startswith("MQTT_") or k.startswith("ADB_") or k.startswith("API_") or k in {"SCREENSHOTS_DIR", "LOGS_DIR", "RUN_DIR"}:
            data[k] = v
    return data

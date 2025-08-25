from __future__ import annotations

import asyncio
import json
import os
import shlex
import subprocess
from dataclasses import dataclass
from typing import Callable, Optional

import paho.mqtt.client as mqtt

from ..models.config import MQTTConfig
from .. import __version__


@dataclass
class HADevice:
    identifiers: str
    name: str
    manufacturer: str = "Custom"
    model: str = "Android"
    sw_version: str = __version__


class HAIntegration:
    def __init__(self, cfg: MQTTConfig, device_id: str = "isg_android_controller", device_name: str = "ISG Android Controller", max_image_bytes: int | None = None, retain_images: bool = True) -> None:
        self.cfg = cfg
        self.client = mqtt.Client()
        if cfg.username and cfg.password:
            self.client.username_pw_set(cfg.username, cfg.password)
        self.device = HADevice(identifiers=device_id, name=device_name)
        self.max_image_bytes = max_image_bytes
        self.retain_images = retain_images

    def connect(self) -> None:
        # Set LWT for availability
        self.client.will_set(self.availability_topic, payload="offline", qos=0, retain=True)
        self.client.connect(self.cfg.host, self.cfg.port, 60)
        try:
            self.client.loop_start()
        except Exception:
            pass

    def _disc_topic(self, component: str, object_id: str) -> str:
        return f"{self.cfg.discovery_prefix}/{component}/{self.device.identifiers}/{object_id}/config"

    def _uid(self, suffix: str) -> str:
        return f"{self.device.identifiers}_{suffix}"

    @property
    def availability_topic(self) -> str:
        return f"{self.cfg.base_topic}/availability"

    def publish_availability(self, online: bool = True) -> None:
        self.client.publish(self.availability_topic, "online" if online else "offline", retain=True)

    def clear_discovery(self, app_names: list[str]) -> None:
        # Publish empty retained payloads to delete discovery entries
        # buttons
        for key in [
            "nav_up","nav_down","nav_left","nav_right","nav_center","home","back","vol_up","vol_down","screenshot"
        ]:
            self.client.publish(self._disc_topic("button", key), "", retain=True)
        # switch/number/select/camera
        for comp, ids in {
            "switch": ["screen"],
            "number": ["brightness","brightness_percent","volume_percent","volume_index"],
            "select": ["active_app"],
            "camera": ["screen"],
            # sensors
            "sensor": [
                "battery","cpu_usage","memory_used","network_type","foreground_app","battery_temp","battery_health","storage_used","cell_level","screen_state"
            ],
        }.items():
            for oid in ids:
                self.client.publish(self._disc_topic(comp, oid), "", retain=True)

    def publish_discovery(self, app_names: list[str], has_battery: bool = False, has_cellular: bool = False, camera: bool = True) -> None:
        # Buttons for nav, volume, screenshot; switch for screen; number for brightness; sensor for battery; select for app
        base_cmd_topic = f"{self.cfg.base_topic}/cmd"
        # Button example: home
        buttons = {
            "nav_up": {"cmd": "nav:up"},
            "nav_down": {"cmd": "nav:down"},
            "nav_left": {"cmd": "nav:left"},
            "nav_right": {"cmd": "nav:right"},
            "nav_center": {"cmd": "nav:center"},
            "home": {"cmd": "nav:home"},
            "back": {"cmd": "nav:back"},
            "vol_up": {"cmd": "volume:up"},
            "vol_down": {"cmd": "volume:down"},
            "screenshot": {"cmd": "screenshot"},
        }
        for key, data in buttons.items():
            payload = {
                "name": f"Android {key}",
                "command_topic": base_cmd_topic,
                "payload_press": data["cmd"],
                "unique_id": self._uid(key),
                "availability_topic": self.availability_topic,
                "payload_available": "online",
                "payload_not_available": "offline",
                "device": self.device.__dict__,
            }
            self.client.publish(self._disc_topic("button", key), json.dumps(payload), retain=True)

        # Screen switch
        switch_payload = {
            "name": "Android Screen",
            "command_topic": base_cmd_topic,
            "payload_on": "screen:on",
            "payload_off": "screen:off",
            "state_topic": f"{self.cfg.base_topic}/state",
            "value_template": "{{ 'ON' if (value_json.screen.on | default(false)) else 'OFF' }}",
            "unique_id": self._uid("screen_switch"),
            "availability_topic": self.availability_topic,
            "payload_available": "online",
            "payload_not_available": "offline",
            "icon": "mdi:monitor",
            "device": self.device.__dict__,
        }
        self.client.publish(self._disc_topic("switch", "screen"), json.dumps(switch_payload), retain=True)

        # Screen state sensor for monitoring
        screen_sensor = {
            "name": "Android Screen State",
            "state_topic": f"{self.cfg.base_topic}/state_json",
            "value_template": "{{ 'on' if (value_json.screen.on | default(false)) else 'off' }}",
            "icon": "mdi:monitor",
            "unique_id": self._uid("screen_state"),
            "availability_topic": self.availability_topic,
            "payload_available": "online",
            "payload_not_available": "offline",
            "device": self.device.__dict__,
        }
        self.client.publish(self._disc_topic("sensor", "screen_state"), json.dumps(screen_sensor), retain=True)

        # Brightness number (0-255)
        number_payload = {
            "name": "Android Brightness",
            "command_topic": base_cmd_topic,
            "state_topic": f"{self.cfg.base_topic}/state_json",
            "command_template": "brightness:{{ value }}",
            "value_template": "{{ (value_json.screen.brightness | default(0) | int) }}",
            "min": 0,
            "max": 255,
            "step": 1,
            "unique_id": self._uid("brightness_255"),
            "availability_topic": self.availability_topic,
            "payload_available": "online",
            "payload_not_available": "offline",
            "device": self.device.__dict__,
        }
        self.client.publish(self._disc_topic("number", "brightness"), json.dumps(number_payload), retain=True)
        # Brightness percent (0-100) mapped to 0-255
        number_pct = {
            "name": "Android Brightness %",
            "command_topic": base_cmd_topic,
            "state_topic": f"{self.cfg.base_topic}/state_json",
            "command_template": "brightness_pct:{{ value }}",
            "value_template": "{{ (((value_json.screen.brightness | default(0, true) | int(0)) * 100 / 255) | round(0)) | int(0) }}",
            "min": 0,
            "max": 100,
            "step": 1,
            "unique_id": self._uid("brightness_percent"),
            "availability_topic": self.availability_topic,
            "payload_available": "online",
            "payload_not_available": "offline",
            "device": self.device.__dict__,
        }
        self.client.publish(self._disc_topic("number", "brightness_percent"), json.dumps(number_pct), retain=True)

        # Volume percent (0-100)
        vol_pct = {
            "name": "Android Volume %",
            "command_topic": base_cmd_topic,
            "state_topic": f"{self.cfg.base_topic}/state_json",
            "command_template": "volume_pct:{{ value }}",
            "value_template": "{{ (value_json.audio.music.percent | default(0, true) | round(0) | int(0)) }}",
            "unit_of_measurement": "%",
            "min": 0,
            "max": 100,
            "step": 1,
            "unique_id": self._uid("volume_percent"),
            "availability_topic": self.availability_topic,
            "payload_available": "online",
            "payload_not_available": "offline",
            "device": self.device.__dict__,
        }
        self.client.publish(self._disc_topic("number", "volume_percent"), json.dumps(vol_pct), retain=True)

        # Volume index (0-25 typical; static bounds)
        vol_idx = {
            "name": "Android Volume (index)",
            "command_topic": base_cmd_topic,
            "state_topic": f"{self.cfg.base_topic}/state_json",
            "command_template": "volume_index:{{ value }}",
            "value_template": "{{ (value_json.audio.music.index | default(0, true) | int(0)) }}",
            "min": 0,
            "max": 15,
            "step": 1,
            "unique_id": self._uid("volume_index"),
            "availability_topic": self.availability_topic,
            "payload_available": "online",
            "payload_not_available": "offline",
            "device": self.device.__dict__,
        }
        self.client.publish(self._disc_topic("number", "volume_index"), json.dumps(vol_idx), retain=True)

        # Battery and state topic
        state_topic = f"{self.cfg.base_topic}/state_json"
        if has_battery:
            sensor_payload = {
                "name": "Android Battery Level",
                "state_topic": state_topic,
                "value_template": "{{ value_json.battery.level }}",
                "unit_of_measurement": "%",
                "device_class": "battery",
                "unique_id": self._uid("battery_level"),
                "availability_topic": self.availability_topic,
                "payload_available": "online",
                "payload_not_available": "offline",
                "device": self.device.__dict__,
            }
            self.client.publish(self._disc_topic("sensor", "battery"), json.dumps(sensor_payload), retain=True)

        # CPU usage sensor (user+kernel)
        cpu_sensor = {
            "name": "Android CPU Usage",
            "state_topic": state_topic,
            "value_template": "{{ ((value_json.cpu['user']|default(0)) + (value_json.cpu['kernel']|default(0)))|round(1) }}",
            "unit_of_measurement": "%",
            "unique_id": self._uid("cpu_usage"),
            "availability_topic": self.availability_topic,
            "payload_available": "online",
            "payload_not_available": "offline",
            "device": self.device.__dict__,
        }
        self.client.publish(self._disc_topic("sensor", "cpu_usage"), json.dumps(cpu_sensor), retain=True)

        # Memory used percent
        mem_sensor = {
            "name": "Android Memory Used",
            "state_topic": state_topic,
            "value_template": "{{ value_json.memory_summary.used_percent }}",
            "unit_of_measurement": "%",
            "device_class": "power_factor",
            "unique_id": self._uid("memory_used"),
            "availability_topic": self.availability_topic,
            "payload_available": "online",
            "payload_not_available": "offline",
            "device": self.device.__dict__,
        }
        self.client.publish(self._disc_topic("sensor", "memory_used"), json.dumps(mem_sensor), retain=True)

        # Network type sensor
        net_sensor = {
            "name": "Android Network Type",
            "state_topic": state_topic,
            "value_template": "{{ value_json.network.type | default('unknown') }}",
            "icon": "mdi:lan-connect",
            "unique_id": self._uid("network_type"),
            "availability_topic": self.availability_topic,
            "payload_available": "online",
            "payload_not_available": "offline",
            "device": self.device.__dict__,
        }
        self.client.publish(self._disc_topic("sensor", "network_type"), json.dumps(net_sensor), retain=True)

        # Active app friendly name sensor
        app_sensor = {
            "name": "Android Foreground App",
            "state_topic": f"{self.cfg.base_topic}/active_app",
            "unique_id": self._uid("foreground_app"),
            "availability_topic": self.availability_topic,
            "payload_available": "online",
            "payload_not_available": "offline",
            "device": self.device.__dict__,
        }
        self.client.publish(self._disc_topic("sensor", "foreground_app"), json.dumps(app_sensor), retain=True)

        # Storage used percent (/data)
        storage_sensor = {
            "name": "Android Storage Used",
            "state_topic": state_topic,
            "value_template": "{{ value_json.storage.data.used_percent | default(0) }}",
            "unit_of_measurement": "%",
            "icon": "mdi:database",
            "unique_id": self._uid("storage_used"),
            "availability_topic": self.availability_topic,
            "payload_available": "online",
            "payload_not_available": "offline",
            "device": self.device.__dict__,
        }
        self.client.publish(self._disc_topic("sensor", "storage_used"), json.dumps(storage_sensor), retain=True)

        if has_battery:
            # Battery temperature
            temp_sensor = {
                "name": "Android Battery Temp",
                "state_topic": state_topic,
                "value_template": "{{ value_json.battery.temperature_c }}",
                "unit_of_measurement": "°C",
                "device_class": "temperature",
                "unique_id": self._uid("battery_temp"),
                "availability_topic": self.availability_topic,
                "payload_available": "online",
                "payload_not_available": "offline",
                "device": self.device.__dict__,
            }
            self.client.publish(self._disc_topic("sensor", "battery_temp"), json.dumps(temp_sensor), retain=True)

            # Battery health
            health_sensor = {
                "name": "Android Battery Health",
                "state_topic": state_topic,
                "value_template": "{{ value_json.battery.health_name }}",
                "icon": "mdi:heart-pulse",
                "unique_id": self._uid("battery_health"),
                "availability_topic": self.availability_topic,
                "payload_available": "online",
                "payload_not_available": "offline",
                "device": self.device.__dict__,
            }
            self.client.publish(self._disc_topic("sensor", "battery_health"), json.dumps(health_sensor), retain=True)

        # If previously published WiFi sensors exist, clear them by sending empty retained config
        self.client.publish(self._disc_topic("sensor", "wifi_rssi"), "", retain=True)
        self.client.publish(self._disc_topic("sensor", "wifi_link"), "", retain=True)

        if has_cellular:
            # Cellular signal level
            cell_level = {
                "name": "Android Cell Level",
                "state_topic": state_topic,
                "value_template": "{{ (value_json.network.cellular.level | default(0)) }}",
                "icon": "mdi:signal",
                "unique_id": self._uid("cell_level"),
                "availability_topic": self.availability_topic,
                "payload_available": "online",
                "payload_not_available": "offline",
                "device": self.device.__dict__,
            }
            self.client.publish(self._disc_topic("sensor", "cell_level"), json.dumps(cell_level), retain=True)

        # App select
        select_payload = {
            "name": "Android Active App",
            "command_topic": f"{self.cfg.base_topic}/app_select/set",
            "state_topic": f"{self.cfg.base_topic}/app_select/state",
            "options": app_names,
            "json_attributes_topic": f"{self.cfg.base_topic}/app_select/attributes",
            "unique_id": self._uid("active_app_select"),
            "availability_topic": self.availability_topic,
            "payload_available": "online",
            "payload_not_available": "offline",
            "device": self.device.__dict__,
        }
        self.client.publish(self._disc_topic("select", "active_app"), json.dumps(select_payload), retain=True)

        # Camera entity (MQTT camera)
        if camera:
            cam_payload = {
                "name": "Android Screen Camera",
                "topic": f"{self.cfg.base_topic}/camera/image",
                "image_encoding": "b64",
                "unique_id": self._uid("camera_screen"),
                "availability_topic": self.availability_topic,
                "payload_available": "online",
                "payload_not_available": "offline",
                "device": self.device.__dict__,
            }
            self.client.publish(self._disc_topic("camera", "screen"), json.dumps(cam_payload), retain=True)

    def publish_state(self, state: dict) -> None:
        # Publish JSON aggregate state to state_json to avoid conflicts with simple screen:on/off on state
        self.client.publish(f"{self.cfg.base_topic}/state_json", json.dumps(state), retain=True)

    def publish_screen_simple(self, on: bool, retain: bool = True) -> None:
        """Publish a simple screen status message to <base>/state as 'screen:on/off'.

        WARNING: This will overwrite the retained JSON state on that topic if
        retain=True. Use retain=False to deliver transient updates only.
        """
        payload = "screen:on" if on else "screen:off"
        self.client.publish(f"{self.cfg.base_topic}/state", payload, retain=retain)

    def publish_app_attributes(self, options: list[str], mapping: dict[str, str], installed: dict[str, bool] | None = None, active: str | None = None) -> None:
        attrs = {"options": options, "mapping": mapping}
        if installed is not None:
            attrs["installed"] = installed
        if active is not None:
            attrs["active"] = active
        self.client.publish(f"{self.cfg.base_topic}/app_select/attributes", json.dumps(attrs), retain=True)

    def start_mosquitto_sub(self, on_message: Callable[[str], None]) -> subprocess.Popen:
        # Use mosquitto_sub CLI: subscribe to base_topic/cmd and app_select/set
        topic_cmd = f"{self.cfg.base_topic}/cmd"
        topic_app = f"{self.cfg.base_topic}/app_select/set"
        cmd = [
            "mosquitto_sub",
            "-h",
            self.cfg.host,
            "-p",
            str(self.cfg.port),
            "-t",
            topic_cmd,
            "-t",
            topic_app,
            "-v",
        ]
        if self.cfg.username:
            cmd += ["-u", self.cfg.username]
        if self.cfg.password:
            cmd += ["-P", self.cfg.password]
        return subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    def publish_app_state(self, name: str) -> None:
        self.client.publish(f"{self.cfg.base_topic}/app_select/state", name, retain=True)

    def publish_camera_image(self, image_bytes: bytes) -> None:
        import base64
        # enforce size guard to avoid broker disconnects on very large payloads
        if self.max_image_bytes is not None and len(image_bytes) > self.max_image_bytes:
            # publish a small stub state instead of the image
            try:
                self.client.publish(f"{self.cfg.base_topic}/camera/info", json.dumps({"skipped": True, "bytes": len(image_bytes)}), retain=False)
            except Exception:
                pass
            return
        b64 = base64.b64encode(image_bytes).decode()
        # Do not retain large images by default; HA camera will still receive updates
        self.client.publish(f"{self.cfg.base_topic}/camera/image", b64, retain=self.retain_images)

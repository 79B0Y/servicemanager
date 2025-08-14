from __future__ import annotations

import asyncio
import json
from pathlib import Path
from typing import Optional

import uvicorn

from .api.main import app, adb, monitor, shots, cache, settings
from .mqtt.ha import HAIntegration
from .mqtt.state import set_ha
from . import __version__


def _maybe_compress_image(raw: bytes) -> bytes:
    """Compress screenshot using Pillow if available and enabled.
    Falls back to original bytes on any error.
    """
    cfg = settings.device
    if not getattr(cfg, "camera_compress", True):
        return raw
    try:
        from io import BytesIO
        from PIL import Image

        with Image.open(BytesIO(raw)) as im:
            # Convert to RGB for JPEG
            fmt = getattr(cfg, "camera_format", "jpeg").lower()
            if fmt == "jpeg" and im.mode not in ("RGB", "L"):
                im = im.convert("RGB")
            # Resize if max dims provided
            max_w = getattr(cfg, "camera_max_width", None)
            max_h = getattr(cfg, "camera_max_height", None)
            if max_w or max_h:
                # Use thumbnail to preserve aspect ratio
                size = (max_w or im.width, max_h or im.height)
                im.thumbnail(size)
            buf = BytesIO()
            if fmt == "png":
                im.save(buf, format="PNG", optimize=True)
            else:
                quality = max(1, min(100, int(getattr(cfg, "camera_quality", 70))))
                im.save(buf, format="JPEG", quality=quality, optimize=True, progressive=True)
            return buf.getvalue()
    except Exception:
        return raw

async def mqtt_worker() -> None:
    ha = HAIntegration(
        settings.mqtt,
        device_id=settings.device.device_id,
        device_name=settings.device.device_name,
        max_image_bytes=getattr(settings.device, "camera_max_bytes", None),
        retain_images=getattr(settings.device, "camera_retain", False),
    )
    # Ensure availability/state on reconnect and subscriptions are restored
    topic_cmd = f"{settings.mqtt.base_topic}/cmd"
    topic_app = f"{settings.mqtt.base_topic}/app_select/set"

    def _on_connect(client, userdata, flags, rc):
        try:
            ha.publish_availability(True)
            client.subscribe(topic_cmd)
            client.subscribe(topic_app)
        except Exception:
            pass

    ha.client.on_connect = _on_connect
    ha.connect()
    ha.publish_availability(True)
    # Use visible subset if configured; otherwise all app names
    app_names = settings.appmap.visible or list(settings.appmap.apps.keys())
    # Clear old discovery (helps after manual device removal in HA)
    ha.clear_discovery(app_names)
    ha.publish_discovery(
        app_names,
        has_battery=settings.device.has_battery,
        has_cellular=settings.device.has_cellular,
        camera=settings.device.camera_enabled,
    )
    set_ha(ha)
    ha.publish_app_attributes(app_names, settings.appmap.apps)
    # Immediately publish initial metrics/state so HA numbers get values
    try:
        m = await monitor.snapshot()
        await cache.set_json("metrics", m, ttl=20)
        ha.publish_state(m)
        info = await adb.top_app()
        active_pkg = info.get("package")
        active_name = None
        for name, pkg in settings.appmap.apps.items():
            if pkg == active_pkg:
                active_name = name
                break
        if active_name:
            ha.publish_app_state(active_name)
        ha.client.publish(f"{settings.mqtt.base_topic}/active_app", active_name or "", retain=True)
    except Exception:
        pass

    # Subscribe to command topics via paho-mqtt
    # topics defined above
    queue: asyncio.Queue[tuple[str, str]] = asyncio.Queue()
    loop = asyncio.get_running_loop()

    def _on_message(client, userdata, msg):
        try:
            payload = msg.payload.decode()
        except Exception:
            payload = ""
        loop.call_soon_threadsafe(queue.put_nowait, (msg.topic, payload))

    ha.client.on_message = _on_message
    ha.client.subscribe(topic_cmd)
    ha.client.subscribe(topic_app)

    async def reader() -> None:
        while True:
            topic, payload = await queue.get()
            await handle_command(topic, payload, ha)

    async def publisher() -> None:
        while True:
            try:
                m = await monitor.snapshot()
                await cache.set_json("metrics", m, ttl=20)
                ha.publish_state(m)
                # publish active app state
                info = await adb.top_app()
                active_pkg = info.get("package")
                # map package -> friendly name if exists (prefer visible naming)
                active_name = None
                for name, pkg in settings.appmap.apps.items():
                    if pkg == active_pkg:
                        active_name = name
                        break
                if active_name:
                    ha.publish_app_state(active_name)
                # publish friendly name to active_app sensor (avoid showing package)
                ha.client.publish(f"{settings.mqtt.base_topic}/active_app", active_name or "", retain=True)
                # periodically republish attributes (options/mapping)
                try:
                    installed_pkgs = set(await adb.list_packages())
                except Exception:
                    installed_pkgs = set()
                installed_map = {name: (pkg in installed_pkgs) for name, pkg in settings.appmap.apps.items()}
                ha.publish_app_attributes(app_names, settings.appmap.apps, installed=installed_map, active=active_name)

                # Publish camera image periodically if enabled: save and rotate, then publish
                if settings.device.camera_enabled:
                    try:
                        p = await shots.capture()
                        # read file and publish
                        img = Path(p).read_bytes()
                        img_c = _maybe_compress_image(img)
                        ha.publish_camera_image(img_c)
                    except Exception:
                        pass
            except Exception:
                pass
            # sleep: smaller of metrics interval (15s) and screenshot interval
            interval = settings.device.screenshot_interval if getattr(settings.device, 'screenshot_interval', None) is not None else settings.device.camera_interval
            delay = min(15, max(1, interval))
            await asyncio.sleep(delay)

    async def app_watcher() -> None:
        if not getattr(settings.device, "app_watch_enabled", True):
            return
        # build reverse mapping package -> name for quick lookup
        reverse_map = {pkg: name for name, pkg in settings.appmap.apps.items()}
        last_name = None
        last_pkg = None
        while True:
            try:
                info = await adb.top_app()
                active_pkg = info.get("package")
                active_name = reverse_map.get(active_pkg)
                if active_pkg != last_pkg:
                    # publish friendly name and select state
                    ha.client.publish(f"{settings.mqtt.base_topic}/active_app", active_name or "", retain=True)
                    if active_name:
                        ha.publish_app_state(active_name)
                    last_pkg = active_pkg
                    last_name = active_name
            except Exception:
                pass
            await asyncio.sleep(max(1, int(getattr(settings.device, "app_poll_interval", 2))))

    await asyncio.gather(reader(), publisher(), app_watcher())


async def handle_command(topic: str | None, payload: str, ha: HAIntegration) -> None:
    # Supported: nav:up|down|left|right|center|home|back ; volume:up|down|mute ; screen:toggle|on|off ; app:start|stop|switch:<name>
    try:
        if payload.startswith("nav:"):
            _, act = payload.split(":", 1)
            await adb.nav(act)
        elif payload.startswith("volume:"):
            _, act = payload.split(":", 1)
            await adb.volume(act)
        elif payload.startswith("volume_pct:"):
            _, val = payload.split(":", 1)
            try:
                await adb.set_volume_percent(int(val))
            except Exception:
                return
        elif payload.startswith("volume_index:"):
            _, val = payload.split(":", 1)
            try:
                await adb.set_volume_index(int(val))
            except Exception:
                return
        elif payload.startswith("screen:"):
            _, act = payload.split(":", 1)
            await adb.screen(act)
        elif payload.startswith("brightness:"):
            _, val = payload.split(":", 1)
            await adb.set_brightness(int(val))
        elif payload.startswith("brightness_pct:"):
            _, val = payload.split(":", 1)
            try:
                pct = int(val)
                pct = max(0, min(100, pct))
                br = round(pct * 255 / 100)
                await adb.set_brightness(int(br))
            except Exception:
                return
        elif payload.startswith("app:"):
            parts = payload.split(":", 2)
            if len(parts) != 3:
                return
            _, act, name = parts
            pkg = settings.appmap.apps.get(name)
            if not pkg:
                return
            if act == "start":
                await adb.launch_app(pkg)
            elif act == "stop":
                await adb.stop_app(pkg)
            elif act == "switch":
                await adb.switch_app(pkg)
                ha.publish_app_state(name)
        elif topic and topic.endswith("/app_select/set"):
            # payload is the selected friendly name
            name = payload.strip()
            pkg = settings.appmap.apps.get(name)
            if pkg:
                await adb.switch_app(pkg)
                ha.publish_app_state(name)
        elif payload == "screenshot":
            p = await shots.capture()
            ha.publish_state({"last_screenshot": str(p)})
            # Camera image publish may be skipped for very large payloads by guard
            try:
                img = Path(p).read_bytes()
                img_c = _maybe_compress_image(img)
                ha.publish_camera_image(img_c)
            except Exception:
                pass
    except Exception:
        # swallow errors for robustness
        return


async def serve() -> None:
    # Use configurable API host/port
    config = uvicorn.Config(app, host=getattr(settings.api, "host", "0.0.0.0"), port=getattr(settings.api, "port", 8000), log_level="info")
    server = uvicorn.Server(config)
    await adb.connect()
    await asyncio.gather(server.serve(), mqtt_worker())


def main() -> None:
    asyncio.run(serve())


if __name__ == "__main__":
    main()

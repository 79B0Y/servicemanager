from __future__ import annotations

import asyncio
import json
import logging
from pathlib import Path
from typing import Optional, Dict, Any, TYPE_CHECKING
from contextlib import asynccontextmanager
from types import SimpleNamespace

# Optional imports so the module can be imported without full runtime deps
try:  # pragma: no cover - best effort import
    import uvicorn  # type: ignore
except Exception:  # ImportError or runtime issues
    uvicorn = None  # type: ignore

try:  # pragma: no cover
    from .api.main import create_app
except Exception:
    create_app = None  # type: ignore

# Only import MQTT integrations for type checking to avoid hard runtime deps
if TYPE_CHECKING:  # pragma: no cover
    from .mqtt.ha import HAIntegration  # noqa: F401
    from .mqtt.state import set_ha  # noqa: F401
from .core.adb import ADBError
from . import __version__


# Initialize app lazily to support import in minimal environments (e.g., tests)
if create_app is not None:
    try:
        app = create_app()
        settings = app.state.settings
        adb = app.state.adb
        monitor = app.state.monitor
        shots = app.state.shots
        cache = app.state.cache
    except Exception:
        # Fall back to placeholders if app creation fails (dependencies missing)
        app = SimpleNamespace(state=SimpleNamespace())  # type: ignore
        settings = SimpleNamespace()  # type: ignore
        adb = None  # type: ignore
        monitor = None  # type: ignore
        shots = None  # type: ignore
        cache = None  # type: ignore
else:
    app = SimpleNamespace(state=SimpleNamespace())  # type: ignore
    settings = SimpleNamespace()  # type: ignore
    adb = None  # type: ignore
    monitor = None  # type: ignore
    shots = None  # type: ignore
    cache = None  # type: ignore

logger = logging.getLogger(__name__)


class ImageProcessor:
    """Optimized image processing with caching and better error handling."""
    
    def __init__(self, device_config):
        self.config = device_config
        self._pil_available = None
        self._check_pil_availability()
    
    def _check_pil_availability(self) -> bool:
        """Check if PIL is available and cache the result."""
        if self._pil_available is None:
            try:
                from PIL import Image
                self._pil_available = True
            except ImportError:
                self._pil_available = False
                logger.warning("PIL not available, image compression disabled")
        return self._pil_available
    
    def compress_image(self, raw: bytes) -> bytes:
        """Compress image with optimized processing and error handling."""
        if not getattr(self.config, "camera_compress", True):
            return raw
        
        if not self._check_pil_availability():
            return raw
        
        try:
            from io import BytesIO
            from PIL import Image
            
            # Validate input
            if not raw or len(raw) < 100:  # Minimum viable image size
                logger.warning("Image data too small, skipping compression")
                return raw
            
            with Image.open(BytesIO(raw)) as im:
                # Get compression settings
                fmt = getattr(self.config, "camera_format", "jpeg").lower()
                quality = max(1, min(100, int(getattr(self.config, "camera_quality", 70))))
                max_w = getattr(self.config, "camera_max_width", None)
                max_h = getattr(self.config, "camera_max_height", None)
                
                # Convert color mode if needed
                if fmt == "jpeg" and im.mode not in ("RGB", "L"):
                    im = im.convert("RGB")
                
                # Resize if dimensions specified
                if max_w or max_h:
                    original_size = im.size
                    size = (max_w or im.width, max_h or im.height)
                    im.thumbnail(size, Image.Resampling.LANCZOS)
                    logger.debug("Image resized from %s to %s", original_size, im.size)
                
                # Compress and save
                buf = BytesIO()
                if fmt == "png":
                    im.save(buf, format="PNG", optimize=True)
                else:
                    im.save(buf, format="JPEG", quality=quality, optimize=True, progressive=True)
                
                compressed = buf.getvalue()
                compression_ratio = len(compressed) / len(raw)
                logger.debug("Image compressed: %d -> %d bytes (%.1f%% of original)", 
                           len(raw), len(compressed), compression_ratio * 100)
                
                return compressed
                
        except Exception as e:
            logger.warning("Image compression failed: %s", e)
            return raw


# Global image processor instance
_image_processor = None

def get_image_processor():
    """Get global image processor instance."""
    global _image_processor
    if _image_processor is None:
        _image_processor = ImageProcessor(settings.device)
    return _image_processor

def _maybe_compress_image(raw: bytes) -> bytes:
    """Compress screenshot using optimized image processor."""
    return get_image_processor().compress_image(raw)


async def publish_screen_state(ha) -> None:
    """Update cached metrics with current screen state and publish."""
    screen_info = {}
    
    # Gather screen info in parallel
    tasks = {
        'screen_on': adb.screen_state(),
        'brightness': adb.get_brightness()
    }
    
    async def safe_gather(name: str, coro):
        try:
            return name, await coro
        except ADBError as e:
            logger.debug("ADB error getting %s: %s", name, e)
            return name, None
        except Exception as e:
            logger.warning("Error getting %s: %s", name, e)
            return name, None
    
    results = await asyncio.gather(
        *[safe_gather(name, task) for name, task in tasks.items()]
    )
    
    # Process results
    for name, value in results:
        if value is not None:
            if name == 'screen_on':
                screen_info['on'] = value
            elif name == 'brightness':
                screen_info['brightness'] = value
    
    if not screen_info:
        return  # No data to update
    
    # Update cache and publish
    try:
        # cache is injected during tests; guard for None in minimal envs
        if cache is None:
            return
        metrics = await cache.get_json("metrics") or {}
        metrics.setdefault("screen", {}).update(screen_info)
        
        # Update cache and publish in parallel
        await asyncio.gather(
            cache.set_json("metrics", metrics, ttl=20),
            asyncio.to_thread(ha.publish_state, metrics),
            return_exceptions=True
        )
        # Also publish simple screen:on/off message on <base>/state as requested
        try:
            on = metrics.get("screen", {}).get("on")
            if isinstance(on, bool):
                # Publish as retained to match user's expectation of last-known state
                await asyncio.to_thread(ha.publish_screen_simple, on, True)
        except Exception:
            pass
    except Exception as e:
        logger.debug("Failed to update screen state cache/publish: %s", e)


async def publish_audio_state(ha) -> None:
    """Update cached metrics with current audio info and publish."""
    try:
        if cache is None:
            return
        try:
            audio = await adb._get_audio_info()  # reuse helper to format
        except Exception:
            return
        if not audio:
            return
        metrics = await cache.get_json("metrics") or {}
        metrics["audio"] = audio
        await asyncio.gather(
            cache.set_json("metrics", metrics, ttl=20),
            asyncio.to_thread(ha.publish_state, metrics),
            return_exceptions=True,
        )
    except Exception as e:
        logger.debug("Failed to update audio state cache/publish: %s", e)


async def screen_watcher(ha: HAIntegration) -> None:
    """Periodically publish screen state with optimized error handling."""
    poll_interval = max(1, int(getattr(settings.device, "screen_poll_interval", 5)))
    error_count = 0
    max_errors = 5
    
    logger.info("Starting screen watcher with %ds interval", poll_interval)
    
    while True:
        try:
            await publish_screen_state(ha)
            error_count = 0  # Reset on success
        except Exception as e:
            error_count += 1
            if error_count <= max_errors:
                logger.warning("Screen watcher error (%d/%d): %s", error_count, max_errors, e)
            elif error_count == max_errors + 1:
                logger.error("Screen watcher: too many consecutive errors, reducing log level")
            
            # Exponential backoff on repeated errors
            if error_count > 3:
                await asyncio.sleep(min(poll_interval * 2, 30))
                continue
        
        await asyncio.sleep(poll_interval)

async def mqtt_worker() -> None:
    # Import at runtime to avoid dependency at import time
    from .mqtt.ha import HAIntegration
    from .mqtt.state import set_ha

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
    # Clear old discovery (helps after manual device removal in HA)
    initial_app_names = settings.appmap.visible or list(settings.appmap.apps.keys())
    ha.clear_discovery(initial_app_names)
    ha.publish_discovery(
        initial_app_names,
        has_battery=settings.device.has_battery,
        has_cellular=settings.device.has_cellular,
        camera=settings.device.camera_enabled,
    )
    set_ha(ha)
    app_names = settings.appmap.visible or list(settings.appmap.apps.keys())
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
        """Process MQTT commands with improved error handling."""
        logger.info("Starting MQTT command reader")
        
        while True:
            try:
                topic, payload = await queue.get()
                await handle_command(topic, payload, ha)
                queue.task_done()
            except asyncio.CancelledError:
                logger.info("MQTT reader cancelled")
                break
            except Exception as e:
                logger.error("Error processing MQTT command: %s", e)
                # Continue processing other commands

    async def publisher() -> None:
        """Optimized publisher with parallel execution and better error handling."""
        cached_metrics: Optional[Dict[str, Any]] = None
        error_count = 0
        max_errors = 5
        
        logger.info("Starting MQTT publisher")
        
        while True:
            try:
                # Gather data in parallel where possible
                metrics_task = monitor.snapshot()
                app_info_task = adb.top_app()
                
                # Get metrics first (most important)
                try:
                    m = await metrics_task
                    cached_metrics = m
                    error_count = 0  # Reset on success
                except Exception as e:
                    logger.warning("monitor.snapshot failed: %s", e)
                    error_count += 1
                    
                    if cached_metrics is None:
                        try:
                            cached_metrics = await cache.get_json("metrics")
                        except Exception:
                            logger.debug("Failed to load cached metrics")
                    m = cached_metrics or {}
                
                # Parallel execution of cache and publish
                await asyncio.gather(
                    cache.set_json("metrics", m, ttl=20),
                    asyncio.to_thread(ha.publish_state, m),
                    return_exceptions=True
                )
                
                # Get app info
                active_name = None
                try:
                    info = await app_info_task
                    active_pkg = info.get("package")
                    
                    # Use dict.get for faster lookup
                    pkg_to_name = {pkg: name for name, pkg in settings.appmap.apps.items()}
                    active_name = pkg_to_name.get(active_pkg)
                    
                    if active_name:
                        await asyncio.gather(
                            asyncio.to_thread(ha.publish_app_state, active_name),
                            asyncio.to_thread(
                                ha.client.publish, 
                                f"{settings.mqtt.base_topic}/active_app", 
                                active_name or "", 
                                retain=True
                            ),
                            return_exceptions=True
                        )
                except Exception as e:
                    logger.debug("Failed to get/publish app info: %s", e)
                
                # Handle package listing and camera in parallel
                tasks = []
                
                # Package listing task
                async def get_packages():
                    try:
                        return set(await adb.list_packages())
                    except Exception as e:
                        logger.debug("adb.list_packages failed: %s", e)
                        return set()
                
                tasks.append(get_packages())
                
                # Camera task if enabled
                if settings.device.camera_enabled:
                    async def capture_and_publish():
                        try:
                            # Use screenshot_bytes for better performance
                            img_data = await adb.screenshot_bytes()
                            if img_data:
                                img_compressed = _maybe_compress_image(img_data)
                                await asyncio.to_thread(ha.publish_camera_image, img_compressed)
                                logger.debug("Camera image published (%d bytes)", len(img_compressed))
                        except Exception as e:
                            logger.debug("Camera capture/publish failed: %s", e)
                    
                    tasks.append(capture_and_publish())
                
                # Execute tasks in parallel
                results = await asyncio.gather(*tasks, return_exceptions=True)
                
                # Process package listing result
                if results:
                    installed_pkgs = results[0] if not isinstance(results[0], Exception) else set()
                    installed_map = {name: (pkg in installed_pkgs) for name, pkg in settings.appmap.apps.items()}
                    
                    try:
                        await asyncio.to_thread(
                            ha.publish_app_attributes, 
                            app_names, 
                            settings.appmap.apps, 
                            installed=installed_map, 
                            active=active_name
                        )
                    except Exception as e:
                        logger.debug("Failed to publish app attributes: %s", e)
                
                # Calculate optimal delay
                interval = getattr(settings.device, 'screenshot_interval', None)
                if interval is None:
                    interval = getattr(settings.device, 'camera_interval', 10)
                
                delay = min(15, max(1, int(interval)))
                
                # Exponential backoff on repeated errors
                if error_count > 3:
                    delay = min(delay * 2, 30)
                    
                await asyncio.sleep(delay)
                
            except asyncio.CancelledError:
                logger.info("Publisher cancelled")
                break
            except Exception as e:
                error_count += 1
                if error_count <= max_errors:
                    logger.error("Publisher error (%d/%d): %s", error_count, max_errors, e)
                elif error_count == max_errors + 1:
                    logger.error("Publisher: too many consecutive errors, reducing log level")
                
                await asyncio.sleep(min(10, error_count))

    async def app_watcher() -> None:
        """Optimized app watcher with improved change detection."""
        if not getattr(settings.device, "app_watch_enabled", True):
            logger.info("App watcher disabled")
            return
        
        # Build reverse mapping for fast lookup
        reverse_map = {pkg: name for name, pkg in settings.appmap.apps.items()}
        last_name = None
        last_pkg = None
        error_count = 0
        max_errors = 5
        poll_interval = max(1, int(getattr(settings.device, "app_poll_interval", 2)))
        
        logger.info("Starting app watcher with %ds interval", poll_interval)
        
        while True:
            try:
                info = await adb.top_app()
                active_pkg = info.get("package")
                active_name = reverse_map.get(active_pkg)
                
                # Only publish on changes
                if active_pkg != last_pkg:
                    logger.debug("App changed: %s -> %s (%s)", last_name, active_name, active_pkg)
                    
                    # Publish changes in parallel
                    tasks = [
                        asyncio.to_thread(
                            ha.client.publish, 
                            f"{settings.mqtt.base_topic}/active_app", 
                            active_name or "", 
                            retain=True
                        )
                    ]
                    
                    if active_name:
                        tasks.append(asyncio.to_thread(ha.publish_app_state, active_name))
                    
                    await asyncio.gather(*tasks, return_exceptions=True)
                    
                    last_pkg = active_pkg
                    last_name = active_name
                
                error_count = 0  # Reset on success
                
            except ADBError as e:
                error_count += 1
                if error_count <= max_errors:
                    logger.debug("ADB error in app watcher (%d/%d): %s", error_count, max_errors, e)
            except Exception as e:
                error_count += 1
                if error_count <= max_errors:
                    logger.warning("App watcher error (%d/%d): %s", error_count, max_errors, e)
                elif error_count == max_errors + 1:
                    logger.error("App watcher: too many consecutive errors, reducing log level")
            
            # Exponential backoff on errors
            sleep_time = poll_interval
            if error_count > 3:
                sleep_time = min(poll_interval * 2, 10)
            
            await asyncio.sleep(sleep_time)

    # Start all tasks with proper error handling
    tasks = [
        asyncio.create_task(reader(), name="mqtt-reader"),
        asyncio.create_task(publisher(), name="mqtt-publisher"),
        asyncio.create_task(app_watcher(), name="app-watcher"),
        asyncio.create_task(screen_watcher(ha), name="screen-watcher")
    ]
    
    try:
        await asyncio.gather(*tasks)
    except Exception as e:
        logger.error("MQTT worker task failed: %s", e)
        # Cancel remaining tasks
        for task in tasks:
            if not task.done():
                task.cancel()
        raise


def _to_int(val: str, *, clamp: tuple[int, int] | None = None) -> int:
    try:
        num = int(val)
    except Exception:
        num = int(round(float(val)))
    if clamp:
        lo, hi = clamp
        if num < lo:
            num = lo
        if num > hi:
            num = hi
    return num


async def handle_command(topic: str | None, payload: str, ha: HAIntegration) -> None:
    """Handle MQTT commands with optimized processing and validation."""
    if not payload or not payload.strip():
        return
    
    payload = payload.strip()
    logger.debug("Processing command: %s (topic: %s)", payload, topic)
    
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
                pct = _to_int(val, clamp=(0, 100))
                await adb.set_volume_percent(pct)
                await publish_audio_state(ha)
            except Exception:
                return
        elif payload.startswith("volume_index:"):
            _, val = payload.split(":", 1)
            try:
                idx = _to_int(val)
                await adb.set_volume_index(idx)
                await publish_audio_state(ha)
            except Exception:
                return
        elif payload.startswith("screen:"):
            _, act = payload.split(":", 1)
            await adb.screen(act)
            # Immediately publish simple screen:on/off message as requested
            try:
                on = act.strip().lower() == "on"
                await asyncio.to_thread(ha.publish_screen_simple, on, True)
            except Exception:
                pass
            # Immediately publish latest screen state for responsive HA switch
            try:
                await publish_screen_state(ha)
            except Exception:
                pass
        elif payload.startswith("brightness:"):
            _, val = payload.split(":", 1)
            try:
                await adb.set_brightness(_to_int(val, clamp=(0, 255)))
                await publish_screen_state(ha)
            except Exception:
                return
        elif payload.startswith("brightness_pct:"):
            _, val = payload.split(":", 1)
            try:
                pct = _to_int(val, clamp=(0, 100))
                br = round(pct * 255 / 100)
                await adb.set_brightness(int(br))
                await publish_screen_state(ha)
            except Exception:
                return
        elif payload in ("report", "state", "metrics"):
            # Force a full metrics snapshot and publish immediately
            try:
                if monitor is None or cache is None:
                    return
                m = await monitor.snapshot()
                await cache.set_json("metrics", m, ttl=20)
                ha.publish_state(m)
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
    try:
        await asyncio.gather(server.serve(), mqtt_worker())
    finally:
        await cache.close()


def main() -> None:
    asyncio.run(serve())


if __name__ == "__main__":
    main()

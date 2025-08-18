from __future__ import annotations

from pathlib import Path
from typing import Optional

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import yaml

from ..core.adb import ADBController
from ..models.config import Settings, CONFIG_DIR
from ..services.monitor import MonitorService
from ..services.screenshot import ScreenshotService
from ..services.cache import Cache
from ..mqtt.state import get_ha


def create_app() -> FastAPI:
    settings = Settings.load()
    adb = ADBController(
        host=settings.device.adb_host,
        port=settings.device.adb_port,
        serial=settings.device.adb_serial,
        has_battery=settings.device.has_battery,
        has_cellular=settings.device.has_cellular,
    )
    monitor = MonitorService(adb)
    shots = ScreenshotService(
        adb, Path.cwd() / settings.device.screenshots_dir, keep=settings.device.screenshot_keep
    )
    cache = Cache()

    app = FastAPI(title="ISG Android Controller API")
    app.state.settings = settings
    app.state.adb = adb
    app.state.monitor = monitor
    app.state.shots = shots
    app.state.cache = cache

    @app.on_event("startup")
    async def _startup() -> None:
        await adb.connect()

    @app.on_event("shutdown")
    async def _shutdown() -> None:
        await cache.close()

    @app.get("/health")
    async def health() -> dict:
        return {"ok": True}

    @app.post("/nav/{action}")
    async def nav(action: str) -> dict:
        await adb.nav(action)
        return {"status": "ok"}

    @app.post("/volume/{direction}")
    async def volume(direction: str) -> dict:
        await adb.volume(direction)
        return {"status": "ok"}

    @app.post("/brightness")
    async def brightness(value: int) -> dict:
        await adb.set_brightness(value)
        return {"status": "ok"}

    @app.post("/screen/{action}")
    async def screen(action: str) -> dict:
        await adb.screen(action)
        return {"status": "ok"}

    @app.post("/apps/{action}/{name}")
    async def apps(action: str, name: str) -> dict:
        pkg = settings.appmap.apps.get(name)
        if not pkg:
            raise HTTPException(404, f"unknown app: {name}")
        if action == "start":
            await adb.launch_app(pkg)
        elif action in ("stop", "kill"):
            await adb.stop_app(pkg)
        elif action in ("switch", "focus"):
            await adb.switch_app(pkg)
        else:
            raise HTTPException(400, "action must be start/stop/switch")
        return {"status": "ok"}

    @app.get("/metrics")
    async def metrics() -> dict:
        cached = await cache.get_json("metrics")
        if cached:
            return cached
        m = await monitor.snapshot()
        await cache.set_json("metrics", m, ttl=10)
        return m

    @app.post("/screenshot")
    async def screenshot() -> dict:
        path = await shots.capture()
        return {"path": str(path)}

    @app.get("/apps")
    async def list_known_apps() -> dict:
        return {"apps": settings.appmap.apps}

    @app.get("/apps/installed")
    async def list_installed(pattern: str | None = None) -> dict:
        pkgs = await adb.list_packages(pattern)
        return {"packages": pkgs}

    @app.get("/apps/foreground")
    async def foreground_app() -> dict:
        info = await adb.top_app()
        return info

    @app.get("/apps/status")
    async def apps_status() -> dict:
        installed = set(await adb.list_packages())
        mapping = settings.appmap.apps
        items = []
        active = await adb.top_app()
        active_pkg = active.get("package")
        active_name = None
        for name, pkg in mapping.items():
            if pkg == active_pkg:
                active_name = name
            items.append({"name": name, "package": pkg, "installed": pkg in installed})
        return {"apps": items, "active": {"name": active_name, "package": active_pkg}}

    @app.get("/apps/options")
    async def apps_options() -> dict:
        visible = settings.appmap.visible or list(settings.appmap.apps.keys())
        installed_pkgs = set(await adb.list_packages())
        installed_map = {name: (pkg in installed_pkgs) for name, pkg in settings.appmap.apps.items()}
        info = await adb.top_app()
        active_pkg = info.get("package")
        active_name = next((n for n, p in settings.appmap.apps.items() if p == active_pkg), None)
        return {
            "options": visible,
            "mapping": settings.appmap.apps,
            "installed": installed_map,
            "active": active_name,
        }

    @app.post("/ha/refresh")
    async def ha_refresh() -> dict:
        ha = get_ha()
        if not ha:
            return {"ok": False, "error": "HA integration not started"}
        options = settings.appmap.visible or list(settings.appmap.apps.keys())
        ha.clear_discovery(options)
        installed_map: dict[str, bool] = {}
        active_name: Optional[str] = None
        try:
            installed_pkgs = set(await adb.list_packages())
            installed_map = {name: (pkg in installed_pkgs) for name, pkg in settings.appmap.apps.items()}
            info = await adb.top_app()
            active_pkg = info.get("package")
            active_name = next((n for n, p in settings.appmap.apps.items() if p == active_pkg), None)
        except Exception:
            pass
        finally:
            ha.publish_discovery(
                options,
                has_battery=settings.device.has_battery,
                has_cellular=settings.device.has_cellular,
            )
            ha.publish_app_attributes(
                options,
                settings.appmap.apps,
                installed=installed_map,
                active=active_name,
            )
        return {"ok": True, "options": options, "active": active_name}

    class OptionsUpdate(BaseModel):
        options: list[str]

    @app.post("/ha/options")
    async def ha_update_options(payload: OptionsUpdate) -> dict:
        all_names = list(settings.appmap.apps.keys())
        invalid = [o for o in payload.options if o not in all_names]
        if invalid:
            raise HTTPException(400, f"unknown app names: {invalid}")

        apps_file = CONFIG_DIR / "apps.yaml"
        data = {"apps": settings.appmap.apps, "visible": payload.options}
        try:
            with open(apps_file, "w", encoding="utf-8") as f:
                yaml.safe_dump(data, f, allow_unicode=True, sort_keys=False)
        except Exception as e:
            raise HTTPException(500, f"failed to write {apps_file}: {e}")

        settings.appmap.visible = payload.options
        ha = get_ha()
        if ha:
            try:
                installed_pkgs = set(await adb.list_packages())
            except Exception:
                installed_pkgs = set()
            installed_map = {name: (pkg in installed_pkgs) for name, pkg in settings.appmap.apps.items()}
            info = await adb.top_app()
            active_pkg = info.get("package")
            active_name = next((n for n, p in settings.appmap.apps.items() if p == active_pkg), None)
            ha.publish_discovery(
                payload.options,
                has_battery=settings.device.has_battery,
                has_cellular=settings.device.has_cellular,
            )
            ha.publish_app_attributes(
                payload.options,
                settings.appmap.apps,
                installed=installed_map,
                active=active_name,
            )
        return {"ok": True, "options": payload.options}

    @app.get("/battery")
    async def battery() -> dict:
        m = await monitor.snapshot()
        return m.get("battery", {})

    @app.get("/network")
    async def network() -> dict:
        m = await monitor.snapshot()
        return m.get("network", {})

    @app.get("/audio")
    async def audio() -> dict:
        try:
            # Use the new comprehensive audio info method
            full_info = await adb.audio_full_info()
            return full_info
        except Exception:
            # Fallback to old method for compatibility
            info = await adb.audio_music_info()
            pct = None
            if info.get("max"):
                try:
                    pct = round(info.get("current", 0) * 100 / info.get("max"))
                except Exception:
                    pct = None
            return {"music": {"index": info.get("current"), "max": info.get("max"), "percent": pct}}

    @app.post("/volume_pct")
    async def set_volume_pct(value: int) -> dict:
        await adb.set_volume_percent(value)
        return {"status": "ok"}

    @app.post("/volume_index")
    async def set_volume_index(value: int) -> dict:
        await adb.set_volume_index(value)
        return {"status": "ok"}

    @app.get("/screen")
    async def get_screen_status() -> dict:
        try:
            is_on = await adb.screen_state()
            brightness = await adb.get_brightness()
            return {
                "on": is_on,
                "brightness": brightness,
                "status": "on" if is_on else "off"
            }
        except Exception as e:
            return {
                "on": None,
                "brightness": None,
                "status": "unknown",
                "error": str(e)
            }

    @app.get("/brightness")
    async def get_brightness() -> dict:
        try:
            brightness = await adb.get_brightness()
            return {"brightness": brightness}
        except Exception as e:
            return {"brightness": None, "error": str(e)}

    # Add comprehensive volume control endpoints
    @app.post("/volume/music/percent")
    async def set_music_volume_percent(value: int) -> dict:
        await adb.set_volume_percent(value)
        return {"status": "ok", "volume_percent": value}

    @app.post("/volume/music/index")
    async def set_music_volume_index(value: int) -> dict:
        await adb.set_volume_index(value)
        return {"status": "ok", "volume_index": value}

    return app


app = create_app()


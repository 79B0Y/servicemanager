from __future__ import annotations

import asyncio
from typing import List, Optional
import re


class ADBController:
    def __init__(self, host: str = "127.0.0.1", port: int = 5555, serial: Optional[str] = None, has_battery: bool = False, has_cellular: bool = False) -> None:
        self.host = host
        self.port = port
        self.serial = serial
        self.has_battery = has_battery
        self.has_cellular = has_cellular

    def _target(self) -> List[str]:
        if self.serial:
            return ["-s", self.serial]
        return ["-s", f"{self.host}:{self.port}"]

    async def _run(self, *args: str, timeout: float = 15.0) -> str:
        cmd = ["adb", *self._target(), *args]
        proc = await asyncio.create_subprocess_exec(
            *cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
        )
        try:
            out, err = await asyncio.wait_for(proc.communicate(), timeout=timeout)
        except asyncio.TimeoutError:
            proc.kill()
            raise
        if proc.returncode != 0:
            raise RuntimeError(f"ADB failed: {' '.join(cmd)} => {err.decode().strip()}")
        return out.decode()

    async def connect(self) -> str:
        # Best-effort connect; ignore errors if already connected
        try:
            return await self._run("connect", f"{self.host}:{self.port}")
        except Exception:
            return ""

    async def keyevent(self, code: int) -> None:
        await self._run("shell", "input", "keyevent", str(code))

    async def nav(self, action: str) -> None:
        mapping = {
            "up": 19, "down": 20, "left": 21, "right": 22,
            "center": 23, "ok": 23, "enter": 66,
            "back": 4, "home": 3,
        }
        code = mapping.get(action.lower())
        if code is None:
            raise ValueError(f"unsupported nav action: {action}")
        await self.keyevent(code)

    async def volume(self, direction: str) -> None:
        mapping = {"up": 24, "down": 25, "mute": 164}
        code = mapping.get(direction.lower())
        if code is None:
            raise ValueError("volume direction must be up/down/mute")
        await self.keyevent(code)

    async def audio_music_info(self) -> dict:
        """Return current/max for STREAM_MUSIC by parsing dumpsys audio."""
        out = await self._run("shell", "dumpsys", "audio")
        cur = None
        maxv = None
        lines = out.splitlines()
        # Find section for STREAM_MUSIC and parse nearby lines
        for i, line in enumerate(lines):
            if "STREAM_MUSIC" in line:
                window = lines[i:i+10]
                for w in window:
                    # Patterns like: index: 8 (range: 0 - 25)
                    m = re.search(r"index\s*:\s*(\d+)\s*\(range:\s*\d+\s*-\s*(\d+)\)", w)
                    if m:
                        cur = int(m.group(1))
                        maxv = int(m.group(2))
                        break
                    m = re.search(r"Current\s*:\s*(\d+)\s*Max\s*:\s*(\d+)", w, re.I)
                    if m:
                        cur = int(m.group(1))
                        maxv = int(m.group(2))
                        break
                    m = re.search(r"indexCur\s*=\s*(\d+).*indexMax\s*=\s*(\d+)", w)
                    if m:
                        cur = int(m.group(1))
                        maxv = int(m.group(2))
                        break
                if cur is not None and maxv is not None:
                    break
        return {"current": cur, "max": maxv}

    async def set_volume_percent(self, percent: int) -> None:
        info = await self.audio_music_info()
        cur = info.get("current")
        maxv = info.get("max")
        if maxv:
            lvl = max(0, min(maxv, round(int(percent) * maxv / 100)))
            # Try modern media volume command
            try:
                await self._run("shell", "media", "volume", "--stream", "3", "--set", str(lvl))
                return
            except Exception:
                pass
            # Fallback via settings (not always supported)
            try:
                await self._run("shell", "settings", "put", "system", "volume_music", str(lvl))
                return
            except Exception:
                pass
        # As last resort, simulate up/down to approximate
        if cur is None or maxv is None:
            # try to nudge using up/down a few times based on target
            steps = 5
            direction = "up" if int(percent) >= 50 else "down"
            for _ in range(steps):
                await self.volume(direction)
        else:
            target = max(0, min(maxv, round(int(percent) * maxv / 100)))
            delta = target - cur
            cmd = "up" if delta > 0 else "down"
            for _ in range(abs(delta)):
                await self.volume(cmd)
    
    async def set_volume_index(self, index: int) -> None:
        info = await self.audio_music_info()
        maxv = info.get("max")
        if maxv is not None:
            index = max(0, min(maxv, int(index)))
        try:
            await self._run("shell", "media", "volume", "--stream", "3", "--set", str(index))
            return
        except Exception:
            pass
        try:
            await self._run("shell", "settings", "put", "system", "volume_music", str(index))
            return
        except Exception:
            pass
        # Fallback by relative keyevents (approximate)
        cur = info.get("current")
        if cur is None:
            return
        delta = int(index) - int(cur)
        cmd = "up" if delta > 0 else "down"
        for _ in range(abs(delta)):
            await self.volume(cmd)

    async def set_brightness(self, value: int) -> None:
        v = max(0, min(255, int(value)))
        await self._run("shell", "settings", "put", "system", "screen_brightness", str(v))

    async def screen(self, action: str) -> None:
        # Toggle with power key; we try to enforce state via dumpsys if necessary later
        if action.lower() in ("toggle", "power"):
            await self.keyevent(26)
            return
        # For on/off, attempt to check and toggle if needed
        state = await self._run("shell", "dumpsys", "power")
        is_on = "Display Power: state=ON" in state or "mHoldingDisplaySuspendBlocker=true" in state
        if action.lower() == "on" and not is_on:
            await self.keyevent(26)
        elif action.lower() == "off" and is_on:
            await self.keyevent(26)

    async def screen_state(self) -> bool:
        state = await self._run("shell", "dumpsys", "power")
        return ("Display Power: state=ON" in state) or ("mHoldingDisplaySuspendBlocker=true" in state)

    async def get_brightness(self) -> int:
        out = await self._run("shell", "settings", "get", "system", "screen_brightness")
        try:
            return int(out.strip())
        except Exception:
            return 0

    async def launch_app(self, package: str) -> None:
        await self._run("shell", "monkey", "-p", package, "-c", "android.intent.category.LAUNCHER", "1")

    async def stop_app(self, package: str) -> None:
        await self._run("shell", "am", "force-stop", package)

    async def switch_app(self, package: str) -> None:
        await self.launch_app(package)

    async def top_app(self) -> dict:
        # Try dumpsys activity activities for top activity
        out = await self._run("shell", "dumpsys", "activity", "activities")
        pkg = None
        act = None
        for line in out.splitlines():
            line = line.strip()
            if line.startswith("mResumedActivity:") or "topResumedActivity" in line:
                # e.g., mResumedActivity: ActivityRecord{... u0 com.spotify.music/.MainActivity}
                parts = line.split()
                for token in parts:
                    if "/" in token and "." in token:
                        comp = token.strip()
                        if comp.endswith("}"):
                            comp = comp[:-1]
                        pkg, act = comp.split("/", 1)
                        break
                break
        return {"package": pkg, "activity": act}

    async def list_packages(self, pattern: Optional[str] = None) -> list[str]:
        args = ["shell", "pm", "list", "packages"]
        if pattern:
            args.append(pattern)
        out = await self._run(*args)
        pkgs = []
        for line in out.splitlines():
            line = line.strip()
            if line.startswith("package:"):
                pkgs.append(line.split(":", 1)[1])
        return pkgs

    async def screenshot(self, path: str) -> None:
        """Capture a screenshot to host path.

        Tries fast path via exec-out. If it fails or times out, falls back to
        screencap on device + pull + cleanup. This avoids long-lived streams
        that can destabilize ADB over TCP.
        """
        # Fast path: exec-out stream
        try:
            cmd = ["adb", *self._target(), "exec-out", "screencap", "-p"]
            proc = await asyncio.create_subprocess_exec(
                *cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
            )
            try:
                assert proc.stdout is not None
                with open(path, "wb") as f:
                    while True:
                        chunk = await asyncio.wait_for(proc.stdout.read(65536), timeout=5.0)
                        if not chunk:
                            break
                        f.write(chunk)
                await asyncio.wait_for(proc.wait(), timeout=2.0)
                if proc.returncode == 0:
                    return
            except asyncio.TimeoutError:
                proc.kill()
                try:
                    await proc.wait()
                except Exception:
                    pass
            except Exception:
                try:
                    await proc.wait()
                except Exception:
                    pass
        except Exception:
            pass
        # Fallback: screencap to file, pull, then remove
        remote = "/sdcard/__isg_screencap.png"
        try:
            await self._run("shell", "screencap", "-p", remote, timeout=10.0)
            await self._run("pull", remote, path, timeout=10.0)
        finally:
            try:
                await self._run("shell", "rm", "-f", remote)
            except Exception:
                pass

    async def screenshot_bytes(self) -> bytes:
        # Try exec-out first
        try:
            cmd = ["adb", *self._target(), "exec-out", "screencap", "-p"]
            proc = await asyncio.create_subprocess_exec(
                *cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
            )
            data = bytearray()
            try:
                assert proc.stdout is not None
                while True:
                    chunk = await asyncio.wait_for(proc.stdout.read(65536), timeout=5.0)
                    if not chunk:
                        break
                    data.extend(chunk)
                await asyncio.wait_for(proc.wait(), timeout=2.0)
                if proc.returncode == 0 and data:
                    return bytes(data)
            except asyncio.TimeoutError:
                proc.kill()
                try:
                    await proc.wait()
                except Exception:
                    pass
        except Exception:
            pass
        # Fallback via temp file
        remote = "/sdcard/__isg_screencap.png"
        try:
            await self._run("shell", "screencap", "-p", remote, timeout=10.0)
            # Pull into bytes by pulling to stdout is tricky; pull to host tmp then read
            # We avoid temp files by using pull to a known path and reading
            import tempfile, os
            with tempfile.NamedTemporaryFile(delete=False, suffix=".png") as tmp:
                tmp_path = tmp.name
            try:
                await self._run("pull", remote, tmp_path, timeout=10.0)
                with open(tmp_path, "rb") as f:
                    return f.read()
            finally:
                try:
                    os.remove(tmp_path)
                except Exception:
                    pass
        finally:
            try:
                await self._run("shell", "rm", "-f", remote)
            except Exception:
                pass

    async def metrics(self) -> dict:
        battery = ""
        if self.has_battery:
            try:
                battery = await self._run("shell", "dumpsys", "battery")
            except Exception:
                battery = ""
        mem = await self._run("shell", "dumpsys", "meminfo")
        net = await self._run("shell", "dumpsys", "connectivity")
        # Optional telephony and wifi dumps
        tele = ""
        if self.has_cellular:
            try:
                tele = await self._run("shell", "dumpsys", "telephony.registry")
            except Exception:
                tele = ""
        try:
            wifi = await self._run("shell", "dumpsys", "wifi")
        except Exception:
            wifi = ""
        # Try CPU via dumpsys cpuinfo
        try:
            cpuinfo = await self._run("shell", "dumpsys", "cpuinfo")
        except Exception:
            cpuinfo = ""
        # Storage: parse df for /data and /sdcard (if mounted)
        storage: dict = {}
        try:
            df_data = await self._run("shell", "df", "-k", "/data")
            for line in df_data.splitlines()[1:]:
                parts = line.split()
                if len(parts) >= 6:
                    total_kb = int(parts[1])
                    used_kb = int(parts[2])
                    avail_kb = int(parts[3])
                    usep = parts[4]
                    try:
                        used_pct = float(usep.strip().strip("%"))
                    except Exception:
                        used_pct = round(used_kb * 100 / total_kb, 1) if total_kb else None
                    storage["data"] = {
                        "total_kb": total_kb,
                        "used_kb": used_kb,
                        "avail_kb": avail_kb,
                        "used_percent": used_pct,
                    }
                    break
        except Exception:
            pass
        try:
            df_sd = await self._run("shell", "df", "-k", "/sdcard")
            for line in df_sd.splitlines()[1:]:
                parts = line.split()
                if len(parts) >= 6:
                    total_kb = int(parts[1])
                    used_kb = int(parts[2])
                    avail_kb = int(parts[3])
                    usep = parts[4]
                    try:
                        used_pct = float(usep.strip().strip("%"))
                    except Exception:
                        used_pct = round(used_kb * 100 / total_kb, 1) if total_kb else None
                    storage["sdcard"] = {
                        "total_kb": total_kb,
                        "used_kb": used_kb,
                        "avail_kb": avail_kb,
                        "used_percent": used_pct,
                    }
                    break
        except Exception:
            pass
        try:
            screen_on = await self.screen_state()
        except Exception:
            screen_on = None
        try:
            brightness = await self.get_brightness()
        except Exception:
            brightness = None
        # audio info
        audio = {"music": {}}
        try:
            ainfo = await self.audio_music_info()
            if ainfo.get("max"):
                pct = round(ainfo.get("current", 0) * 100 / ainfo.get("max"), 0)
            else:
                pct = None
            audio["music"] = {"index": ainfo.get("current"), "max": ainfo.get("max"), "percent": pct}
        except Exception:
            pass
        out = {
            "battery": {},
            "memory_summary": {},
            "network": {},
            "screen": {"on": screen_on, "brightness": brightness},
            "audio": audio,
            "storage": storage,
        }
        temp_raw = None
        health_raw = None
        for line in battery.splitlines():
            if ":" in line:
                k, v = [x.strip() for x in line.split(":", 1)]
                out["battery"][k.replace(" ", "_").lower()] = v
                if k.strip().lower() == "temperature":
                    try:
                        temp_raw = int(v)
                    except Exception:
                        pass
                if k.strip().lower() == "health":
                    health_raw = v
        # normalize temperature and health name
        if temp_raw is not None:
            out["battery"]["temperature_c"] = round(temp_raw / 10.0, 1)
        # Health may be enum number or string
        health_map = {
            "1": "unknown",
            "2": "good",
            "3": "overheat",
            "4": "dead",
            "5": "over_voltage",
            "6": "failure",
            "7": "cold",
        }
        if health_raw is not None:
            out["battery"]["health_name"] = health_map.get(str(health_raw).strip(), str(health_raw).strip())
        # crude parse of meminfo summary
        total_k = free_k = used_k = None
        for line in mem.splitlines():
            s = line.strip()
            if s.startswith("Total RAM:") or s.startswith("Free RAM:") or s.startswith("Used RAM:"):
                k, v = [x.strip() for x in line.split(":", 1)]
                out["memory_summary"][k.replace(" ", "_").lower()] = v
                # attempt numeric extraction in kB
                num = "".join(ch for ch in v if ch.isdigit())
                try:
                    val = int(num)
                    if k.startswith("Total"):
                        total_k = val
                    elif k.startswith("Free"):
                        free_k = val
                    elif k.startswith("Used"):
                        used_k = val
                except Exception:
                    pass
        if total_k and used_k is not None:
            try:
                out["memory_summary"]["used_percent"] = round(used_k / total_k * 100, 1)
            except Exception:
                pass
        elif total_k and free_k is not None:
            try:
                used = max(total_k - free_k, 0)
                out["memory_summary"]["used_percent"] = round(used / total_k * 100, 1)
            except Exception:
                pass
        # Fallback via /proc/meminfo if used_percent missing
        if "used_percent" not in out["memory_summary"]:
            try:
                proc_mem = await self._run("shell", "cat", "/proc/meminfo")
                mt = ma = None
                for line in proc_mem.splitlines():
                    if line.startswith("MemTotal:"):
                        mt = int(line.split()[1])  # kB
                    elif line.startswith("MemAvailable:"):
                        ma = int(line.split()[1])  # kB
                if mt and ma is not None:
                    used = max(mt - ma, 0)
                    out["memory_summary"]["used_percent"] = round(used / mt * 100, 1)
            except Exception:
                pass
        # network active default
        active_type = None
        for line in net.splitlines():
            if "mNetworkCapabilities" in line and "NET_CAPABILITY_INTERNET" in line:
                out["network"]["internet"] = True
            if "NetworkAgentInfo" in line and ("WIFI" in line or "ETHERNET" in line or "MOBILE" in line or "CELLULAR" in line):
                if "WIFI" in line:
                    active_type = "wifi"
                elif "ETHERNET" in line:
                    active_type = "ethernet"
                elif "MOBILE" in line or "CELLULAR" in line:
                    active_type = "cellular"
        if active_type:
            out["network"]["type"] = active_type
        # wifi info
        if wifi:
            w = {}
            for line in wifi.splitlines():
                ls = line.strip()
                if ls.startswith("SSID:") and "<unknown ssid>" not in ls:
                    w["ssid"] = ls.split(":", 1)[1].strip()
                if "RSSI:" in ls:
                    try:
                        rssi = int(ls.split("RSSI:", 1)[1].split()[0])
                        w["rssi_dbm"] = rssi
                    except Exception:
                        pass
                if "Link speed:" in ls:
                    # e.g., Link speed: 72Mbps
                    sp = ls.split(":", 1)[1].strip()
                    try:
                        mbps = int("".join(ch for ch in sp if ch.isdigit()))
                        w["link_mbps"] = mbps
                    except Exception:
                        pass
            if w:
                out["network"]["wifi"] = w
        # cellular signal
        if tele:
            c = {}
            for line in tele.splitlines():
                ls = line.strip()
                if "mSignalStrength=" in ls:
                    # Try to capture level and dbm if present
                    if "level=" in ls:
                        try:
                            lvl = int(ls.split("level=", 1)[1].split(",", 1)[0].strip())
                            c["level"] = lvl
                        except Exception:
                            pass
                    if "dbm=" in ls:
                        try:
                            dbm = int(ls.split("dbm=", 1)[1].split(",", 1)[0].strip())
                            c["dbm"] = dbm
                        except Exception:
                            pass
                    break
            if c:
                out["network"]["cellular"] = c
        # cpu summary
        for line in cpuinfo.splitlines():
            if "TOTAL:" in line or line.strip().lower().startswith("total:"):
                # e.g., "TOTAL: 2% user + 1% kernel + 0% iowait + 0% irq + ..."
                parts = line.split(":", 1)[-1]
                fields = {}
                for token in parts.split("+"):
                    token = token.strip()
                    if "%" in token:
                        try:
                            value = float(token.split("%", 1)[0].strip())
                        except Exception:
                            continue
                        name = token.split("%", 1)[1].strip()
                        fields[name] = value
                if fields:
                    out["cpu"] = fields
                break
        return out

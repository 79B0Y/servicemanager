from __future__ import annotations

import os
import signal
import subprocess
import sys
from pathlib import Path

from . import __version__
from .models.config import Settings
import socket


BASE_DIR = Path.cwd()
VAR_DIR = BASE_DIR / "var"
LOG_DIR = VAR_DIR / "log"
RUN_DIR = VAR_DIR / "run"
PID_FILE = RUN_DIR / "isg-android-control.pid"
LOG_FILE = LOG_DIR / "isg-android-control.log"


def _ensure_dirs() -> None:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    RUN_DIR.mkdir(parents=True, exist_ok=True)


def cmd_start() -> int:
    _ensure_dirs()
    if PID_FILE.exists():
        print("Service already running (pid file exists)")
        return 1
    # Check if API port is free to avoid double-start
    try:
        settings = Settings.load()
        host = getattr(settings.api, "host", "0.0.0.0")
        port = int(getattr(settings.api, "port", 8000))
        # Bind test on 127.0.0.1 and on host for safety
        for h in {"127.0.0.1", host}:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                try:
                    s.bind((h, port))
                except OSError:
                    print(f"Port {port} already in use on {h}. Refusing to start. Adjust API_PORT or stop the other process.")
                    return 2
    except Exception:
        # If check fails, continue; uvicorn will report meaningful error
        pass
    # Launch uvicorn in background
    with open(LOG_FILE, "ab", buffering=0) as log:
        env = {**os.environ}
        env["PYTHONPATH"] = f"{BASE_DIR / 'src'}:" + env.get("PYTHONPATH", "")
        proc = subprocess.Popen(
            [sys.executable, "-m", "isg_android_control.run"],
            stdout=log,
            stderr=subprocess.STDOUT,
            cwd=BASE_DIR,
            env=env,
        )
        PID_FILE.write_text(str(proc.pid))
        print(f"Started API pid={proc.pid} (logs: {LOG_FILE})")
    return 0


def cmd_stop() -> int:
    if not PID_FILE.exists():
        print("No pid file; service not running?")
        return 1
    pid = int(PID_FILE.read_text().strip())
    try:
        os.kill(pid, signal.SIGTERM)
        print(f"Sent SIGTERM to pid {pid}")
    except ProcessLookupError:
        print("Process not found; removing stale pid file")
    # Also attempt to free port if lingering server exists (best-effort)
    try:
        settings = Settings.load()
        host = getattr(settings.api, "host", "0.0.0.0")
        port = int(getattr(settings.api, "port", 8000))
        # Nothing to actively free here beyond SIGTERM; guidance only
        print(f"If port {port} remains in use, check: lsof -i :{port} or netstat -plant")
    except Exception:
        pass
    try:
        PID_FILE.unlink()
    except FileNotFoundError:
        pass
    return 0


def cmd_status() -> int:
    if not PID_FILE.exists():
        print("stopped")
        return 3
    pid = int(PID_FILE.read_text().strip())
    try:
        os.kill(pid, 0)
        print(f"running (pid {pid})")
        return 0
    except ProcessLookupError:
        print("stale pid file; removing")
        PID_FILE.unlink(missing_ok=True)
        return 3


def cmd_logs() -> int:
    if not LOG_FILE.exists():
        print("no log file yet")
        return 1
    try:
        subprocess.call(["tail", "-n", "200", "-f", str(LOG_FILE)])
        return 0
    except KeyboardInterrupt:
        return 0


def cmd_version() -> int:
    print(__version__)
    return 0


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv:
        print("usage: isg-android-control [start|stop|status|logs|version]")
        return 2
    cmd = argv[0]
    if cmd == "start":
        return cmd_start()
    if cmd == "stop":
        return cmd_stop()
    if cmd == "status":
        return cmd_status()
    if cmd == "logs":
        return cmd_logs()
    if cmd == "version":
        return cmd_version()
    print(f"unknown command: {cmd}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())

from __future__ import annotations

from pathlib import Path
import os
import sys
import subprocess
import signal

from . import __version__
from .models.config import Settings
import socket


# Resolve project root from this file location to avoid CWD-dependent paths
# cli.py path: <project_root>/src/isg_android_control/cli.py
BASE_DIR = Path(__file__).resolve().parents[2]
VAR_DIR = BASE_DIR / "var"
LOG_DIR = VAR_DIR / "log"
RUN_DIR = VAR_DIR / "run"
PID_FILE = RUN_DIR / "isg-android-control.pid"
LOG_FILE = LOG_DIR / "isg-android-control.log"


def _ensure_dirs() -> None:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    RUN_DIR.mkdir(parents=True, exist_ok=True)


def check_port_available(host: str, port: int) -> bool:
    """Return True if ``port`` is free on ``host``.

    Prints an informative message and returns False when the port cannot be
    bound.
    """
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            s.bind((host, port))
        except OSError:
            print(f"Port {port} already in use on {host}.")
            return False
    return True


def cmd_start() -> int:
    _ensure_dirs()
    # Foreground mode: do not use pid file; just run the server in the current tty.
    # Check if API port is free to avoid confusing startup errors.
    try:
        settings = Settings.load()
        host = getattr(settings.api, "host", "0.0.0.0")
        port = int(getattr(settings.api, "port", 8000))
        # Bind test on 127.0.0.1 and on host for safety
        for h in {"127.0.0.1", host}:
            if not check_port_available(h, port):
                print("Refusing to start. Adjust API_PORT or stop the other process.")
                return 2
    except Exception:
        # If check fails, continue; uvicorn will report meaningful error
        pass
    # Foreground exec: replace current process so signals pass through cleanly
    env = {**os.environ}
    # Load .env into environment (non-destructive: system env wins)
    try:
        env_path = BASE_DIR / ".env"
        if env_path.exists():
            for raw in env_path.read_text(encoding="utf-8").splitlines():
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                k = k.strip()
                v = v.strip().strip('"').strip("'")
                # Do not override explicitly set env vars
                env.setdefault(k, v)
    except Exception:
        # Best-effort; ignore .env loading errors in CLI
        pass
    env["PYTHONPATH"] = f"{BASE_DIR / 'src'}:" + env.get("PYTHONPATH", "")
    os.chdir(BASE_DIR)
    print("Starting API in foreground (Ctrl+C to stop)...")
    os.execve(sys.executable, [sys.executable, "-m", "isg_android_control.run"], env)
    return 0  # not reached


def cmd_stop() -> int:
    if not PID_FILE.exists():
        print("No pid file; service may be running in foreground or not running.")
        return 1
    try:
        pid = int(PID_FILE.read_text().strip())
    except ValueError:
        print(f"invalid pid file; removing ({PID_FILE})")
        PID_FILE.unlink(missing_ok=True)
        return 1
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
    try:
        pid = int(PID_FILE.read_text().strip())
    except ValueError:
        print(f"invalid pid file; removing ({PID_FILE})")
        PID_FILE.unlink(missing_ok=True)
        print("stopped")
        return 3
    try:
        os.kill(pid, 0)
        print(f"running (pid {pid})")
        return 0
    except ProcessLookupError:
        print(f"stale pid file; removing ({PID_FILE})")
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
    if cmd in ("daemon", "start-daemon"):
        # Background mode preserved for convenience
        _ensure_dirs()
        if PID_FILE.exists():
            print("Service already running (pid file exists)")
            return 1
        try:
            settings = Settings.load()
            host = getattr(settings.api, "host", "0.0.0.0")
            port = int(getattr(settings.api, "port", 8000))
            for h in {"127.0.0.1", host}:
                if not check_port_available(h, port):
                    print("Refusing to start daemon.")
                    return 2
        except Exception:
            pass
        with open(LOG_FILE, "ab", buffering=0) as log:
            env = {**os.environ}
            # Load .env into environment (non-destructive: system env wins)
            try:
                env_path = BASE_DIR / ".env"
                if env_path.exists():
                    for raw in env_path.read_text(encoding="utf-8").splitlines():
                        line = raw.strip()
                        if not line or line.startswith("#") or "=" not in line:
                            continue
                        k, v = line.split("=", 1)
                        k = k.strip()
                        v = v.strip().strip('"').strip("'")
                        env.setdefault(k, v)
            except Exception:
                pass
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

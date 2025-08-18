import asyncio
import os
import sys
from pathlib import Path

import pytest

sys.path.append(str(Path(__file__).resolve().parents[1] / "src"))

from isg_android_control.core.adb import ADBController

def test_run_timeout_no_zombie(monkeypatch):
    controller = ADBController()
    proc_holder = {}
    orig_create = asyncio.create_subprocess_exec

    async def fake_create_subprocess_exec(*cmd, **kwargs):
        proc = await orig_create(sys.executable, "-c", "import time; time.sleep(60)", **kwargs)
        proc_holder["proc"] = proc
        return proc

    monkeypatch.setattr(asyncio, "create_subprocess_exec", fake_create_subprocess_exec)

    async def invoke():
        await controller._run("version", timeout=0.1)

    with pytest.raises(asyncio.TimeoutError):
        asyncio.run(invoke())

    proc = proc_holder["proc"]
    with pytest.raises(ProcessLookupError):
        os.kill(proc.pid, 0)

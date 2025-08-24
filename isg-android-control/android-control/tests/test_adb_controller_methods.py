import sys
import asyncio
from pathlib import Path
from unittest.mock import AsyncMock

import pytest

sys.path.append(str(Path(__file__).resolve().parents[1] / "src"))
from isg_android_control.core.adb import ADBController  # noqa: E402


def test_volume_up_sends_keyevent(monkeypatch):
    adb = ADBController()
    mock_run = AsyncMock()
    monkeypatch.setattr(adb, "_run", mock_run)

    async def run_test():
        await adb.volume("up")

    asyncio.run(run_test())
    mock_run.assert_awaited_with("shell", "input", "keyevent", "24")


def test_screen_state_parses_output(monkeypatch):
    adb = ADBController()

    mock_run = AsyncMock(return_value="Display Power: state=ON")
    monkeypatch.setattr(adb, "_run", mock_run)

    async def run_true():
        assert await adb.screen_state() is True

    asyncio.run(run_true())
    mock_run.assert_awaited_with("shell", "dumpsys", "power")

    mock_run.reset_mock()
    mock_run.return_value = "Display Power: state=OFF"

    async def run_false():
        assert await adb.screen_state() is False

    asyncio.run(run_false())
    mock_run.assert_awaited_with("shell", "dumpsys", "power")

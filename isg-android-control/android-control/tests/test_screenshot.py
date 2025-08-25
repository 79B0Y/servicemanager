import sys
import asyncio
from pathlib import Path
from tempfile import TemporaryDirectory

import pytest

sys.path.append(str(Path(__file__).resolve().parents[1] / "src"))
from isg_android_control.services.screenshot import ScreenshotService  # noqa: E402


def test_init_with_negative_keep_raises_value_error():
    with TemporaryDirectory() as tmpdir:
        with pytest.raises(ValueError):
            ScreenshotService(adb=None, directory=Path(tmpdir), keep=-1)


def test_rotate_removes_all_when_keep_zero():
    with TemporaryDirectory() as tmpdir:
        d = Path(tmpdir)
        for i in range(3):
            (d / f"screenshot-{i}.png").touch()
        service = ScreenshotService(adb=None, directory=d, keep=0)
        remaining = service._rotate()
        assert remaining == []
        assert list(d.glob("screenshot-*.png")) == []


def test_capture_rotates_and_names_files(tmp_path):
    """Ensure capture rotates files and reuses the lowest available index."""

    class DummyADB:
        def __init__(self):
            self.count = 0

        async def screenshot(self, target):
            self.count += 1
            Path(target).write_text(f"shot{self.count}")

    adb = DummyADB()
    service = ScreenshotService(adb=adb, directory=tmp_path, keep=2)

    async def run_test():
        f1 = await service.capture()
        f2 = await service.capture()
        assert f1.name == "screenshot-1.png"
        assert f2.name == "screenshot-2.png"

        f3 = await service.capture()
        # Oldest file should be removed and name reused
        assert f3.name == "screenshot-1.png"

        files = sorted(p.name for p in tmp_path.glob("screenshot-*.png"))
        assert files == ["screenshot-1.png", "screenshot-2.png"]
        # Validate contents to ensure rotation occurred
        assert (tmp_path / "screenshot-1.png").read_text() == "shot3"
        assert (tmp_path / "screenshot-2.png").read_text() == "shot2"

    asyncio.run(run_test())

from __future__ import annotations

import asyncio
from pathlib import Path
from typing import List

from ..core.adb import ADBController


class ScreenshotService:
    def __init__(self, adb: ADBController, directory: Path, keep: int = 3) -> None:
        self.adb = adb
        self.dir = directory
        self.keep = keep
        self.dir.mkdir(parents=True, exist_ok=True)

    def _rotate(self) -> List[Path]:
        files = sorted(self.dir.glob("screenshot-*.png"))
        while len(files) >= self.keep:
            oldest = files.pop(0)
            try:
                oldest.unlink()
            except FileNotFoundError:
                pass
        return files

    async def capture(self) -> Path:
        self._rotate()
        idx = 1
        existing = {p.name for p in self.dir.glob("screenshot-*.png")}
        while f"screenshot-{idx}.png" in existing:
            idx += 1
        target = self.dir / f"screenshot-{idx}.png"
        await self.adb.screenshot(str(target))
        return target


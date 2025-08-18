from __future__ import annotations

from ..core.adb import ADBController


class MonitorService:
    def __init__(self, adb: ADBController) -> None:
        self.adb = adb

    async def snapshot(self) -> dict:
        return await self.adb.metrics()


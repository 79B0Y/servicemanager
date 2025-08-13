from __future__ import annotations

from typing import Any, Optional

from redis import asyncio as aioredis
import os
import time


class Cache:
    def __init__(self, url: str | None = None) -> None:
        if url is None:
            url = os.environ.get("REDIS_URL", "redis://127.0.0.1:6379/0")
        self._memory = None
        if url.startswith("memory://"):
            self._memory = {}
            self._client = None
        else:
            self._client = aioredis.from_url(url, encoding="utf-8", decode_responses=True)

    async def get_json(self, key: str) -> Optional[dict]:
        if self._memory is not None:
            item = self._memory.get(key)
            if not item:
                return None
            exp, val = item
            if exp is not None and exp < time.time():
                self._memory.pop(key, None)
                return None
            return val
        else:
            val = await self._client.get(key)
            if not val:
                return None
            import json
            return json.loads(val)

    async def set_json(self, key: str, value: Any, ttl: int = 30) -> None:
        if self._memory is not None:
            exp = time.time() + ttl if ttl else None
            self._memory[key] = (exp, value)
        else:
            import json
            await self._client.set(key, json.dumps(value), ex=ttl)

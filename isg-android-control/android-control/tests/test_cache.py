import sys
import unittest
from pathlib import Path

import asyncio
import pytest

sys.path.append(str(Path(__file__).resolve().parents[1] / "src"))
from isg_android_control.services.cache import Cache  # noqa: E402
import isg_android_control.services.cache as cache_module  # noqa: E402


class CacheTest(unittest.IsolatedAsyncioTestCase):
    async def test_zero_cached(self):
        cache = Cache("memory://")
        await cache.set_json("zero", 0)
        result = await cache.get_json("zero")
        self.assertEqual(result, 0)

    async def test_empty_list_cached(self):
        cache = Cache("memory://")
        await cache.set_json("list", [])
        result = await cache.get_json("list")
        self.assertEqual(result, [])

    async def test_empty_dict_cached(self):
        cache = Cache("memory://")
        await cache.set_json("dict", {})
        result = await cache.get_json("dict")
        self.assertEqual(result, {})


def test_memory_cache_expiration(monkeypatch):
    """Values should expire after their TTL when using memory backend."""

    monkeypatch.setenv("REDIS_URL", "memory://")
    current = {"value": 0}

    def fake_time():
        return current["value"]

    monkeypatch.setattr(cache_module.time, "time", fake_time)
    cache = Cache()

    async def run_test():
        await cache.set_json("foo", {"bar": 1}, ttl=10)
        assert await cache.get_json("foo") == {"bar": 1}
        current["value"] = 20  # advance time beyond TTL
        assert await cache.get_json("foo") is None

    asyncio.run(run_test())


if __name__ == "__main__":
    unittest.main()

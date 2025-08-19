import asyncio
from types import SimpleNamespace
from pathlib import Path
import sys

import pytest

sys.path.append(str(Path(__file__).resolve().parents[1] / "src"))
from isg_android_control import run


class DummyADB:
    async def screen_state(self):
        return True

    async def get_brightness(self):
        return 128


class DummyCache:
    def __init__(self):
        self.store = {}

    async def get_json(self, key):
        return self.store.get(key)

    async def set_json(self, key, value, ttl=20):
        self.store[key] = value


class DummyHA:
    def __init__(self):
        self.published = None

    def publish_state(self, state):
        self.published = state

def test_publish_screen_state_updates_cache_and_ha(monkeypatch):
    adb = DummyADB()
    cache = DummyCache()
    monkeypatch.setattr(run, "adb", adb)
    monkeypatch.setattr(run, "cache", cache)
    ha = DummyHA()
    asyncio.run(run.publish_screen_state(ha))
    assert cache.store["metrics"]["screen"]["on"] is True
    assert cache.store["metrics"]["screen"]["brightness"] == 128
    assert ha.published["screen"]["on"] is True


def test_publish_screen_state_merges_existing(monkeypatch):
    adb = DummyADB()
    cache = DummyCache()
    cache.store["metrics"] = {"battery": {"level": 50}}
    monkeypatch.setattr(run, "adb", adb)
    monkeypatch.setattr(run, "cache", cache)
    ha = DummyHA()
    asyncio.run(run.publish_screen_state(ha))
    assert cache.store["metrics"]["battery"]["level"] == 50
    assert cache.store["metrics"]["screen"]["on"] is True
    assert ha.published["battery"]["level"] == 50

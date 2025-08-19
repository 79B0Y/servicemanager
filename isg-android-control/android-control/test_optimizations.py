#!/usr/bin/env python3
"""Test script to validate optimizations."""

import sys
import asyncio
from pathlib import Path

# Add src to path
sys.path.insert(0, str(Path(__file__).parent / "src"))

async def test_cache():
    """Test cache functionality."""
    from isg_android_control.services.cache import Cache
    
    print("Testing cache...")
    
    # Test memory cache
    cache = Cache("memory://test")
    await cache.set_json("test_key", {"value": 123, "nested": {"data": "test"}})
    result = await cache.get_json("test_key")
    assert result == {"value": 123, "nested": {"data": "test"}}, f"Cache test failed: {result}"
    
    # Test TTL
    await cache.set_json("ttl_key", {"temp": True}, ttl=1)
    await asyncio.sleep(1.1)
    expired = await cache.get_json("ttl_key")
    assert expired is None, "TTL test failed"
    
    await cache.close()
    print("✓ Cache tests passed")

def test_config():
    """Test configuration loading."""
    from isg_android_control.models.config import Settings
    
    print("Testing configuration...")
    
    settings = Settings.load()
    assert settings.mqtt.host == "127.0.0.1"
    assert settings.mqtt.port == 1883
    assert settings.api.host == "0.0.0.0"
    assert settings.api.port == 8000
    
    print("✓ Configuration tests passed")

async def test_screenshot_service():
    """Test screenshot service (without actual ADB)."""
    from isg_android_control.services.screenshot import ScreenshotService
    from isg_android_control.core.adb import ADBController
    import tempfile
    
    print("Testing screenshot service...")
    
    with tempfile.TemporaryDirectory() as temp_dir:
        temp_path = Path(temp_dir)
        adb = ADBController()  # Mock ADB
        
        service = ScreenshotService(adb, temp_path, keep=2)
        stats = service.get_stats()
        
        assert stats["directory"] == str(temp_path)
        assert stats["keep_policy"] == 2
        assert stats["file_count"] == 0
        
    print("✓ Screenshot service tests passed")

async def main():
    """Run all tests."""
    print("Running optimization validation tests...\n")
    
    try:
        test_config()
        await test_cache()
        await test_screenshot_service()
        
        print("\n🎉 All optimization tests passed!")
        return 0
        
    except Exception as e:
        print(f"\n❌ Test failed: {e}")
        import traceback
        traceback.print_exc()
        return 1

if __name__ == "__main__":
    exit(asyncio.run(main()))
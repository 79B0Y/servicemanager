from __future__ import annotations

import json
import os
import time
import logging
from typing import Any, Optional, Dict
from contextlib import asynccontextmanager

try:
    from redis import asyncio as aioredis
    REDIS_AVAILABLE = True
except ImportError:
    REDIS_AVAILABLE = False
    aioredis = None

logger = logging.getLogger(__name__)


class Cache:
    """Optimized cache implementation with fallback and better error handling."""
    
    def __init__(self, url: str | None = None) -> None:
        self.url = url or os.environ.get("REDIS_URL", "redis://127.0.0.1:6379/0")
        self._memory: Optional[Dict[str, tuple]] = None
        self._client = None
        self._redis_failed = False
        
        if self.url.startswith("memory://"):
            logger.info("Using memory cache")
            self._memory = {}
        elif not REDIS_AVAILABLE:
            logger.info("Redis not available, using memory cache")
            self._memory = {}
        else:
            self._init_redis()
    
    def _init_redis(self) -> None:
        """Initialize Redis client with error handling."""
        try:
            self._client = aioredis.from_url(
                self.url, 
                encoding="utf-8", 
                decode_responses=True,
                socket_timeout=5.0,
                socket_connect_timeout=5.0,
                retry_on_timeout=True
            )
            logger.info("Redis cache initialized: %s", self.url)
        except Exception as e:
            logger.warning("Failed to initialize Redis, using memory cache: %s", e)
            self._memory = {}
            self._redis_failed = True

    async def get_json(self, key: str) -> Optional[dict]:
        """Get JSON value from cache with fallback handling."""
        if self._memory is not None:
            return self._get_from_memory(key)
        
        try:
            val = await self._client.get(key)
            if val is None:
                return None
            return json.loads(val)
        except Exception as e:
            logger.debug("Redis get failed for key %s: %s", key, e)
            if not self._redis_failed:
                logger.warning("Redis connection issues, falling back to memory cache")
                self._memory = {}
                self._redis_failed = True
            return None
    
    def _get_from_memory(self, key: str) -> Optional[dict]:
        """Get value from memory cache with TTL handling."""
        item = self._memory.get(key)
        if item is None:
            return None
        
        exp, val = item
        if exp is not None and exp < time.time():
            # Expired, remove and return None
            self._memory.pop(key, None)
            return None
        
        return val

    async def set_json(self, key: str, value: Any, ttl: int = 30) -> None:
        """Set JSON value in cache with fallback handling."""
        if self._memory is not None:
            exp = time.time() + ttl if ttl > 0 else None
            self._memory[key] = (exp, value)
            self._cleanup_memory_cache()
            return
        
        try:
            serialized = json.dumps(value, separators=(',', ':'))  # Compact JSON
            await self._client.set(key, serialized, ex=ttl if ttl > 0 else None)
        except Exception as e:
            logger.debug("Redis set failed for key %s: %s", key, e)
            if not self._redis_failed:
                logger.warning("Redis connection issues, falling back to memory cache")
                self._memory = {}
                self._redis_failed = True
            
            # Fallback to memory
            if self._memory is not None:
                exp = time.time() + ttl if ttl > 0 else None
                self._memory[key] = (exp, value)
                self._cleanup_memory_cache()
    
    def _cleanup_memory_cache(self) -> None:
        """Clean up expired entries from memory cache."""
        if self._memory is None or len(self._memory) < 100:
            return  # Only cleanup when cache gets large
        
        current_time = time.time()
        expired_keys = [
            key for key, (exp, _) in self._memory.items()
            if exp is not None and exp < current_time
        ]
        
        for key in expired_keys:
            self._memory.pop(key, None)
        
        if expired_keys:
            logger.debug("Cleaned up %d expired cache entries", len(expired_keys))

    async def close(self) -> None:
        """Close the cache and cleanup resources."""
        if self._client is not None:
            try:
                await self._client.close()
                logger.debug("Redis connection closed")
            except Exception as e:
                logger.debug("Error closing Redis connection: %s", e)
            finally:
                self._client = None
        
        if self._memory is not None:
            self._memory.clear()
    
    @asynccontextmanager
    async def transaction(self):
        """Context manager for cache transactions (Redis only)."""
        if self._client is None:
            # For memory cache, just yield
            yield self
            return
        
        try:
            pipe = self._client.pipeline()
            yield pipe
            await pipe.execute()
        except Exception as e:
            logger.warning("Cache transaction failed: %s", e)
            raise
    
    async def health_check(self) -> bool:
        """Check if cache is healthy."""
        if self._memory is not None:
            return True
        
        try:
            await self._client.ping()
            return True
        except Exception:
            return False
    
    async def warmup(self) -> None:
        """Proactively verify Redis and fall back to memory at startup.

        This avoids mid-request warnings by switching to in-memory cache
        immediately if Redis is not reachable.
        """
        if self._memory is not None:
            return
        try:
            await self._client.ping()
        except Exception as e:
            logger.warning("Redis not reachable at startup, using memory cache: %s", e)
            try:
                await self._client.close()
            except Exception:
                pass
            self._client = None
            self._memory = {}
            self._redis_failed = True
    
    def get_stats(self) -> Dict[str, Any]:
        """Get cache statistics."""
        if self._memory is not None:
            current_time = time.time()
            total_keys = len(self._memory)
            expired_keys = sum(
                1 for exp, _ in self._memory.values()
                if exp is not None and exp < current_time
            )
            
            return {
                'type': 'memory',
                'total_keys': total_keys,
                'expired_keys': expired_keys,
                'active_keys': total_keys - expired_keys
            }
        else:
            return {
                'type': 'redis',
                'url': self.url,
                'failed': self._redis_failed
            }

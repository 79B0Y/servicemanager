from __future__ import annotations

import asyncio
import logging
import time
from pathlib import Path
from typing import List, Optional

from ..core.adb import ADBController, ADBError

logger = logging.getLogger(__name__)


class ScreenshotService:
    """Optimized screenshot service with better file management and error handling."""
    
    def __init__(self, adb: ADBController, directory: Path, keep: int = 3) -> None:
        if keep < 0:
            raise ValueError("keep must be >= 0")
        
        self.adb = adb
        self.dir = Path(directory)
        self.keep = keep
        self._file_counter = 0
        self._last_cleanup = 0
        self._cleanup_interval = 60  # Cleanup every 60 seconds
        
        # Ensure directory exists
        try:
            self.dir.mkdir(parents=True, exist_ok=True)
            logger.info("Screenshot directory initialized: %s (keep %d files)", self.dir, self.keep)
        except PermissionError as e:
            logger.error("Cannot create screenshot directory %s: %s", self.dir, e)
            raise
        
        # Initialize counter from existing files
        self._init_counter()

    def _init_counter(self) -> None:
        """Initialize file counter from existing files."""
        try:
            existing_files = list(self.dir.glob("screenshot-*.png"))
            if existing_files:
                # Extract numbers from filenames and find the highest
                numbers = []
                for file in existing_files:
                    try:
                        num_str = file.stem.split('-', 1)[1]
                        numbers.append(int(num_str))
                    except (IndexError, ValueError):
                        continue
                
                if numbers:
                    self._file_counter = max(numbers)
                    logger.debug("Initialized screenshot counter to %d", self._file_counter)
        except Exception as e:
            logger.warning("Failed to initialize screenshot counter: %s", e)
            self._file_counter = 0
    
    def _should_cleanup(self) -> bool:
        """Check if cleanup should be performed."""
        current_time = time.time()
        return (current_time - self._last_cleanup) > self._cleanup_interval
    
    def _cleanup_files(self) -> List[Path]:
        """Clean up old screenshot files according to keep policy."""
        try:
            files = sorted(self.dir.glob("screenshot-*.png"), key=lambda p: p.stat().st_mtime)
            
            if self.keep <= 0:
                # Remove all files
                removed_count = 0
                for p in files:
                    try:
                        p.unlink()
                        removed_count += 1
                    except FileNotFoundError:
                        pass
                    except Exception as e:
                        logger.warning("Failed to remove screenshot %s: %s", p, e)
                
                if removed_count > 0:
                    logger.debug("Removed %d screenshot files (keep=0)", removed_count)
                return []
            
            # Remove excess files
            removed_count = 0
            while len(files) >= self.keep:
                oldest = files.pop(0)
                try:
                    oldest.unlink()
                    removed_count += 1
                    logger.debug("Removed old screenshot: %s", oldest.name)
                except FileNotFoundError:
                    pass
                except Exception as e:
                    logger.warning("Failed to remove screenshot %s: %s", oldest, e)
            
            if removed_count > 0:
                logger.debug("Cleaned up %d old screenshot files", removed_count)
            
            self._last_cleanup = time.time()
            return files
            
        except Exception as e:
            logger.error("Error during screenshot cleanup: %s", e)
            return []

    async def capture(self) -> Path:
        """Capture a screenshot with optimized file management."""
        # Periodic cleanup
        if self._should_cleanup():
            self._cleanup_files()
        
        # Generate unique filename
        self._file_counter += 1
        target = self.dir / f"screenshot-{self._file_counter}.png"
        
        # Ensure we don't overwrite existing files (rare edge case)
        while target.exists():
            self._file_counter += 1
            target = self.dir / f"screenshot-{self._file_counter}.png"
        
        try:
            await self.adb.screenshot(str(target))
            
            # Verify file was created and has content
            if not target.exists():
                raise ADBError(f"Screenshot file was not created: {target}")
            
            file_size = target.stat().st_size
            if file_size == 0:
                target.unlink(missing_ok=True)
                raise ADBError("Screenshot file is empty")
            
            logger.debug("Screenshot captured: %s (%d bytes)", target.name, file_size)
            return target
            
        except Exception as e:
            # Cleanup failed screenshot attempt
            if target.exists():
                try:
                    target.unlink()
                except Exception:
                    pass
            
            logger.error("Screenshot capture failed: %s", e)
            raise
    
    async def capture_bytes(self) -> bytes:
        """Capture screenshot and return as bytes without saving to disk."""
        try:
            return await self.adb.screenshot_bytes()
        except Exception as e:
            logger.error("Screenshot bytes capture failed: %s", e)
            raise
    
    def get_latest(self) -> Optional[Path]:
        """Get the path to the most recent screenshot."""
        try:
            files = list(self.dir.glob("screenshot-*.png"))
            if not files:
                return None
            
            # Sort by modification time, newest first
            latest = max(files, key=lambda p: p.stat().st_mtime)
            return latest
            
        except Exception as e:
            logger.warning("Failed to get latest screenshot: %s", e)
            return None
    
    def list_screenshots(self) -> List[Path]:
        """List all screenshot files, sorted by modification time (newest first)."""
        try:
            files = list(self.dir.glob("screenshot-*.png"))
            return sorted(files, key=lambda p: p.stat().st_mtime, reverse=True)
        except Exception as e:
            logger.warning("Failed to list screenshots: %s", e)
            return []
    
    def get_stats(self) -> dict:
        """Get screenshot service statistics."""
        try:
            files = self.list_screenshots()
            total_size = sum(f.stat().st_size for f in files)
            
            return {
                'directory': str(self.dir),
                'keep_policy': self.keep,
                'file_count': len(files),
                'total_size_bytes': total_size,
                'latest_file': files[0].name if files else None,
                'file_counter': self._file_counter
            }
        except Exception as e:
            logger.warning("Failed to get screenshot stats: %s", e)
            return {
                'directory': str(self.dir),
                'keep_policy': self.keep,
                'error': str(e)
            }
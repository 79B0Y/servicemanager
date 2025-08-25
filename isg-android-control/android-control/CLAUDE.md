# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Development Commands

**Installation and Setup:**
- `bash install.sh` - One-click installer that sets up dependencies, creates venv, and installs CLI
- `bash scripts/setup.sh` - Manual setup for pure Termux environments
- `python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt` - Manual Python environment setup

**Service Management:**
- `isg-android-control start` - Run service in foreground (Ctrl+C to stop)
- `isg-android-control daemon` - Run service in background with PID file
- `isg-android-control stop` - Stop background service
- `isg-android-control status` - Check service status
- `isg-android-control logs` - View service logs (tail -f)
- `isg-android-control version` - Show version

**Testing:**
- `python -m pytest tests/` - Run all tests
- `python -m pytest tests/test_cli.py` - Run specific test file
- Tests require src path: `PYTHONPATH=src python -m pytest tests/`
- Tests are available for: ADB controller, CLI, caching, screenshots, and screen watcher

**Development:**
- `python -m isg_android_control.run` - Run main application directly
- `python -m isg_android_control.cli start` - Run CLI directly

**Environment Setup:**
- Environment variables can be set in `.env` file or passed directly
- Key variables: `REDIS_URL`, `MQTT_HOST`, `MQTT_PORT`, `ADB_HOST`, `ADB_PORT`, `ADB_SERIAL`
- Logging controlled via `LOGS_DIR` (defaults to `var/log/`)
- Screenshots saved to `SCREENSHOTS_DIR` (defaults to `var/screenshots/`)

## Architecture Overview

This is a Python-based Android device control system that provides REST API and MQTT integration for Home Assistant. The system uses ADB to control Android devices remotely.

**Core Components:**

- **ADB Controller** (`src/isg_android_control/core/adb.py`): Manages ADB connections and device operations (navigation, volume, brightness, apps, screenshots)
- **FastAPI Server** (`src/isg_android_control/api/main.py`): REST API endpoints for device control
- **MQTT Integration** (`src/isg_android_control/mqtt/`): Home Assistant auto-discovery and state publishing
- **Service Layer** (`src/isg_android_control/services/`): Monitor, cache, and screenshot services
- **CLI Interface** (`src/isg_android_control/cli.py`): Command-line service management

**Configuration System:**
- `configs/device.yaml` - Device and ADB settings
- `configs/mqtt.yaml` - MQTT broker configuration  
- `configs/apps.yaml` - App name to package mappings
- `.env` - Environment variable overrides (optional)

**Key Architecture Patterns:**
- Async/await throughout for non-blocking operations
- FastAPI dependency injection for shared state (settings, adb, monitor, etc.)
- MQTT pub/sub for Home Assistant integration with auto-discovery
- Redis caching for metrics and state (falls back to memory)
- Configurable screenshot compression and resizing
- Daemon management with PID files and logging

**Data Flow:**
1. CLI starts FastAPI server and MQTT worker concurrently
2. MQTT worker publishes device discovery to Home Assistant
3. Background tasks: metrics monitoring, app watching, screenshot capture
4. Commands arrive via REST API or MQTT subscriptions
5. ADB controller executes device operations
6. State changes published back to MQTT/Home Assistant

**Testing Strategy:**
- Unit tests for CLI, ADB operations, caching, and screenshots
- Mocking used for external dependencies (ADB commands, Redis)
- Tests located in `tests/` directory with `test_*.py` naming

The system is designed for Termux+Ubuntu environments but works on any Linux system with ADB access.
from __future__ import annotations

import os
import logging
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Optional, Any, Union
from functools import lru_cache

import yaml

logger = logging.getLogger(__name__)


CONFIG_DIR = Path(__file__).resolve().parents[3] / "configs"


@dataclass
class MQTTConfig:
    host: str = "127.0.0.1"
    port: int = 1883
    username: Optional[str] = None
    password: Optional[str] = None
    discovery_prefix: str = "homeassistant"
    base_topic: str = "isg/android"


@dataclass
class DeviceConfig:
    adb_host: str = "127.0.0.1"
    adb_port: int = 5555
    adb_serial: Optional[str] = None  # overrides host:port if set
    screenshots_dir: Path = Path("var/screenshots")
    logs_dir: Path = Path("var/log")
    run_dir: Path = Path("var/run")
    has_battery: bool = False
    has_cellular: bool = False
    camera_enabled: bool = True
    camera_interval: int = 10  # seconds (deprecated; use screenshot_interval)
    screenshot_interval: int = 10  # seconds
    screenshot_keep: int = 3
    # MQTT camera behavior
    camera_max_bytes: int = 600000  # skip MQTT publish if larger
    camera_retain: bool = False     # do not retain large images by default
    # Compression settings
    camera_compress: bool = True
    camera_format: str = "jpeg"     # jpeg or png
    camera_quality: int = 70         # for jpeg
    camera_max_width: Optional[int] = None
    camera_max_height: Optional[int] = None
    device_id: str = "isg_android_controller"
    device_name: str = "ISG Android Controller"
    # Foreground app tracking
    app_watch_enabled: bool = True
    app_poll_interval: int = 2  # seconds


@dataclass
class AppConfig:
    apps: Dict[str, str] = field(default_factory=dict)  # display_name -> package
    visible: Optional[list[str]] = field(default_factory=list)  # optional subset of display names


@dataclass
class APIConfig:
    host: str = "0.0.0.0"
    port: int = 8000


@dataclass
class Settings:
    """Optimized settings with caching and validation."""
    mqtt: MQTTConfig = field(default_factory=MQTTConfig)
    api: APIConfig = field(default_factory=APIConfig)
    device: DeviceConfig = field(default_factory=DeviceConfig)
    appmap: AppConfig = field(default_factory=AppConfig)
    
    def __post_init__(self):
        """Validate configuration after initialization."""
        self._validate()
    
    def _validate(self) -> None:
        """Validate configuration values."""
        # Validate MQTT config
        if not (1 <= self.mqtt.port <= 65535):
            raise ValueError(f"Invalid MQTT port: {self.mqtt.port}")
        
        # Validate API config
        if not (1 <= self.api.port <= 65535):
            raise ValueError(f"Invalid API port: {self.api.port}")
        
        # Validate device config
        if not (1 <= self.device.adb_port <= 65535):
            raise ValueError(f"Invalid ADB port: {self.device.adb_port}")
        
        if self.device.screenshot_interval < 1:
            logger.warning("Screenshot interval too low, setting to 1 second")
            self.device.screenshot_interval = 1
        
        if self.device.app_poll_interval < 1:
            logger.warning("App poll interval too low, setting to 1 second")
            self.device.app_poll_interval = 1
        
        # Validate camera settings
        if self.device.camera_quality < 1 or self.device.camera_quality > 100:
            logger.warning("Camera quality out of range, setting to 70")
            self.device.camera_quality = 70
        
        if self.device.camera_format.lower() not in ['jpeg', 'png']:
            logger.warning("Invalid camera format '%s', setting to 'jpeg'", self.device.camera_format)
            self.device.camera_format = 'jpeg'
    
    @classmethod
    @lru_cache(maxsize=1)
    def load(cls) -> "Settings":
        """Load settings with optimized file handling and error recovery."""
        logger.debug("Loading configuration from %s", CONFIG_DIR)
        
        # Initialize with defaults
        config_data = {
            'mqtt': {},
            'api': {},
            'device': {},
            'appmap': {'apps': {}, 'visible': []}
        }
        
        # Load configuration files
        config_files = {
            'mqtt': CONFIG_DIR / "mqtt.yaml",
            'api': CONFIG_DIR / "api.yaml", 
            'device': CONFIG_DIR / "device.yaml",
            'appmap': CONFIG_DIR / "apps.yaml"
        }
        
        for section, config_file in config_files.items():
            if config_file.exists():
                try:
                    data = cls._load_yaml_file(config_file)
                    if section == 'appmap':
                        # Special handling for app config
                        config_data[section] = {
                            'apps': data.get('apps', {}),
                            'visible': data.get('visible') or data.get('options', [])
                        }
                    else:
                        config_data[section] = data
                except Exception as e:
                    logger.error("Failed to load %s: %s", config_file, e)
            else:
                logger.debug("Config file not found: %s", config_file)
        
        # Create config objects with type validation
        try:
            mqtt = cls._create_mqtt_config(config_data['mqtt'])
            api = cls._create_api_config(config_data['api'])
            device = cls._create_device_config(config_data['device'])
            appmap = cls._create_app_config(config_data['appmap'])
        except Exception as e:
            logger.error("Failed to create config objects: %s", e)
            # Fallback to defaults on error
            mqtt = MQTTConfig()
            api = APIConfig()
            device = DeviceConfig()
            appmap = AppConfig()

        # Apply environment variable overrides
        env = cls._load_env()
        mqtt = cls._apply_env_overrides_mqtt(mqtt, env)
        api = cls._apply_env_overrides_api(api, env)
        device = cls._apply_env_overrides_device(device, env)

        # Ensure directories exist
        cls._ensure_directories(device)
        
        settings = Settings(mqtt=mqtt, api=api, device=device, appmap=appmap)
        logger.info("Configuration loaded successfully")
        return settings
    
    @staticmethod
    def _load_yaml_file(file_path: Path) -> Dict[str, Any]:
        """Load and validate YAML file."""
        try:
            with open(file_path, "r", encoding="utf-8") as f:
                data = yaml.safe_load(f)
                return data or {}
        except yaml.YAMLError as e:
            logger.error("Invalid YAML in %s: %s", file_path, e)
            raise
        except Exception as e:
            logger.error("Failed to read %s: %s", file_path, e)
            raise
    
    @staticmethod
    def _create_mqtt_config(data: Dict[str, Any]) -> MQTTConfig:
        """Create MQTT config with type validation."""
        valid_fields = {k: v for k, v in data.items() if k in MQTTConfig.__annotations__}
        return MQTTConfig(**valid_fields)
    
    @staticmethod
    def _create_api_config(data: Dict[str, Any]) -> APIConfig:
        """Create API config with type validation."""
        valid_fields = {k: v for k, v in data.items() if k in APIConfig.__annotations__}
        return APIConfig(**valid_fields)
    
    @staticmethod
    def _create_device_config(data: Dict[str, Any]) -> DeviceConfig:
        """Create device config with type validation and path handling."""
        # Handle path fields
        for path_field in ['screenshots_dir', 'logs_dir', 'run_dir']:
            if path_field in data:
                data[path_field] = Path(data[path_field])
        
        valid_fields = {k: v for k, v in data.items() if k in DeviceConfig.__annotations__}
        return DeviceConfig(**valid_fields)
    
    @staticmethod
    def _create_app_config(data: Dict[str, Any]) -> AppConfig:
        """Create app config with validation."""
        return AppConfig(
            apps=data.get('apps', {}),
            visible=data.get('visible', [])
        )
    
    @staticmethod
    def _apply_env_overrides_mqtt(mqtt: MQTTConfig, env: Dict[str, str]) -> MQTTConfig:
        """Apply environment overrides to MQTT config."""
        env_mappings = {
            'MQTT_HOST': ('host', str),
            'MQTT_PORT': ('port', int),
            'MQTT_USERNAME': ('username', str),
            'MQTT_PASSWORD': ('password', str),
            'MQTT_DISCOVERY_PREFIX': ('discovery_prefix', str),
            'MQTT_BASE_TOPIC': ('base_topic', str)
        }
        
        for env_key, (attr_name, type_func) in env_mappings.items():
            if env_key in env:
                try:
                    setattr(mqtt, attr_name, type_func(env[env_key]))
                except (ValueError, TypeError) as e:
                    logger.warning("Invalid %s value '%s': %s", env_key, env[env_key], e)
        
        return mqtt
    
    @staticmethod
    def _apply_env_overrides_api(api: APIConfig, env: Dict[str, str]) -> APIConfig:
        """Apply environment overrides to API config."""
        if 'API_HOST' in env:
            api.host = env['API_HOST']
        
        if 'API_PORT' in env:
            try:
                api.port = int(env['API_PORT'])
            except ValueError as e:
                logger.warning("Invalid API_PORT value '%s': %s", env['API_PORT'], e)
        
        return api
    
    @staticmethod
    def _apply_env_overrides_device(device: DeviceConfig, env: Dict[str, str]) -> DeviceConfig:
        """Apply environment overrides to device config."""
        # String fields
        string_mappings = {
            'ADB_HOST': 'adb_host',
            'ADB_SERIAL': 'adb_serial',
            'DEVICE_ID': 'device_id',
            'DEVICE_NAME': 'device_name',
            'CAMERA_FORMAT': 'camera_format'
        }
        
        for env_key, attr_name in string_mappings.items():
            if env_key in env:
                setattr(device, attr_name, env[env_key])
        
        # Integer fields
        int_mappings = {
            'ADB_PORT': 'adb_port',
            'CAMERA_MAX_BYTES': 'camera_max_bytes',
            'CAMERA_QUALITY': 'camera_quality',
            'CAMERA_MAX_WIDTH': 'camera_max_width',
            'CAMERA_MAX_HEIGHT': 'camera_max_height',
            'APP_POLL_INTERVAL': 'app_poll_interval'
        }
        
        for env_key, attr_name in int_mappings.items():
            if env_key in env:
                try:
                    setattr(device, attr_name, int(env[env_key]))
                except ValueError as e:
                    logger.warning("Invalid %s value '%s': %s", env_key, env[env_key], e)
        
        # Path fields
        path_mappings = {
            'SCREENSHOTS_DIR': 'screenshots_dir',
            'LOGS_DIR': 'logs_dir',
            'RUN_DIR': 'run_dir'
        }
        
        for env_key, attr_name in path_mappings.items():
            if env_key in env:
                setattr(device, attr_name, Path(env[env_key]))
        
        # Boolean fields
        bool_mappings = {
            'CAMERA_RETAIN': 'camera_retain',
            'CAMERA_COMPRESS': 'camera_compress',
            'APP_WATCH_ENABLED': 'app_watch_enabled'
        }
        
        for env_key, attr_name in bool_mappings.items():
            if env_key in env:
                value = env[env_key].strip().lower()
                setattr(device, attr_name, value in {'1', 'true', 'yes', 'on'})
        
        return device
    
    @staticmethod
    def _ensure_directories(device: DeviceConfig) -> None:
        """Ensure required directories exist."""
        for dir_path in [device.screenshots_dir, device.logs_dir, device.run_dir]:
            full_path = Path.cwd() / dir_path
            try:
                full_path.mkdir(parents=True, exist_ok=True)
                logger.debug("Directory ensured: %s", full_path)
            except Exception as e:
                logger.error("Failed to create directory %s: %s", full_path, e)
                raise
    
    @staticmethod
    def _load_env() -> Dict[str, str]:
        """Load environment variables from .env file and system environment."""
        data: Dict[str, str] = {}
        
        # Load from .env file
        env_path = Path.cwd() / ".env"
        if env_path.exists():
            try:
                content = env_path.read_text(encoding="utf-8")
                for line_num, raw_line in enumerate(content.splitlines(), 1):
                    line = raw_line.strip()
                    if not line or line.startswith("#") or "=" not in line:
                        continue
                    
                    try:
                        key, value = line.split("=", 1)
                        key = key.strip()
                        value = value.strip().strip('"').strip("'")
                        data[key] = value
                    except Exception as e:
                        logger.warning("Invalid .env line %d: %s (%s)", line_num, raw_line, e)
                        
                logger.debug("Loaded %d variables from .env file", len(data))
            except Exception as e:
                logger.warning("Failed to load .env file: %s", e)
        
        # Load from system environment (overrides .env)
        env_prefixes = {'MQTT_', 'ADB_', 'API_', 'CAMERA_'}
        env_keys = {
            'SCREENSHOTS_DIR', 'LOGS_DIR', 'RUN_DIR', 'DEVICE_ID', 
            'DEVICE_NAME', 'APP_WATCH_ENABLED', 'APP_POLL_INTERVAL'
        }
        
        for key, value in os.environ.items():
            if any(key.startswith(prefix) for prefix in env_prefixes) or key in env_keys:
                data[key] = value
        
        return data

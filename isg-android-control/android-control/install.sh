#!/usr/bin/env bash
set -euo pipefail

# One-click installer for ISG Android Controller (Termux + Proot Ubuntu)
# - Installs OS deps
# - Creates Python venv and installs requirements
# - Installs CLI wrapper to ~/.local/bin
# - Optionally starts the service

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

echo "[1/6] Detecting package manager and sudo"
if command -v sudo >/dev/null 2>&1; then
  SUDO=sudo
else
  SUDO=""
fi

PKG="apt-get"
if ! command -v apt-get >/dev/null 2>&1; then
  echo "apt-get not found. If you're in pure Termux, please run scripts/setup.sh or install Proot Ubuntu."
fi

echo "[2/6] Installing OS dependencies (adb, mosquitto-clients, redis, python)"
${SUDO} ${PKG} update -y || true
${SUDO} ${PKG} install -y adb mosquitto-clients redis-server python3 python3-venv python3-pip || true

echo "[i] Checking Redis availability"
if command -v redis-cli >/dev/null 2>&1; then
  if ! redis-cli -h 127.0.0.1 -p 6379 ping >/dev/null 2>&1; then
    echo "[i] Starting local Redis (no systemd)"
    mkdir -p var var/run var/redis
    REDIS_CONF="var/redis.conf"
    cat > "$REDIS_CONF" << 'RC'
port 6379
bind 127.0.0.1
daemonize yes
pidfile var/run/redis.pid
dir var/redis
save ""
RC
    redis-server "$REDIS_CONF" || true
    sleep 0.5
    if redis-cli -h 127.0.0.1 -p 6379 ping >/dev/null 2>&1; then
      echo "[i] Redis started locally (background daemon)."
    else
      echo "[!] Could not start local Redis; caching will fall back to memory if configured."
    fi
  else
    echo "[i] Redis is already reachable on 127.0.0.1:6379"
  fi
else
  echo "[!] redis-cli not found; skipping availability check."
fi

echo "[3/6] Creating virtualenv (.venv) and installing Python deps"
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt

echo "[4/6] Ensuring scripts are executable"
chmod +x scripts/isg-android-control scripts/set_static_ip.sh scripts/install_termux_boot.sh || true

echo "[5/6] Installing CLI wrapper to ~/.local/bin"
BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"
WRAP="$BIN_DIR/isg-android-control"
cat > "$WRAP" << EOF
#!/usr/bin/env bash
set -euo pipefail
REPO_DIR="$REPO_DIR"
if [ ! -d "\$REPO_DIR" ]; then
  echo "[!] Repository directory not found: \$REPO_DIR" >&2
  exit 1
fi
cd "\$REPO_DIR" || exit 1
if [ -f .venv/bin/activate ]; then
  # Prefer local venv created by installer
  source .venv/bin/activate
fi
export PYTHONPATH="\$(pwd)/src:\${PYTHONPATH:-}"
exec python3 -m isg_android_control.cli "\$@"
EOF
chmod +x "$WRAP"
echo "[i] CLI available as: $WRAP (ensure ~/.local/bin in PATH)"

echo "[6/6] Optionally applying configuration from environment"
# No file writes are necessary; service reads from .env and configs/*.yaml
# Create .env if environment variables provided
ENV_FILE=".env"
touch "$ENV_FILE"
append_env() {
  local key="$1"; local val="${!1:-}"
  if [ -n "${val}" ]; then
    if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
      sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE" || true
    else
      echo "${key}=${val}" >> "$ENV_FILE"
    fi
  fi
}
for k in REDIS_URL MQTT_HOST MQTT_PORT MQTT_USERNAME MQTT_PASSWORD MQTT_DISCOVERY_PREFIX MQTT_BASE_TOPIC ADB_HOST ADB_PORT ADB_SERIAL SCREENSHOTS_DIR LOGS_DIR RUN_DIR; do
  append_env "$k"
done

START_NOW="${START_NOW:-1}"
if [ "$START_NOW" = "1" ]; then
  echo "[i] Starting service via isg-android-control start"
  PATH="$HOME/.local/bin:$PATH" isg-android-control start || true
  echo "Use 'isg-android-control logs' to view logs."
else
  echo "[i] Skipping auto-start (START_NOW=0). You can run: isg-android-control start"
fi

echo "[OK] Install complete."

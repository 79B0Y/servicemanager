#!/usr/bin/env bash
set -euo pipefail

# Install Termux:Boot startup script that starts the controller service on boot.
# Requires the Termux:Boot app installed and storage permission granted.

BOOT_DIR="$HOME/.termux/boot"
mkdir -p "$BOOT_DIR"

cat > "$BOOT_DIR/isg-android-control.sh" << 'EOF'
#!/data/data/com.termux/files/usr/bin/bash
cd "$HOME/android-control" || exit 0
if [ -f .venv/bin/activate ]; then
  source .venv/bin/activate
fi
export PYTHONPATH="$(pwd)/src:${PYTHONPATH:-}"
bash scripts/isg-android-control start
EOF

chmod +x "$BOOT_DIR/isg-android-control.sh"
echo "Installed Termux:Boot script at $BOOT_DIR/isg-android-control.sh"
echo "Make sure the repository is at ~/android-control or edit the script path."


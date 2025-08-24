#!/usr/bin/env bash
set -euo pipefail

if [[ ! -d .venv ]]; then
  echo "Virtualenv .venv not found. Run scripts/dev_setup.sh first." >&2
  exit 1
fi

source .venv/bin/activate
pytest -q


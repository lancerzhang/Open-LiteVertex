#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  if command -v python >/dev/null 2>&1; then
    PYTHON_BIN="python"
  else
    echo "python3 is not installed or not on PATH." >&2
    exit 1
  fi
fi

exec "$PYTHON_BIN" "$SCRIPT_DIR/entra_client.py" start-broker --login-mode device-code "$@"

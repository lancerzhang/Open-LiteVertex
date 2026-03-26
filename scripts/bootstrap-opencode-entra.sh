#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
AUTH_FILE="$HOME/.local/share/opencode/auth.json"
MODE="start"
FORCE_LOGIN="0"

if [[ "${1:-}" == "--login-only" ]]; then
  MODE="login-only"
  shift
elif [[ "${1:-}" == "--relogin" ]]; then
  FORCE_LOGIN="1"
  shift
fi

resolve_python_bin() {
  if [[ -n "${PYTHON_BIN:-}" ]] && command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    printf '%s\n' "$PYTHON_BIN"
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    printf '%s\n' "python3"
    return 0
  fi
  if command -v python >/dev/null 2>&1; then
    printf '%s\n' "python"
    return 0
  fi
  return 1
}

has_litellm_auth() {
  local python_bin
  python_bin=$(resolve_python_bin) || return 1
  "$python_bin" - "$AUTH_FILE" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.exists():
    raise SystemExit(1)
try:
    payload = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(1)
entry = payload.get("litellm") if isinstance(payload, dict) else None
raise SystemExit(0 if isinstance(entry, dict) and entry else 1)
PY
}

run_litellm_login() {
  echo "No saved Entra LiteVertex login found. Opening OpenCode provider login..." >&2
  opencode auth login
}

"$SCRIPT_DIR/setup-opencode-entra-client.sh"
unset ENTRA_OPENCODE_PLUGIN_DISABLED

if ! command -v opencode >/dev/null 2>&1; then
  echo "opencode is not installed. Install it first, for example: npm install -g opencode-ai" >&2
  exit 1
fi

if [[ "$MODE" == "login-only" ]]; then
  run_litellm_login
  exit 0
fi

if [[ "$FORCE_LOGIN" == "1" ]] || ! has_litellm_auth; then
  run_litellm_login
fi

exec opencode "$@"

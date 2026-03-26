#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
SOURCE_FILE="$ROOT_DIR/plugins/entra-litellm-auth.ts"
CONFIG_SOURCE_FILE="$ROOT_DIR/config/opencode.global.json"
CONFIG_DIR="$HOME/.config/opencode"
TARGET_DIR="$CONFIG_DIR/plugins"
TARGET_FILE="$TARGET_DIR/entra-litellm-auth.ts"
GLOBAL_CONFIG_FILE="$CONFIG_DIR/opencode.json"
GLOBAL_CACHE_FILE="$CONFIG_DIR/entra-device-token.json"
LEGACY_CACHE_FILE="$ROOT_DIR/.secrets/entra-device-token.json"
AUTH_FILE="$HOME/.local/share/opencode/auth.json"
MODE="start"
FORCE_LOGIN="0"

if [[ "${1:-}" == "--setup-only" ]]; then
  MODE="setup-only"
  shift
elif [[ "${1:-}" == "--login-only" ]]; then
  MODE="login-only"
  shift
elif [[ "${1:-}" == "--relogin" ]]; then
  FORCE_LOGIN="1"
  shift
fi

if [[ ! -f "$SOURCE_FILE" ]]; then
  echo "Missing plugin source: $SOURCE_FILE" >&2
  exit 1
fi

if [[ ! -f "$CONFIG_SOURCE_FILE" ]]; then
  echo "Missing global config template: $CONFIG_SOURCE_FILE" >&2
  exit 1
fi

if command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN=python3
elif command -v python >/dev/null 2>&1; then
  PYTHON_BIN=python
else
  echo "Python is required to merge the global OpenCode config." >&2
  exit 1
fi

mkdir -p "$TARGET_DIR"
cp "$SOURCE_FILE" "$TARGET_FILE"

"$PYTHON_BIN" - "$CONFIG_SOURCE_FILE" "$GLOBAL_CONFIG_FILE" <<'PY'
import json
import sys
from pathlib import Path

template_path = Path(sys.argv[1])
target_path = Path(sys.argv[2])

template = json.loads(template_path.read_text(encoding="utf-8"))
if target_path.exists():
    current = json.loads(target_path.read_text(encoding="utf-8"))
else:
    current = {}

current["$schema"] = template.get("$schema", current.get("$schema"))

enabled = []
for item in current.get("enabled_providers", []):
    if item not in enabled:
        enabled.append(item)
for item in template.get("enabled_providers", []):
    if item not in enabled:
        enabled.append(item)
current["enabled_providers"] = enabled

providers = current.get("provider")
if not isinstance(providers, dict):
    providers = {}
current["provider"] = providers

for provider_id, provider_value in template.get("provider", {}).items():
    providers[provider_id] = provider_value

current["model"] = template.get("model", current.get("model"))
current["small_model"] = template.get("small_model", current.get("small_model"))

target_path.parent.mkdir(parents=True, exist_ok=True)
target_path.write_text(json.dumps(current, indent=2) + "\n", encoding="utf-8")
PY

if [[ ! -f "$GLOBAL_CACHE_FILE" && -f "$LEGACY_CACHE_FILE" ]]; then
  cp "$LEGACY_CACHE_FILE" "$GLOBAL_CACHE_FILE"
fi

chmod 0644 "$TARGET_FILE"
chmod 0644 "$GLOBAL_CONFIG_FILE"
chmod 0600 "$GLOBAL_CACHE_FILE" 2>/dev/null || true

if [[ "$MODE" == "setup-only" ]]; then
  exit 0
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

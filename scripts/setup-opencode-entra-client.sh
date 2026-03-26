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

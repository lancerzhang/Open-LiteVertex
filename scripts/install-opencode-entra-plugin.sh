#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
SOURCE_FILE="$ROOT_DIR/plugins/entra-litellm-auth.ts"
TARGET_DIR="$HOME/.config/opencode/plugins"
TARGET_FILE="$TARGET_DIR/entra-litellm-auth.ts"
GLOBAL_CACHE_FILE="$HOME/.config/opencode/entra-device-token.json"
LEGACY_CACHE_FILE="$ROOT_DIR/.secrets/entra-device-token.json"

if [[ ! -f "$SOURCE_FILE" ]]; then
  echo "Missing plugin source: $SOURCE_FILE" >&2
  exit 1
fi

mkdir -p "$TARGET_DIR"
cp "$SOURCE_FILE" "$TARGET_FILE"

if [[ ! -f "$GLOBAL_CACHE_FILE" && -f "$LEGACY_CACHE_FILE" ]]; then
  cp "$LEGACY_CACHE_FILE" "$GLOBAL_CACHE_FILE"
fi

chmod 0644 "$TARGET_FILE"
chmod 0600 "$GLOBAL_CACHE_FILE" 2>/dev/null || true

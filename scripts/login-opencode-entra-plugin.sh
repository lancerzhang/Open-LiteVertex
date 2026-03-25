#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

exec "$SCRIPT_DIR/start-opencode-entra-plugin.sh" providers login --provider litellm "$@"

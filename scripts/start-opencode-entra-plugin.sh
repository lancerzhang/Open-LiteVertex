#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
DEMO_ENV_FILE="$ROOT_DIR/.demo.env"
ENTRA_ENV_FILE="$ROOT_DIR/.entra.env"
CONFIG_FILE="$ROOT_DIR/opencode.json"

load_env_file() {
  local env_file=$1
  [[ -f "$env_file" ]] || return 0

  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    local key=${line%%=*}
    local value=${line#*=}
    export "$key=$value"
  done < "$env_file"
}

if [[ ! -f "$DEMO_ENV_FILE" ]]; then
  echo "Missing .demo.env. Run scripts/deploy-demo.ps1 first." >&2
  exit 1
fi

load_env_file "$DEMO_ENV_FILE"
load_env_file "$ENTRA_ENV_FILE"

if [[ -z "${LITELLM_BASE_URL:-}" ]]; then
  echo "LITELLM_BASE_URL is missing from .demo.env." >&2
  exit 1
fi

for required_var in ENTRA_TENANT_ID ENTRA_CLIENT_ID ENTRA_PUBLIC_CLIENT_ID; do
  if [[ -z "${!required_var:-}" ]]; then
    echo "$required_var is required. Create .entra.env or export it before starting OpenCode." >&2
    exit 1
  fi
done

"$SCRIPT_DIR/install-opencode-entra-plugin.sh"

export OPENCODE_CONFIG="$CONFIG_FILE"
export ENTRA_ENV_PATH="$ENTRA_ENV_FILE"
export LITELLM_OPENAI_BASE_URL="${LITELLM_BASE_URL%/}/v1"
export LITELLM_API_KEY="${LITELLM_API_KEY:-opencode-entra-plugin-placeholder}"
unset ENTRA_OPENCODE_PLUGIN_DISABLED

if ! command -v opencode >/dev/null 2>&1; then
  echo "opencode is not installed. Install it first, for example: npm install -g opencode-ai" >&2
  exit 1
fi

cd "$ROOT_DIR"
exec opencode "$@"

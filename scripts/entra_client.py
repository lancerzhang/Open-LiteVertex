#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

from entra_auth import DEFAULT_TOKEN_CACHE_PATH, EntraAuthError, acquire_access_token


ROOT_DIR = Path(__file__).resolve().parent.parent
ENTRA_ENV_PATH = ROOT_DIR / ".entra.env"
DEMO_ENV_PATH = ROOT_DIR / ".demo.env"


class CliError(RuntimeError):
    pass


def _load_dotenv(path: Path, *, missing_hint: str | None = None) -> dict[str, str]:
    if not path.exists():
        message = f"Missing {path.name}."
        if missing_hint:
            message = f"{message} {missing_hint}"
        raise CliError(message)

    env: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        key, sep, value = line.partition("=")
        if not sep:
            continue
        env[key.strip()] = value.strip()
    return env


def _merge_env(*env_sets: dict[str, str]) -> dict[str, str]:
    merged = dict(os.environ)
    for env_set in env_sets:
        merged.update(env_set)
    return merged


def _require_env_values(env: dict[str, str], names: list[str], *, source_name: str) -> None:
    missing = [name for name in names if not env.get(name, "").strip()]
    if missing:
        quoted = ", ".join(missing)
        raise CliError(f"{source_name} is missing {quoted}.")


def _require_command(name: str, *, install_hint: str | None = None) -> str:
    path = shutil.which(name)
    if path:
        return path

    message = f"{name} is not installed or not on PATH."
    if install_hint:
        message = f"{message} {install_hint}"
    raise CliError(message)


def _resolve_token_request(args: argparse.Namespace) -> tuple[str, str, str, str]:
    entra_env: dict[str, str] = {}
    if args.entra_env_path.exists():
        entra_env = _load_dotenv(args.entra_env_path)

    tenant_id = (args.tenant_id or entra_env.get("ENTRA_TENANT_ID", "")).strip()
    client_id = (args.client_id or entra_env.get("ENTRA_CLIENT_ID", "")).strip()
    public_client_id = (args.public_client_id or entra_env.get("ENTRA_PUBLIC_CLIENT_ID", "")).strip()
    scope = (args.scope or entra_env.get("ENTRA_SCOPE", "")).strip()

    if not tenant_id or not client_id:
        raise CliError(
            "Tenant ID and client ID are required. Pass --tenant-id/--client-id or create .entra.env first."
        )
    if not public_client_id:
        raise CliError(
            "ENTRA_PUBLIC_CLIENT_ID is required for native device code login. "
            "Pass --public-client-id or create .entra.env first."
        )
    if not scope:
        scope = f"api://{client_id}/access_as_user"

    return tenant_id, client_id, public_client_id, scope


def _strip_remainder_separator(values: list[str]) -> list[str]:
    if values and values[0] == "--":
        return values[1:]
    return values


def _run_opencode(opencode_env: dict[str, str], opencode_args: list[str]) -> int:
    opencode_path = _require_command("opencode", install_hint="Install it first, for example: npm install -g opencode-ai")
    completed = subprocess.run(
        [opencode_path, *_strip_remainder_separator(opencode_args)],
        cwd=ROOT_DIR,
        env=opencode_env,
        check=False,
    )
    return completed.returncode


def _run_opencode_direct(args: argparse.Namespace) -> int:
    entra_env = _load_dotenv(
        args.entra_env_path,
        missing_hint="Run scripts\\setup-entra-oss.ps1 first." if os.name == "nt" else "Run scripts/setup-entra-oss.ps1 first.",
    )
    demo_env = _load_dotenv(
        args.demo_env_path,
        missing_hint="Run scripts\\deploy-demo.ps1 first." if os.name == "nt" else "Run scripts/deploy-demo.ps1 first.",
    )
    _require_env_values(
        entra_env,
        ["ENTRA_TENANT_ID", "ENTRA_CLIENT_ID", "ENTRA_PUBLIC_CLIENT_ID"],
        source_name=args.entra_env_path.name,
    )
    _require_env_values(demo_env, ["LITELLM_BASE_URL"], source_name=args.demo_env_path.name)

    tenant_id = entra_env["ENTRA_TENANT_ID"].strip()
    client_id = entra_env["ENTRA_CLIENT_ID"].strip()
    public_client_id = entra_env["ENTRA_PUBLIC_CLIENT_ID"].strip()
    scope = entra_env.get("ENTRA_SCOPE", "").strip() or f"api://{client_id}/access_as_user"
    token = acquire_access_token(
        tenant_id=tenant_id,
        client_id=client_id,
        scope=scope,
        public_client_id=public_client_id,
        token_cache_path=args.token_cache_path,
    )

    opencode_env = _merge_env(entra_env, demo_env)
    opencode_env["ENTRA_ACCESS_TOKEN"] = str(token["accessToken"])
    opencode_env["ENTRA_ACCESS_TOKEN_EXPIRES_ON"] = str(token.get("expiresOn", ""))
    opencode_env["LITELLM_API_KEY"] = str(token["accessToken"])
    opencode_env["LITELLM_OPENAI_BASE_URL"] = demo_env["LITELLM_BASE_URL"].strip().rstrip("/") + "/v1"
    opencode_env["ENTRA_OPENCODE_PLUGIN_DISABLED"] = "1"

    print("Using Entra access token directly against LiteLLM.")
    if token.get("expiresOn"):
        print(f"Token expires on: {token['expiresOn']}")

    return _run_opencode(opencode_env, args.opencode_args)


def _get_token(args: argparse.Namespace) -> int:
    tenant_id, client_id, public_client_id, scope = _resolve_token_request(args)
    token = acquire_access_token(
        tenant_id=tenant_id,
        client_id=client_id,
        scope=scope,
        public_client_id=public_client_id,
        token_cache_path=args.token_cache_path,
    )
    print(json.dumps(token))
    return 0


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Cross-platform client helpers for Entra-authenticated LiteLLM access.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    token_parser = subparsers.add_parser("get-token", help="Fetch an Entra access token via native device code.")
    token_parser.add_argument("--tenant-id")
    token_parser.add_argument("--client-id")
    token_parser.add_argument("--public-client-id")
    token_parser.add_argument("--scope")
    token_parser.add_argument("--token-cache-path", type=Path, default=DEFAULT_TOKEN_CACHE_PATH)
    token_parser.add_argument("--entra-env-path", type=Path, default=ENTRA_ENV_PATH)
    token_parser.set_defaults(handler=_get_token)

    run_direct_parser = subparsers.add_parser("run-opencode-direct", help="Run opencode with a direct Entra access token.")
    run_direct_parser.add_argument("--entra-env-path", type=Path, default=ENTRA_ENV_PATH)
    run_direct_parser.add_argument("--demo-env-path", type=Path, default=DEMO_ENV_PATH)
    run_direct_parser.add_argument("--token-cache-path", type=Path, default=DEFAULT_TOKEN_CACHE_PATH)
    run_direct_parser.add_argument("opencode_args", nargs=argparse.REMAINDER)
    run_direct_parser.set_defaults(handler=_run_opencode_direct)

    return parser


def main() -> int:
    parser = _build_parser()
    args = parser.parse_args()
    try:
        return int(args.handler(args))
    except CliError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    except EntraAuthError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("Interrupted.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())

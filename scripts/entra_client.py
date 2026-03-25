#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

from entra_auth import DEFAULT_TOKEN_CACHE_PATH, EntraAuthError, acquire_access_token, default_login_mode


ROOT_DIR = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = Path(__file__).resolve().parent
SECRETS_DIR = ROOT_DIR / ".secrets"
ENTRA_ENV_PATH = ROOT_DIR / ".entra.env"
DEMO_ENV_PATH = ROOT_DIR / ".demo.env"
BROKER_SCRIPT_PATH = SCRIPTS_DIR / "entra_litellm_broker.py"
PID_FILE_PATH = SECRETS_DIR / "entra-broker.pid"
STDOUT_LOG_PATH = SECRETS_DIR / "entra-broker.stdout.log"
STDERR_LOG_PATH = SECRETS_DIR / "entra-broker.stderr.log"

DEFAULT_BROKER_HOST = "127.0.0.1"
DEFAULT_BROKER_PORT = 8787
DEFAULT_BROKER_API_KEY = "opencode-local-broker-key"
DEFAULT_REFRESH_SKEW_SECONDS = 300


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
    if not scope:
        scope = f"api://{client_id}/access_as_user"

    return tenant_id, client_id, public_client_id, scope


def _process_exists(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def _read_pid(pid_file: Path) -> int | None:
    if not pid_file.exists():
        return None
    raw = pid_file.read_text(encoding="utf-8").strip()
    if not raw:
        return None
    try:
        return int(raw)
    except ValueError:
        return None


def _broker_connect_host(bind_host: str) -> str:
    if bind_host in {"0.0.0.0", "::"}:
        return "127.0.0.1"
    return bind_host


def _start_background_process(command: list[str], *, cwd: Path, env: dict[str, str], stdout_path: Path, stderr_path: Path) -> subprocess.Popen[Any]:
    stdout_handle = stdout_path.open("a", encoding="utf-8")
    stderr_handle = stderr_path.open("a", encoding="utf-8")
    try:
        popen_kwargs: dict[str, Any] = {
            "cwd": str(cwd),
            "env": env,
            "stdout": stdout_handle,
            "stderr": stderr_handle,
            "text": True,
        }
        if os.name == "nt":
            popen_kwargs["creationflags"] = 0x00000008 | 0x00000200
        else:
            popen_kwargs["start_new_session"] = True

        return subprocess.Popen(command, **popen_kwargs)
    finally:
        stdout_handle.close()
        stderr_handle.close()


def _wait_for_healthcheck(host: str, port: int, *, timeout_seconds: int = 30) -> None:
    url = f"http://{_broker_connect_host(host)}:{port}/healthz"
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=2) as response:
                payload = json.loads(response.read().decode("utf-8"))
                if payload.get("status") == "ok":
                    return
        except (OSError, urllib.error.URLError, json.JSONDecodeError):
            pass
        time.sleep(1)

    raise CliError(f"Broker process started but did not become healthy on {url}.")


def _print_broker_status(
    pid: int,
    *,
    host: str,
    port: int,
    broker_api_key: str,
    expires_on: str,
    auth_mode: str,
    already_running: bool,
) -> None:
    state = "already running" if already_running else "started"
    connect_host = _broker_connect_host(host)
    print(f"Broker {state} on PID {pid}.")
    print(f"Broker bind host: {host}")
    print(f"Broker base URL: http://{connect_host}:{port}/v1")
    print(f"Broker API key: {broker_api_key}")
    print(f"Auth mode: {auth_mode}")
    if expires_on:
        print(f"Initial Entra token expires on: {expires_on}")
    print(f"Broker stdout log: {STDOUT_LOG_PATH}")
    print(f"Broker stderr log: {STDERR_LOG_PATH}")


def _start_broker(args: argparse.Namespace) -> int:
    if not BROKER_SCRIPT_PATH.exists():
        raise CliError(f"Missing broker script: {BROKER_SCRIPT_PATH}")

    entra_env = _load_dotenv(
        args.entra_env_path,
        missing_hint="Run scripts\\setup-entra-oss.ps1 first." if os.name == "nt" else "Run scripts/setup-entra-oss.ps1 first.",
    )
    demo_env = _load_dotenv(
        args.demo_env_path,
        missing_hint="Run scripts\\deploy-demo.ps1 first." if os.name == "nt" else "Run scripts/deploy-demo.ps1 first.",
    )
    _require_env_values(entra_env, ["ENTRA_TENANT_ID", "ENTRA_CLIENT_ID"], source_name=args.entra_env_path.name)
    _require_env_values(demo_env, ["LITELLM_BASE_URL"], source_name=args.demo_env_path.name)

    SECRETS_DIR.mkdir(parents=True, exist_ok=True)
    existing_pid = _read_pid(PID_FILE_PATH)
    if existing_pid and _process_exists(existing_pid):
        _print_broker_status(
            existing_pid,
            host=args.host,
            port=args.port,
            broker_api_key=args.broker_api_key,
            expires_on="",
            auth_mode=args.auth_mode,
            already_running=True,
        )
        return 0

    tenant_id = entra_env["ENTRA_TENANT_ID"].strip()
    client_id = entra_env["ENTRA_CLIENT_ID"].strip()
    public_client_id = entra_env.get("ENTRA_PUBLIC_CLIENT_ID", "").strip()
    scope = entra_env.get("ENTRA_SCOPE", "").strip() or f"api://{client_id}/access_as_user"
    token = acquire_access_token(
        tenant_id=tenant_id,
        client_id=client_id,
        scope=scope,
        auth_mode=args.auth_mode,
        login_mode=args.login_mode,
        public_client_id=public_client_id,
        token_cache_path=args.token_cache_path,
        refresh_skew_seconds=DEFAULT_REFRESH_SKEW_SECONDS,
    )
    resolved_auth_mode = str(token.get("authMode", "")).strip() or "unknown"

    env = _merge_env(entra_env, demo_env)
    env["BROKER_HOST"] = args.host
    env["BROKER_PORT"] = str(args.port)
    env["BROKER_LOG_LEVEL"] = "info"
    env["BROKER_UPSTREAM_BASE_URL"] = demo_env["LITELLM_BASE_URL"].strip().rstrip("/")
    env["ENTRA_SCOPE"] = scope
    env["ENTRA_AUTH_MODE"] = args.auth_mode
    env["ENTRA_PUBLIC_CLIENT_ID"] = public_client_id
    env["ENTRA_AZURE_CLI_LOGIN_MODE"] = args.login_mode
    env["ENTRA_TOKEN_CACHE_PATH"] = str(args.token_cache_path)
    env["ENTRA_BROKER_API_KEY"] = args.broker_api_key
    env["BROKER_REFRESH_SKEW_SECONDS"] = str(DEFAULT_REFRESH_SKEW_SECONDS)

    process = _start_background_process(
        [sys.executable, str(BROKER_SCRIPT_PATH)],
        cwd=ROOT_DIR,
        env=env,
        stdout_path=STDOUT_LOG_PATH,
        stderr_path=STDERR_LOG_PATH,
    )
    PID_FILE_PATH.write_text(str(process.pid), encoding="utf-8")

    try:
        _wait_for_healthcheck(args.host, args.port)
    except Exception:
        _stop_process(process.pid)
        PID_FILE_PATH.unlink(missing_ok=True)
        raise

    _print_broker_status(
        process.pid,
        host=args.host,
        port=args.port,
        broker_api_key=args.broker_api_key,
        expires_on=str(token.get("expiresOn", "")),
        auth_mode=resolved_auth_mode,
        already_running=False,
    )
    return 0


def _stop_process(pid: int) -> bool:
    if not _process_exists(pid):
        return False

    if os.name == "nt":
        subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"], capture_output=True, text=True, check=False)
        return not _process_exists(pid)

    os.kill(pid, signal.SIGTERM)
    deadline = time.time() + 5
    while time.time() < deadline:
        if not _process_exists(pid):
            return True
        time.sleep(0.2)
    os.kill(pid, signal.SIGKILL)
    return not _process_exists(pid)


def _stop_broker(_: argparse.Namespace) -> int:
    pid = _read_pid(PID_FILE_PATH)
    if pid is None:
        print("No broker PID file found.")
        return 0

    if _stop_process(pid):
        print(f"Stopped broker PID {pid}.")
    else:
        print(f"Broker process {pid} is not running.")

    PID_FILE_PATH.unlink(missing_ok=True)
    return 0


def _strip_remainder_separator(values: list[str]) -> list[str]:
    if values and values[0] == "--":
        return values[1:]
    return values


def _run_opencode(opencode_env: dict[str, str], opencode_args: list[str]) -> int:
    opencode_path = _require_command("opencode", install_hint="Install it first, for example: npm install -g opencode-ai")
    completed = subprocess.run([opencode_path, *_strip_remainder_separator(opencode_args)], cwd=ROOT_DIR, env=opencode_env, check=False)
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
    _require_env_values(entra_env, ["ENTRA_TENANT_ID", "ENTRA_CLIENT_ID"], source_name=args.entra_env_path.name)
    _require_env_values(demo_env, ["LITELLM_BASE_URL"], source_name=args.demo_env_path.name)

    tenant_id = entra_env["ENTRA_TENANT_ID"].strip()
    client_id = entra_env["ENTRA_CLIENT_ID"].strip()
    public_client_id = entra_env.get("ENTRA_PUBLIC_CLIENT_ID", "").strip()
    scope = entra_env.get("ENTRA_SCOPE", "").strip() or f"api://{client_id}/access_as_user"
    token = acquire_access_token(
        tenant_id=tenant_id,
        client_id=client_id,
        scope=scope,
        auth_mode=args.auth_mode,
        login_mode=args.login_mode,
        public_client_id=public_client_id,
        token_cache_path=args.token_cache_path,
    )

    opencode_env = _merge_env(entra_env, demo_env)
    opencode_env["ENTRA_ACCESS_TOKEN"] = str(token["accessToken"])
    opencode_env["ENTRA_ACCESS_TOKEN_EXPIRES_ON"] = str(token.get("expiresOn", ""))
    opencode_env["LITELLM_API_KEY"] = str(token["accessToken"])
    opencode_env["LITELLM_OPENAI_BASE_URL"] = demo_env["LITELLM_BASE_URL"].strip().rstrip("/") + "/v1"

    print("Using Entra access token directly against LiteLLM.")
    if token.get("expiresOn"):
        print(f"Token expires on: {token['expiresOn']}")

    return _run_opencode(opencode_env, args.opencode_args)


def _run_opencode_broker(args: argparse.Namespace) -> int:
    start_args = argparse.Namespace(
        port=args.port,
        host=args.host,
        broker_api_key=args.broker_api_key,
        auth_mode=args.auth_mode,
        login_mode=args.login_mode,
        entra_env_path=args.entra_env_path,
        demo_env_path=args.demo_env_path,
        token_cache_path=args.token_cache_path,
    )
    _start_broker(start_args)

    opencode_env = dict(os.environ)
    opencode_env["ENTRA_BROKER_BASE_URL"] = f"http://{_broker_connect_host(args.host)}:{args.port}/v1"
    opencode_env["ENTRA_BROKER_API_KEY"] = args.broker_api_key
    opencode_env["LITELLM_OPENAI_BASE_URL"] = opencode_env["ENTRA_BROKER_BASE_URL"]
    opencode_env["LITELLM_API_KEY"] = args.broker_api_key
    return _run_opencode(opencode_env, args.opencode_args)


def _get_token(args: argparse.Namespace) -> int:
    tenant_id, client_id, public_client_id, scope = _resolve_token_request(args)
    token = acquire_access_token(
        tenant_id=tenant_id,
        client_id=client_id,
        scope=scope,
        auth_mode=args.auth_mode,
        login_mode=args.login_mode,
        public_client_id=public_client_id,
        token_cache_path=args.token_cache_path,
    )
    print(json.dumps(token))
    return 0


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Cross-platform client helpers for Entra-authenticated LiteLLM access.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    token_parser = subparsers.add_parser("get-token", help="Fetch an Entra access token via device code or Azure CLI.")
    token_parser.add_argument("--tenant-id")
    token_parser.add_argument("--client-id")
    token_parser.add_argument("--public-client-id")
    token_parser.add_argument("--scope")
    token_parser.add_argument("--auth-mode", choices=["auto", "device-code", "azure-cli"], default="auto")
    token_parser.add_argument("--login-mode", choices=["interactive", "device-code"], default=default_login_mode())
    token_parser.add_argument("--token-cache-path", type=Path, default=DEFAULT_TOKEN_CACHE_PATH)
    token_parser.add_argument("--entra-env-path", type=Path, default=ENTRA_ENV_PATH)
    token_parser.set_defaults(handler=_get_token)

    start_broker_parser = subparsers.add_parser("start-broker", help="Start the local Entra broker.")
    start_broker_parser.add_argument("--port", type=int, default=DEFAULT_BROKER_PORT)
    start_broker_parser.add_argument("--host", default=DEFAULT_BROKER_HOST)
    start_broker_parser.add_argument("--broker-api-key", default=DEFAULT_BROKER_API_KEY)
    start_broker_parser.add_argument("--auth-mode", choices=["auto", "device-code", "azure-cli"], default="auto")
    start_broker_parser.add_argument("--login-mode", choices=["interactive", "device-code"], default=default_login_mode())
    start_broker_parser.add_argument("--entra-env-path", type=Path, default=ENTRA_ENV_PATH)
    start_broker_parser.add_argument("--demo-env-path", type=Path, default=DEMO_ENV_PATH)
    start_broker_parser.add_argument("--token-cache-path", type=Path, default=DEFAULT_TOKEN_CACHE_PATH)
    start_broker_parser.set_defaults(handler=_start_broker)

    stop_broker_parser = subparsers.add_parser("stop-broker", help="Stop the local Entra broker.")
    stop_broker_parser.set_defaults(handler=_stop_broker)

    run_direct_parser = subparsers.add_parser("run-opencode-direct", help="Run opencode with a direct Entra access token.")
    run_direct_parser.add_argument("--auth-mode", choices=["auto", "device-code", "azure-cli"], default="auto")
    run_direct_parser.add_argument("--login-mode", choices=["interactive", "device-code"], default=default_login_mode())
    run_direct_parser.add_argument("--entra-env-path", type=Path, default=ENTRA_ENV_PATH)
    run_direct_parser.add_argument("--demo-env-path", type=Path, default=DEMO_ENV_PATH)
    run_direct_parser.add_argument("--token-cache-path", type=Path, default=DEFAULT_TOKEN_CACHE_PATH)
    run_direct_parser.add_argument("opencode_args", nargs=argparse.REMAINDER)
    run_direct_parser.set_defaults(handler=_run_opencode_direct)

    run_broker_parser = subparsers.add_parser("run-opencode-broker", help="Run opencode against the local Entra broker.")
    run_broker_parser.add_argument("--port", type=int, default=DEFAULT_BROKER_PORT)
    run_broker_parser.add_argument("--host", default=DEFAULT_BROKER_HOST)
    run_broker_parser.add_argument("--broker-api-key", default=DEFAULT_BROKER_API_KEY)
    run_broker_parser.add_argument("--auth-mode", choices=["auto", "device-code", "azure-cli"], default="auto")
    run_broker_parser.add_argument("--login-mode", choices=["interactive", "device-code"], default=default_login_mode())
    run_broker_parser.add_argument("--entra-env-path", type=Path, default=ENTRA_ENV_PATH)
    run_broker_parser.add_argument("--demo-env-path", type=Path, default=DEMO_ENV_PATH)
    run_broker_parser.add_argument("--token-cache-path", type=Path, default=DEFAULT_TOKEN_CACHE_PATH)
    run_broker_parser.add_argument("opencode_args", nargs=argparse.REMAINDER)
    run_broker_parser.set_defaults(handler=_run_opencode_broker)

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

from __future__ import annotations

import json
import os
import shutil
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any


ROOT_DIR = Path(__file__).resolve().parent.parent
DEFAULT_TOKEN_CACHE_PATH = ROOT_DIR / ".secrets" / "entra-device-token.json"
DEVICE_CODE_GRANT_TYPE = "urn:ietf:params:oauth:grant-type:device_code"
LOGIN_HINT = (
    "Run scripts/get-entra-token.ps1 on Windows, scripts/get-entra-token.sh on Linux, "
    "or python scripts/entra_client.py get-token once to complete login."
)


class EntraAuthError(RuntimeError):
    pass


class EntraInteractionRequired(EntraAuthError):
    pass


@dataclass
class AccessTokenResult:
    access_token: str
    expires_on: str
    expires_on_epoch: int | None
    tenant: str
    client_id: str
    scope: str
    auth_mode: str
    public_client_id: str | None = None

    def to_payload(self) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "accessToken": self.access_token,
            "expiresOn": self.expires_on,
            "expiresOnEpoch": self.expires_on_epoch,
            "tenant": self.tenant,
            "clientId": self.client_id,
            "scope": self.scope,
            "authMode": self.auth_mode,
        }
        if self.public_client_id:
            payload["publicClientId"] = self.public_client_id
        return payload


def default_login_mode() -> str:
    return "interactive" if os.name == "nt" else "device-code"


def resolve_auth_mode(auth_mode: str, *, public_client_id: str | None) -> str:
    normalized = (auth_mode or "auto").strip().lower() or "auto"
    if normalized not in {"auto", "device-code", "azure-cli"}:
        raise EntraAuthError(f"Unsupported auth mode: {auth_mode}")
    if normalized == "auto":
        return "device-code" if (public_client_id or "").strip() else "azure-cli"
    return normalized


def acquire_access_token(
    *,
    tenant_id: str,
    client_id: str,
    scope: str,
    auth_mode: str = "auto",
    login_mode: str | None = None,
    public_client_id: str | None = None,
    token_cache_path: Path | None = None,
    refresh_skew_seconds: int = 0,
    allow_user_interaction: bool = True,
    az_path: str | None = None,
) -> dict[str, Any]:
    resolved_auth_mode = resolve_auth_mode(auth_mode, public_client_id=public_client_id)
    effective_login_mode = (login_mode or default_login_mode()).strip().lower() or default_login_mode()

    if resolved_auth_mode == "device-code":
        return _acquire_access_token_device_code(
            tenant_id=tenant_id,
            client_id=client_id,
            public_client_id=(public_client_id or "").strip(),
            scope=scope,
            token_cache_path=token_cache_path or DEFAULT_TOKEN_CACHE_PATH,
            refresh_skew_seconds=refresh_skew_seconds,
            allow_user_interaction=allow_user_interaction,
        ).to_payload()

    return _acquire_access_token_azure_cli(
        tenant_id=tenant_id,
        client_id=client_id,
        scope=scope,
        login_mode=effective_login_mode,
        allow_user_interaction=allow_user_interaction,
        az_path=az_path,
    ).to_payload()


def _acquire_access_token_device_code(
    *,
    tenant_id: str,
    client_id: str,
    public_client_id: str,
    scope: str,
    token_cache_path: Path,
    refresh_skew_seconds: int,
    allow_user_interaction: bool,
) -> AccessTokenResult:
    if not public_client_id:
        raise EntraAuthError(
            "Device code auth requires ENTRA_PUBLIC_CLIENT_ID. "
            "Rerun scripts/setup-entra-oss.ps1 or pass --public-client-id explicitly."
        )

    requested_scope = _normalize_device_code_scope(scope)
    cache_record = _load_device_token_cache(
        token_cache_path,
        tenant_id=tenant_id,
        client_id=client_id,
        public_client_id=public_client_id,
        scope=requested_scope,
    )

    if cache_record and _token_is_fresh(_coerce_int(cache_record.get("expiresOnEpoch")), refresh_skew_seconds):
        return _token_result_from_cache(
            cache_record,
            tenant_id=tenant_id,
            client_id=client_id,
            scope=scope,
            public_client_id=public_client_id,
        )

    if cache_record:
        refresh_token = str(cache_record.get("refreshToken", "")).strip()
        if refresh_token:
            try:
                refreshed = _refresh_device_code_token(
                    tenant_id=tenant_id,
                    public_client_id=public_client_id,
                    requested_scope=requested_scope,
                    refresh_token=refresh_token,
                )
            except EntraInteractionRequired:
                token_cache_path.unlink(missing_ok=True)
                if not allow_user_interaction:
                    raise EntraAuthError(
                        "Cached Entra device-code refresh token is no longer valid. "
                        f"{LOGIN_HINT}"
                    ) from None
            else:
                result, updated_cache = _build_device_code_result(
                    refreshed,
                    tenant_id=tenant_id,
                    client_id=client_id,
                    scope=scope,
                    requested_scope=requested_scope,
                    public_client_id=public_client_id,
                    previous_refresh_token=refresh_token,
                )
                _write_device_token_cache(token_cache_path, updated_cache)
                return result

    if not allow_user_interaction:
        raise EntraAuthError(
            "No reusable Entra device-code token is available for the local broker. "
            f"{LOGIN_HINT}"
        )

    device_code_payload = _request_device_code(
        tenant_id=tenant_id,
        public_client_id=public_client_id,
        requested_scope=requested_scope,
    )
    _print_device_code_prompt(device_code_payload)
    token_payload = _poll_for_device_code_token(
        tenant_id=tenant_id,
        public_client_id=public_client_id,
        device_code=str(device_code_payload["device_code"]),
        interval_seconds=_coerce_int(device_code_payload.get("interval")) or 5,
        expires_in_seconds=_coerce_int(device_code_payload.get("expires_in")) or 900,
    )
    result, updated_cache = _build_device_code_result(
        token_payload,
        tenant_id=tenant_id,
        client_id=client_id,
        scope=scope,
        requested_scope=requested_scope,
        public_client_id=public_client_id,
    )
    _write_device_token_cache(token_cache_path, updated_cache)
    return result


def _acquire_access_token_azure_cli(
    *,
    tenant_id: str,
    client_id: str,
    scope: str,
    login_mode: str,
    allow_user_interaction: bool,
    az_path: str | None,
) -> AccessTokenResult:
    az_cmd = _require_command("az", explicit_path=az_path, install_hint="Install Azure CLI first, then rerun this command.")
    get_token_command = [
        az_cmd,
        "account",
        "get-access-token",
        "--tenant",
        tenant_id,
        "--scope",
        scope,
        "-o",
        "json",
    ]

    payload, stderr = _run_json_command(get_token_command)
    if payload is None:
        if not allow_user_interaction:
            raise EntraAuthError(
                "Unable to refresh Entra access token via Azure CLI. "
                f"{LOGIN_HINT} Azure CLI said: {stderr}".strip()
            )

        _login_with_azure_cli(az_cmd, tenant_id=tenant_id, scope=scope, login_mode=login_mode)
        payload, stderr = _run_json_command(get_token_command)
        if payload is None:
            raise EntraAuthError(f"Azure CLI could not fetch an access token. {stderr}".strip())

    return _normalize_azure_cli_payload(payload, tenant_id=tenant_id, client_id=client_id, scope=scope)


def _normalize_device_code_scope(scope: str) -> str:
    scopes = [part.strip() for part in scope.split() if part.strip()]
    if "offline_access" not in scopes:
        scopes.append("offline_access")
    return " ".join(scopes)


def _request_device_code(*, tenant_id: str, public_client_id: str, requested_scope: str) -> dict[str, Any]:
    url = f"https://login.microsoftonline.com/{tenant_id}/oauth2/v2.0/devicecode"
    status_code, payload = _post_form(url, {"client_id": public_client_id, "scope": requested_scope})
    if status_code != 200:
        raise EntraAuthError(_format_entra_error("Microsoft Entra device-code request failed.", payload))

    required_fields = ["device_code", "user_code", "verification_uri"]
    missing = [name for name in required_fields if not str(payload.get(name, "")).strip()]
    if missing:
        raise EntraAuthError(f"Microsoft Entra device-code response is missing {', '.join(missing)}.")
    return payload


def _poll_for_device_code_token(
    *,
    tenant_id: str,
    public_client_id: str,
    device_code: str,
    interval_seconds: int,
    expires_in_seconds: int,
) -> dict[str, Any]:
    url = f"https://login.microsoftonline.com/{tenant_id}/oauth2/v2.0/token"
    deadline = time.time() + max(expires_in_seconds, 1)
    interval = max(interval_seconds, 1)

    while time.time() < deadline:
        status_code, payload = _post_form(
            url,
            {
                "client_id": public_client_id,
                "grant_type": DEVICE_CODE_GRANT_TYPE,
                "device_code": device_code,
            },
        )
        if status_code == 200:
            return payload

        error_code = str(payload.get("error", "")).strip()
        if error_code == "authorization_pending":
            time.sleep(interval)
            continue
        if error_code == "slow_down":
            interval += 5
            time.sleep(interval)
            continue
        if error_code == "authorization_declined":
            raise EntraAuthError("Microsoft Entra device-code login was declined by the user.")
        if error_code == "expired_token":
            raise EntraAuthError("Microsoft Entra device-code login expired before it was completed.")

        raise EntraAuthError(_format_entra_error("Microsoft Entra device-code login failed.", payload))

    raise EntraAuthError("Microsoft Entra device-code login timed out before authorization completed.")


def _refresh_device_code_token(
    *,
    tenant_id: str,
    public_client_id: str,
    requested_scope: str,
    refresh_token: str,
) -> dict[str, Any]:
    url = f"https://login.microsoftonline.com/{tenant_id}/oauth2/v2.0/token"
    status_code, payload = _post_form(
        url,
        {
            "client_id": public_client_id,
            "grant_type": "refresh_token",
            "refresh_token": refresh_token,
            "scope": requested_scope,
        },
    )
    if status_code == 200:
        return payload

    error_code = str(payload.get("error", "")).strip()
    if error_code in {"invalid_grant", "interaction_required"}:
        raise EntraInteractionRequired("Microsoft Entra requires the user to log in again.")
    raise EntraAuthError(_format_entra_error("Microsoft Entra refresh-token request failed.", payload))


def _build_device_code_result(
    payload: dict[str, Any],
    *,
    tenant_id: str,
    client_id: str,
    scope: str,
    requested_scope: str,
    public_client_id: str,
    previous_refresh_token: str | None = None,
) -> tuple[AccessTokenResult, dict[str, Any]]:
    access_token = str(payload.get("access_token", "")).strip()
    if not access_token:
        raise EntraAuthError("Microsoft Entra did not return an access token.")

    expires_in = _coerce_int(payload.get("expires_in"))
    if expires_in is None:
        raise EntraAuthError("Microsoft Entra did not return expires_in for the access token.")

    expires_on_epoch = int(time.time()) + max(expires_in, 0)
    refresh_token = str(payload.get("refresh_token") or previous_refresh_token or "").strip()
    result = AccessTokenResult(
        access_token=access_token,
        expires_on=_format_epoch(expires_on_epoch),
        expires_on_epoch=expires_on_epoch,
        tenant=tenant_id,
        client_id=client_id,
        scope=scope,
        auth_mode="device-code",
        public_client_id=public_client_id,
    )
    cache_payload: dict[str, Any] = {
        "tenantId": tenant_id,
        "clientId": client_id,
        "publicClientId": public_client_id,
        "scope": requested_scope,
        "accessToken": access_token,
        "expiresOn": result.expires_on,
        "expiresOnEpoch": expires_on_epoch,
        "refreshToken": refresh_token,
    }
    return result, cache_payload


def _token_result_from_cache(
    payload: dict[str, Any],
    *,
    tenant_id: str,
    client_id: str,
    scope: str,
    public_client_id: str,
) -> AccessTokenResult:
    access_token = str(payload.get("accessToken", "")).strip()
    if not access_token:
        raise EntraAuthError("Cached Entra device-code token is missing accessToken.")

    expires_on_epoch = _coerce_int(payload.get("expiresOnEpoch"))
    expires_on = str(payload.get("expiresOn", "")).strip()
    if not expires_on and expires_on_epoch is not None:
        expires_on = _format_epoch(expires_on_epoch)

    return AccessTokenResult(
        access_token=access_token,
        expires_on=expires_on,
        expires_on_epoch=expires_on_epoch,
        tenant=tenant_id,
        client_id=client_id,
        scope=scope,
        auth_mode="device-code",
        public_client_id=public_client_id,
    )


def _load_device_token_cache(
    path: Path,
    *,
    tenant_id: str,
    client_id: str,
    public_client_id: str,
    scope: str,
) -> dict[str, Any] | None:
    if not path.exists():
        return None

    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None

    if not isinstance(payload, dict):
        return None

    expected = {
        "tenantId": tenant_id,
        "clientId": client_id,
        "publicClientId": public_client_id,
        "scope": scope,
    }
    for key, value in expected.items():
        if str(payload.get(key, "")).strip() != value:
            return None
    return payload


def _write_device_token_cache(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if os.name != "nt":
        try:
            os.chmod(path.parent, 0o700)
        except OSError:
            pass

    path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
    if os.name != "nt":
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass


def _token_is_fresh(expires_on_epoch: int | None, refresh_skew_seconds: int) -> bool:
    if expires_on_epoch is None:
        return False
    return expires_on_epoch > int(time.time()) + max(refresh_skew_seconds, 0)


def _post_form(url: str, data: dict[str, str]) -> tuple[int, dict[str, Any]]:
    encoded = urllib.parse.urlencode(data).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=encoded,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = response.read().decode("utf-8")
            return response.getcode(), _parse_json_payload(payload)
    except urllib.error.HTTPError as exc:
        error_body = exc.read().decode("utf-8", errors="replace")
        return exc.code, _parse_json_payload(error_body)
    except urllib.error.URLError as exc:
        raise EntraAuthError(f"Unable to reach Microsoft Entra endpoints. {exc.reason}") from exc


def _parse_json_payload(raw: str) -> dict[str, Any]:
    if not raw.strip():
        return {}
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError:
        return {"error_description": raw.strip()}
    if not isinstance(payload, dict):
        return {"error_description": raw.strip()}
    return payload


def _print_device_code_prompt(payload: dict[str, Any]) -> None:
    verification_uri = str(payload.get("verification_uri", "")).strip()
    user_code = str(payload.get("user_code", "")).strip()
    message = str(payload.get("message", "")).strip()
    verification_uri_complete = str(payload.get("verification_uri_complete", "")).strip()

    if message:
        print(message)
    else:
        print("Microsoft Entra device-code login is required.")
        print(f"Open: {verification_uri}")
        print(f"Code: {user_code}")

    if verification_uri_complete:
        print(f"Direct URL: {verification_uri_complete}")


def _format_entra_error(prefix: str, payload: dict[str, Any]) -> str:
    error_code = str(payload.get("error", "")).strip()
    description = str(payload.get("error_description", "")).strip()
    if error_code and description:
        return f"{prefix} {error_code}: {description}"
    if error_code:
        return f"{prefix} {error_code}"
    if description:
        return f"{prefix} {description}"
    return prefix


def _format_epoch(epoch: int | None) -> str:
    if epoch is None:
        return ""
    return time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime(epoch))


def _coerce_int(value: Any) -> int | None:
    if isinstance(value, int):
        return value
    if isinstance(value, str) and value.strip().isdigit():
        return int(value.strip())
    return None


def _require_command(name: str, *, explicit_path: str | None = None, install_hint: str | None = None) -> str:
    if explicit_path:
        explicit = explicit_path.strip()
        if explicit and shutil.which(explicit):
            return explicit

    path = shutil.which(name)
    if path:
        return path

    message = f"{name} is not installed or not on PATH."
    if install_hint:
        message = f"{message} {install_hint}"
    raise EntraAuthError(message)


def _run_json_command(command: list[str]) -> tuple[dict[str, Any] | None, str]:
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    stderr = (result.stderr or "").strip()
    if result.returncode != 0:
        return None, stderr or "command failed"

    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise EntraAuthError(f"Command returned invalid JSON: {' '.join(command)}") from exc
    if not isinstance(payload, dict):
        raise EntraAuthError(f"Command returned unexpected JSON payload: {' '.join(command)}")
    return payload, stderr


def _login_with_azure_cli(az_path: str, *, tenant_id: str, scope: str, login_mode: str) -> None:
    command = [az_path, "login", "--tenant", tenant_id, "--scope", scope]
    if login_mode == "device-code":
        command.append("--use-device-code")

    completed = subprocess.run(command, check=False)
    if completed.returncode != 0:
        raise EntraAuthError("Azure CLI login failed.")


def _normalize_azure_cli_payload(payload: dict[str, Any], *, tenant_id: str, client_id: str, scope: str) -> AccessTokenResult:
    access_token = str(payload.get("accessToken", "")).strip()
    if not access_token:
        raise EntraAuthError("Azure CLI did not return an access token.")

    expires_on_epoch = _coerce_int(payload.get("expires_on"))
    expires_on = str(payload.get("expiresOn", "")).strip()
    if not expires_on and expires_on_epoch is not None:
        expires_on = _format_epoch(expires_on_epoch)

    tenant = str(payload.get("tenant", "")).strip() or tenant_id
    return AccessTokenResult(
        access_token=access_token,
        expires_on=expires_on,
        expires_on_epoch=expires_on_epoch,
        tenant=tenant,
        client_id=client_id,
        scope=scope,
        auth_mode="azure-cli",
    )

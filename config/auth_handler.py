from __future__ import annotations

import asyncio
import json
import logging
import os
from functools import lru_cache
from typing import Any, Dict, List, Optional
from urllib.parse import parse_qsl, urlsplit

import httpx
import jwt
from fastapi import HTTPException, Request, status
from jwt import InvalidTokenError, PyJWKClient

from litellm.proxy._types import LitellmUserRoles, UserAPIKeyAuth
from litellm.proxy.auth.auth_checks import get_key_object
from litellm.proxy.common_utils.timezone_utils import get_budget_reset_time
from litellm.proxy.utils import hash_token

DEFAULT_ALLOWED_MODELS = [
    "vertex-gemini-2.5-flash",
    "vertex-gemini-2.5-flash-lite",
    "vertex-gemini-2.5-pro",
    "vertex-gemini-3-pro-preview",
    "vertex-claude-sonnet-4-6",
]
DEFAULT_PROXY_ADMIN_USER_ID = "litellm-proxy-admin"
DEFAULT_ENTRA_SHARED_TEAM_ALIAS = "entra-allowed-users"
DEFAULT_INTERNAL_MANAGEMENT_BASE_URL = "http://127.0.0.1:4000"
TRACE_LOG_PREFIX = "vertex-trace"
SENSITIVE_HEADER_NAMES = {
    "authorization",
    "proxy-authorization",
    "cookie",
    "set-cookie",
    "x-goog-api-key",
    "api-key",
}
_TEAM_SYNC_LOCK = asyncio.Lock()
_ENSURED_TEAM_IDS: set[str] = set()
_ENSURED_TEAM_MEMBERS: set[tuple[str, str]] = set()


def _is_truthy(value: Optional[str]) -> bool:
    return (value or "").strip().lower() in {"1", "true", "yes", "on"}


def _should_trace_vertex_requests() -> bool:
    return _is_truthy(os.getenv("VERTEX_TRACE_REQUESTS"))


def _should_include_trace_secrets() -> bool:
    return _is_truthy(os.getenv("VERTEX_TRACE_INCLUDE_SECRETS"))


def _sanitize_header_value(name: str, value: Any) -> Any:
    if _should_include_trace_secrets():
        return value
    if name.lower() in SENSITIVE_HEADER_NAMES and value is not None:
        return "<redacted>"
    return value


def _sanitize_headers(headers: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    sanitized: Dict[str, Any] = {}
    for key, value in (headers or {}).items():
        sanitized[str(key)] = _sanitize_header_value(str(key), value)
    return sanitized


def _normalize_params(url: str, params: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    normalized = {
        key: value
        for key, value in parse_qsl(urlsplit(url).query, keep_blank_values=True)
    }
    if params:
        for key, value in params.items():
            normalized[str(key)] = value
    return normalized


def _emit_vertex_trace(method: str, url: Any, params: Optional[Dict[str, Any]], headers: Optional[Dict[str, Any]]) -> None:
    if not _should_trace_vertex_requests():
        return

    url_text = str(url)
    if "aiplatform.googleapis.com" not in url_text:
        return

    payload = {
        "event": TRACE_LOG_PREFIX,
        "method": method,
        "url": url_text,
        "params": _normalize_params(url_text, params),
        "headers": _sanitize_headers(headers),
    }
    print(json.dumps(payload, ensure_ascii=False), flush=True)


def _pick_positional_arg(args: Any, index: int, default: Any = None) -> Any:
    if len(args) > index:
        return args[index]
    return default


def _install_vertex_request_trace_patch() -> None:
    if not _should_trace_vertex_requests():
        return

    try:
        from litellm.llms.custom_httpx.http_handler import AsyncHTTPHandler, HTTPHandler
    except Exception as exc:
        logging.exception("Unable to install Vertex request trace patch: %s", exc)
        return

    if getattr(AsyncHTTPHandler.post, "_vertex_trace_patched", False):
        return

    original_async_post = AsyncHTTPHandler.post
    original_sync_post = HTTPHandler.post

    async def traced_async_post(self, url: str, *args: Any, **kwargs: Any):
        params = kwargs.get("params", _pick_positional_arg(args, 2))
        headers = kwargs.get("headers", _pick_positional_arg(args, 3))
        _emit_vertex_trace("POST", url, params, headers)
        return await original_async_post(self, url, *args, **kwargs)

    def traced_sync_post(self, url: str, *args: Any, **kwargs: Any):
        params = kwargs.get("params", _pick_positional_arg(args, 2))
        headers = kwargs.get("headers", _pick_positional_arg(args, 3))
        _emit_vertex_trace("POST", url, params, headers)
        return original_sync_post(self, url, *args, **kwargs)

    setattr(traced_async_post, "_vertex_trace_patched", True)
    setattr(traced_sync_post, "_vertex_trace_patched", True)
    AsyncHTTPHandler.post = traced_async_post
    HTTPHandler.post = traced_sync_post


_install_vertex_request_trace_patch()


def _install_admin_ui_session_key_patch() -> None:
    try:
        from litellm.constants import LITELLM_PROXY_ADMIN_NAME
        from litellm.proxy.auth import login_utils
    except Exception as exc:
        logging.exception("Unable to install admin UI session key patch: %s", exc)
        return

    if getattr(login_utils.generate_key_helper_fn, "_open_litevertex_ui_admin_patch", False):
        return

    original_generate_key_helper_fn = login_utils.generate_key_helper_fn

    async def patched_generate_key_helper_fn(*args: Any, **kwargs: Any):
        user_role = kwargs.get("user_role")
        user_id = kwargs.get("user_id")
        team_id = kwargs.get("team_id")

        is_proxy_admin_role = False
        if isinstance(user_role, LitellmUserRoles):
            is_proxy_admin_role = user_role == LitellmUserRoles.PROXY_ADMIN
        elif isinstance(user_role, str):
            is_proxy_admin_role = user_role.strip() == LitellmUserRoles.PROXY_ADMIN.value

        # LiteLLM's default UI login creates a short-lived admin key on the
        # special litellm-dashboard team. That key cannot access /user/list and
        # related admin APIs. For proxy-admin UI logins, generate a regular
        # short-lived admin key instead.
        if (
            team_id == "litellm-dashboard"
            and is_proxy_admin_role
            and user_id == LITELLM_PROXY_ADMIN_NAME
        ):
            kwargs = dict(kwargs)
            kwargs.pop("team_id", None)

        return await original_generate_key_helper_fn(*args, **kwargs)

    setattr(patched_generate_key_helper_fn, "_open_litevertex_ui_admin_patch", True)
    login_utils.generate_key_helper_fn = patched_generate_key_helper_fn


_install_admin_ui_session_key_patch()


def _normalize_token(api_key: str) -> str:
    token = (api_key or "").strip()
    for prefix in ("Bearer ", "bearer ", "Basic ", "basic "):
        if token.startswith(prefix):
            return token[len(prefix) :].strip()
    return token


def _split_csv(value: Optional[str]) -> List[str]:
    if value is None:
        return []
    normalized = value.replace(";", ",").replace("\n", ",")
    return [item.strip() for item in normalized.split(",") if item.strip()]


def _first_env(*names: str) -> Optional[str]:
    for name in names:
        value = os.getenv(name)
        if value is not None and value.strip():
            return value.strip()
    return None


def _get_allowed_models() -> List[str]:
    configured = _split_csv(os.getenv("ENTRA_ALLOWED_MODELS"))
    if configured:
        return configured
    return list(DEFAULT_ALLOWED_MODELS)


def _get_user_budget() -> float:
    raw_value = os.getenv("ENTRA_USER_MAX_BUDGET", "50").strip()
    return float(raw_value)


def _get_user_budget_duration() -> str:
    return os.getenv("ENTRA_USER_BUDGET_DURATION", "7d").strip() or "7d"


def _get_shared_team_id(matched_group_ids: List[str]) -> Optional[str]:
    configured = _first_env("ENTRA_SHARED_TEAM_ID")
    if configured:
        return configured
    if len(matched_group_ids) == 1:
        return matched_group_ids[0]
    allowed_group_ids = _require_entra_settings()["allowed_group_ids"]
    if len(allowed_group_ids) == 1:
        return allowed_group_ids[0]
    return None


def _get_shared_team_alias(team_id: str) -> str:
    configured = os.getenv("ENTRA_SHARED_TEAM_ALIAS", "").strip()
    if configured:
        return configured
    return DEFAULT_ENTRA_SHARED_TEAM_ALIAS if team_id else DEFAULT_ENTRA_SHARED_TEAM_ALIAS


def _get_shared_team_budget() -> float:
    raw_value = os.getenv("ENTRA_SHARED_TEAM_MAX_BUDGET", "").strip()
    if raw_value:
        return float(raw_value)
    return _get_user_budget()


def _get_shared_team_budget_duration() -> str:
    return os.getenv("ENTRA_SHARED_TEAM_BUDGET_DURATION", "").strip() or _get_user_budget_duration()


def _get_shared_team_member_budget() -> float:
    raw_value = os.getenv("ENTRA_SHARED_TEAM_MEMBER_MAX_BUDGET", "").strip()
    if raw_value:
        return float(raw_value)
    return _get_user_budget()


def _get_internal_management_base_url() -> str:
    return os.getenv("LITELLM_INTERNAL_BASE_URL", "").strip().rstrip("/") or DEFAULT_INTERNAL_MANAGEMENT_BASE_URL


def _is_jwt(token: str) -> bool:
    return token.count(".") == 2


@lru_cache(maxsize=8)
def _get_jwks_client(jwks_uri: str) -> PyJWKClient:
    return PyJWKClient(jwks_uri)


def _get_entra_settings() -> Dict[str, Any]:
    tenant_id = _first_env("ENTRA_TENANT_ID")
    client_id = _first_env("ENTRA_CLIENT_ID")
    allowed_group_ids = _split_csv(
        _first_env("ENTRA_ALLOWED_GROUP_IDS", "ENTRA_ALLOWED_GROUP_ID")
    )
    allowed_audiences = _split_csv(_first_env("ENTRA_ALLOWED_AUDIENCES"))
    if not allowed_audiences and client_id:
        allowed_audiences = [client_id, f"api://{client_id}"]
    issuer = _first_env("ENTRA_ISSUER")
    if issuer is None and tenant_id is not None:
        issuer = f"https://login.microsoftonline.com/{tenant_id}/v2.0"
    jwks_uri = _first_env("ENTRA_JWKS_URI")
    if jwks_uri is None and tenant_id is not None:
        jwks_uri = f"https://login.microsoftonline.com/{tenant_id}/discovery/v2.0/keys"

    return {
        "tenant_id": tenant_id,
        "client_id": client_id,
        "allowed_group_ids": allowed_group_ids,
        "allowed_audiences": allowed_audiences,
        "issuer": issuer,
        "jwks_uri": jwks_uri,
    }


def _require_entra_settings() -> Dict[str, Any]:
    settings = _get_entra_settings()
    missing = []
    if not settings["tenant_id"]:
        missing.append("ENTRA_TENANT_ID")
    if not settings["allowed_group_ids"]:
        missing.append("ENTRA_ALLOWED_GROUP_IDS")
    if not settings["allowed_audiences"]:
        missing.append("ENTRA_CLIENT_ID or ENTRA_ALLOWED_AUDIENCES")
    if not settings["issuer"]:
        missing.append("ENTRA_ISSUER")
    if not settings["jwks_uri"]:
        missing.append("ENTRA_JWKS_URI")

    if missing:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=(
                "Entra JWT auth is not configured on this LiteLLM deployment. "
                f"Missing: {', '.join(missing)}"
            ),
        )

    return settings


def _extract_groups(claims: Dict[str, Any]) -> List[str]:
    groups = claims.get("groups")
    if isinstance(groups, str) and groups.strip():
        return [groups.strip()]
    if isinstance(groups, list):
        return [str(group).strip() for group in groups if str(group).strip()]

    claim_names = claims.get("_claim_names")
    if claims.get("hasgroups") or (
        isinstance(claim_names, dict) and "groups" in claim_names
    ):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail=(
                "This Entra token does not include the groups claim because of groups "
                "overage. Configure Entra to emit only assigned groups or use app roles."
            ),
        )

    raise HTTPException(
        status_code=status.HTTP_403_FORBIDDEN,
        detail="The Entra token does not contain a groups claim.",
    )


def _authorize_groups(claims: Dict[str, Any], allowed_group_ids: List[str]) -> List[str]:
    group_ids = _extract_groups(claims)
    matched = sorted(set(group_ids).intersection(allowed_group_ids))
    if not matched:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="The signed-in user is not a member of an allowed Entra group.",
        )
    return matched


def _decode_entra_token(token: str) -> Dict[str, Any]:
    settings = _require_entra_settings()
    try:
        signing_key = _get_jwks_client(settings["jwks_uri"]).get_signing_key_from_jwt(
            token
        )
        return jwt.decode(
            token,
            signing_key.key,
            algorithms=["RS256"],
            audience=settings["allowed_audiences"],
            issuer=settings["issuer"],
            options={"require": ["exp", "iss", "aud"]},
        )
    except InvalidTokenError as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=f"Invalid Entra access token: {exc}",
        ) from exc


def _pick_user_email(claims: Dict[str, Any]) -> Optional[str]:
    for key in ("preferred_username", "upn", "email", "unique_name"):
        value = claims.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return None


def _build_jwt_claims_metadata(claims: Dict[str, Any], matched_group_ids: List[str]) -> Dict[str, Any]:
    return {
        "iss": claims.get("iss"),
        "aud": claims.get("aud"),
        "tid": claims.get("tid"),
        "oid": claims.get("oid"),
        "sub": claims.get("sub"),
        "preferred_username": claims.get("preferred_username"),
        "groups": matched_group_ids,
    }


async def _call_management_api(
    method: str,
    path: str,
    *,
    params: Optional[Dict[str, Any]] = None,
    json_payload: Optional[Dict[str, Any]] = None,
    expected_statuses: Optional[set[int]] = None,
) -> Optional[Any]:
    master_key = os.getenv("LITELLM_MASTER_KEY", "").strip()
    if not master_key:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="LiteLLM team sync requires LITELLM_MASTER_KEY to be configured.",
        )

    base_url = _get_internal_management_base_url()
    url = f"{base_url}{path}"
    async with httpx.AsyncClient(timeout=15.0) as client:
        response = await client.request(
            method,
            url,
            headers={"Authorization": f"Bearer {master_key}"},
            params=params,
            json=json_payload,
        )

    allowed_statuses = expected_statuses or {200}
    if response.status_code in allowed_statuses:
        if response.status_code == 404:
            return None
        if response.content:
            return response.json()
        return None

    detail = response.text
    try:
        payload = response.json()
        if isinstance(payload, dict):
            detail = payload.get("detail") or payload.get("error", {}).get("message") or response.text
    except Exception:
        pass

    raise HTTPException(
        status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
        detail=f"LiteLLM management API call failed for {path}: {detail}",
    )


def _build_shared_team_metadata(shared_team_id: str, matched_group_ids: List[str]) -> Dict[str, Any]:
    return {
        "auth_provider": "entra",
        "team_mode": "shared",
        "shared_team_id": shared_team_id,
        "allowed_group_ids": _require_entra_settings()["allowed_group_ids"],
        "matched_group_ids": matched_group_ids,
    }


async def _ensure_shared_team_membership(
    *,
    user_id: str,
    user_email: Optional[str],
    matched_group_ids: List[str],
) -> Optional[Dict[str, Any]]:
    shared_team_id = _get_shared_team_id(matched_group_ids)
    if not shared_team_id:
        return None

    shared_team_alias = _get_shared_team_alias(shared_team_id)
    models = _get_allowed_models()
    team_budget = _get_shared_team_budget()
    team_budget_duration = _get_shared_team_budget_duration()
    team_member_budget = _get_shared_team_member_budget()

    async with _TEAM_SYNC_LOCK:
        if shared_team_id not in _ENSURED_TEAM_IDS:
            team_info_response = await _call_management_api(
                "GET",
                "/team/info",
                params={"team_id": shared_team_id},
                expected_statuses={200, 404},
            )
            team_info = None
            if isinstance(team_info_response, dict):
                nested_team_info = team_info_response.get("team_info")
                if isinstance(nested_team_info, dict):
                    team_info = nested_team_info
            team_payload = {
                "team_id": shared_team_id,
                "team_alias": shared_team_alias,
                "models": models,
                "max_budget": team_budget,
                "budget_duration": team_budget_duration,
                "metadata": _build_shared_team_metadata(
                    shared_team_id=shared_team_id,
                    matched_group_ids=matched_group_ids,
                ),
            }
            if team_info is None:
                await _call_management_api(
                    "POST",
                    "/team/new",
                    json_payload=team_payload,
                    expected_statuses={200},
                )
            else:
                needs_update = (
                    team_info.get("team_alias") != shared_team_alias
                    or sorted(team_info.get("models") or []) != sorted(models)
                    or team_info.get("max_budget") != team_budget
                    or team_info.get("budget_duration") != team_budget_duration
                )
                if needs_update:
                    await _call_management_api(
                        "POST",
                        "/team/update",
                        json_payload=team_payload,
                        expected_statuses={200},
                    )
            _ENSURED_TEAM_IDS.add(shared_team_id)

        membership_key = (shared_team_id, user_id)
        if membership_key not in _ENSURED_TEAM_MEMBERS:
            team_info_response = await _call_management_api(
                "GET",
                "/team/info",
                params={"team_id": shared_team_id},
                expected_statuses={200},
            )
            team_info = {}
            if isinstance(team_info_response, dict):
                nested_team_info = team_info_response.get("team_info")
                if isinstance(nested_team_info, dict):
                    team_info = nested_team_info
            members_with_roles = team_info.get("members_with_roles") or []
            existing_member_ids = {
                member.get("user_id")
                for member in members_with_roles
                if isinstance(member, dict) and member.get("user_id")
            }
            if user_id not in existing_member_ids:
                await _call_management_api(
                    "POST",
                    "/team/member_add",
                    json_payload={
                        "team_id": shared_team_id,
                        "max_budget_in_team": team_member_budget,
                        "member": {
                            "role": "user",
                            "user_id": user_id,
                        },
                    },
                    expected_statuses={200},
                )
            _ENSURED_TEAM_MEMBERS.add(membership_key)

    return {
        "team_id": shared_team_id,
        "team_alias": shared_team_alias,
        "team_max_budget": team_budget,
        "team_models": models,
        "team_member_budget": team_member_budget,
        "team_budget_duration": team_budget_duration,
        "user_email": user_email,
    }


async def _load_existing_key(api_key: str) -> UserAPIKeyAuth:
    from litellm.proxy.proxy_server import prisma_client, proxy_logging_obj, user_api_key_cache

    if prisma_client is None:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="LiteLLM database is not connected.",
        )

    key_object = await get_key_object(
        hashed_token=hash_token(api_key),
        prisma_client=prisma_client,
        user_api_key_cache=user_api_key_cache,
        proxy_logging_obj=proxy_logging_obj,
    )

    owner_user_id = getattr(key_object, "user_id", None)
    if isinstance(owner_user_id, str) and owner_user_id.strip():
        owner_user = await prisma_client.db.litellm_usertable.find_unique(
            where={"user_id": owner_user_id.strip()}
        )
        if owner_user is not None:
            owner_role = getattr(owner_user, "user_role", None)
            if isinstance(owner_role, str) and owner_role.strip():
                try:
                    key_object.user_role = LitellmUserRoles(owner_role.strip())
                except ValueError:
                    pass

            owner_email = getattr(owner_user, "user_email", None)
            if isinstance(owner_email, str) and owner_email.strip():
                key_object.user_email = owner_email.strip()

    key_object.api_key = api_key
    return key_object


async def _upsert_internal_user(
    user_id: str,
    user_email: Optional[str],
    matched_group_ids: List[str],
) -> None:
    from litellm.proxy.proxy_server import prisma_client, user_api_key_cache

    if prisma_client is None:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="LiteLLM database is not connected.",
        )

    max_budget = _get_user_budget()
    budget_duration = _get_user_budget_duration()
    models = _get_allowed_models()
    metadata = {
        "auth_provider": "entra",
        "entra_oid": user_id,
        "matched_group_ids": matched_group_ids,
    }
    metadata_json = json.dumps(metadata)

    create_data: Dict[str, Any] = {
        "user_id": user_id,
        "sso_user_id": user_id,
        "user_role": LitellmUserRoles.INTERNAL_USER.value,
        "models": models,
        "metadata": metadata_json,
        "max_budget": max_budget,
        "budget_duration": budget_duration,
        "budget_reset_at": get_budget_reset_time(budget_duration),
    }
    update_data: Dict[str, Any] = {
        "sso_user_id": user_id,
        "user_role": LitellmUserRoles.INTERNAL_USER.value,
        "models": models,
        "metadata": metadata_json,
        "max_budget": max_budget,
        "budget_duration": budget_duration,
    }

    if user_email is not None:
        create_data["user_email"] = user_email
        update_data["user_email"] = user_email

    user_row = await prisma_client.db.litellm_usertable.upsert(
        where={"user_id": user_id},
        data={
            "create": create_data,
            "update": update_data,
        },
    )

    if getattr(user_row, "budget_reset_at", None) is None:
        await prisma_client.db.litellm_usertable.update(
            where={"user_id": user_id},
            data={"budget_reset_at": get_budget_reset_time(budget_duration)},
        )

    try:
        user_api_key_cache.delete_cache(key=user_id)
    except Exception:
        pass


async def user_api_key_auth(request: Request, api_key: str) -> UserAPIKeyAuth:
    token = _normalize_token(api_key)
    if not token:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Missing API key or bearer token.",
        )

    master_key = os.getenv("LITELLM_MASTER_KEY")
    if master_key and token == master_key:
        return UserAPIKeyAuth(
            api_key=token,
            token=hash_token(token),
            user_id=DEFAULT_PROXY_ADMIN_USER_ID,
            user_role=LitellmUserRoles.PROXY_ADMIN,
        )

    if token.startswith("sk-"):
        return await _load_existing_key(api_key=token)

    if not _is_jwt(token):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Unsupported credential. Use a LiteLLM key or an Entra access token.",
        )

    claims = _decode_entra_token(token)
    matched_group_ids = _authorize_groups(
        claims=claims,
        allowed_group_ids=_require_entra_settings()["allowed_group_ids"],
    )
    user_id = claims.get("oid")
    if not isinstance(user_id, str) or not user_id.strip():
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="The Entra token is missing the oid claim.",
        )

    user_id = user_id.strip()
    user_email = _pick_user_email(claims)
    await _upsert_internal_user(
        user_id=user_id,
        user_email=user_email,
        matched_group_ids=matched_group_ids,
    )
    team_context = await _ensure_shared_team_membership(
        user_id=user_id,
        user_email=user_email,
        matched_group_ids=matched_group_ids,
    )

    synthetic_token = f"entra::{user_id}"
    metadata = {
        "auth_provider": "entra",
        "matched_group_ids": matched_group_ids,
    }
    if team_context is not None:
        metadata["shared_team_id"] = team_context["team_id"]
    return UserAPIKeyAuth(
        api_key=synthetic_token,
        token=synthetic_token,
        user_id=user_id,
        user_role=LitellmUserRoles.INTERNAL_USER,
        user_email=user_email,
        models=_get_allowed_models(),
        metadata=metadata,
        team_id=team_context["team_id"] if team_context is not None else None,
        team_alias=team_context["team_alias"] if team_context is not None else None,
        team_max_budget=team_context["team_max_budget"] if team_context is not None else None,
        team_models=team_context["team_models"] if team_context is not None else None,
        jwt_claims=_build_jwt_claims_metadata(
            claims=claims,
            matched_group_ids=matched_group_ids,
        ),
    )

from __future__ import annotations

import json
import logging
import os
from functools import lru_cache
from typing import Any, Dict, List, Optional
from urllib.parse import parse_qsl, urlsplit

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
TRACE_LOG_PREFIX = "vertex-trace"
SENSITIVE_HEADER_NAMES = {
    "authorization",
    "proxy-authorization",
    "cookie",
    "set-cookie",
    "x-goog-api-key",
    "api-key",
}


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

    synthetic_token = f"entra::{user_id}"
    return UserAPIKeyAuth(
        api_key=synthetic_token,
        token=synthetic_token,
        user_id=user_id,
        user_role=LitellmUserRoles.INTERNAL_USER,
        user_email=user_email,
        models=_get_allowed_models(),
        metadata={
            "auth_provider": "entra",
            "matched_group_ids": matched_group_ids,
        },
        jwt_claims=_build_jwt_claims_metadata(
            claims=claims,
            matched_group_ids=matched_group_ids,
        ),
    )

from __future__ import annotations

import asyncio
import os
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

import httpx
import uvicorn
from fastapi import FastAPI, HTTPException, Request, Response, status
from fastapi.responses import JSONResponse, StreamingResponse
from starlette.background import BackgroundTask

from entra_auth import EntraAuthError, acquire_access_token


HOP_BY_HOP_HEADERS = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
}


def _require_env(name: str) -> str:
    value = os.getenv(name, "").strip()
    if not value:
        raise RuntimeError(f"Missing required environment variable: {name}")
    return value


def _normalize_token(value: str) -> str:
    token = (value or "").strip()
    for prefix in ("Bearer ", "bearer ", "Basic ", "basic "):
        if token.startswith(prefix):
            return token[len(prefix) :].strip()
    return token


def _filter_request_headers(headers: Iterable[tuple[str, str]]) -> dict[str, str]:
    filtered: dict[str, str] = {}
    for key, value in headers:
        normalized = key.lower()
        if normalized in HOP_BY_HOP_HEADERS:
            continue
        if normalized in {"host", "content-length", "authorization"}:
            continue
        filtered[key] = value
    return filtered


def _filter_response_headers(headers: httpx.Headers) -> dict[str, str]:
    filtered: dict[str, str] = {}
    for key, value in headers.items():
        normalized = key.lower()
        if normalized in HOP_BY_HOP_HEADERS:
            continue
        if normalized == "content-length":
            continue
        filtered[key] = value
    return filtered


async def _send_upstream_with_retry(
    request: Request,
    *,
    upstream_url: str,
    body: bytes,
    headers: dict[str, str],
) -> httpx.Response:
    last_error: httpx.HTTPError | None = None
    for attempt in range(2):
        upstream_request = http_client.build_request(
            request.method,
            upstream_url,
            content=body,
            headers=headers,
            params=list(request.query_params.multi_items()),
        )
        try:
            return await http_client.send(upstream_request, stream=True)
        except httpx.TransportError as exc:
            last_error = exc
            if attempt == 0:
                continue
            break
        except httpx.HTTPError as exc:
            last_error = exc
            break

    detail = "Unable to reach the upstream LiteLLM service."
    if last_error is not None:
        detail = f"{detail} {last_error}"
    raise HTTPException(
        status_code=status.HTTP_502_BAD_GATEWAY,
        detail=detail,
    )


@dataclass
class TokenBundle:
    access_token: str
    expires_at_epoch: int


class EntraTokenCache:
    def __init__(
        self,
        tenant_id: str,
        client_id: str,
        scope: str,
        refresh_skew_seconds: int,
        *,
        auth_mode: str,
        public_client_id: str,
        login_mode: str,
        token_cache_path: str,
        az_path: str,
    ) -> None:
        self.tenant_id = tenant_id
        self.client_id = client_id
        self.scope = scope
        self.refresh_skew_seconds = refresh_skew_seconds
        self.auth_mode = auth_mode
        self.public_client_id = public_client_id
        self.login_mode = login_mode
        self.token_cache_path = token_cache_path
        self.az_path = az_path
        self._lock = asyncio.Lock()
        self._bundle: TokenBundle | None = None

    def _token_is_fresh(self) -> bool:
        if self._bundle is None:
            return False
        now = int(time.time())
        return self._bundle.expires_at_epoch > now + self.refresh_skew_seconds

    async def get_access_token(self) -> str:
        if self._token_is_fresh():
            return self._bundle.access_token

        async with self._lock:
            if self._token_is_fresh():
                return self._bundle.access_token

            self._bundle = await asyncio.to_thread(self._fetch_token)
            return self._bundle.access_token

    def _fetch_token(self) -> TokenBundle:
        try:
            payload = acquire_access_token(
                tenant_id=self.tenant_id,
                client_id=self.client_id,
                scope=self.scope,
                auth_mode=self.auth_mode,
                login_mode=self.login_mode,
                public_client_id=self.public_client_id,
                token_cache_path=None if not self.token_cache_path else Path(self.token_cache_path),
                refresh_skew_seconds=self.refresh_skew_seconds,
                allow_user_interaction=False,
                az_path=self.az_path,
            )
        except EntraAuthError as exc:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail=str(exc),
            ) from exc

        access_token = payload.get("accessToken")
        expires_at_epoch = payload.get("expiresOnEpoch")
        if not isinstance(access_token, str) or not access_token.strip():
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="Entra auth provider did not return an access token.",
            )
        if not isinstance(expires_at_epoch, int):
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="Entra auth provider did not return expiresOnEpoch for the access token.",
            )

        return TokenBundle(access_token=access_token.strip(), expires_at_epoch=expires_at_epoch)


UPSTREAM_BASE_URL = _require_env("BROKER_UPSTREAM_BASE_URL").rstrip("/")
TENANT_ID = _require_env("ENTRA_TENANT_ID")
CLIENT_ID = _require_env("ENTRA_CLIENT_ID")
SCOPE = os.getenv("ENTRA_SCOPE", "").strip() or f"api://{CLIENT_ID}/access_as_user"
LOCAL_API_KEY = os.getenv("ENTRA_BROKER_API_KEY", "").strip()
REFRESH_SKEW_SECONDS = int(os.getenv("BROKER_REFRESH_SKEW_SECONDS", "300"))
AUTH_MODE = os.getenv("ENTRA_AUTH_MODE", "auto").strip() or "auto"
PUBLIC_CLIENT_ID = os.getenv("ENTRA_PUBLIC_CLIENT_ID", "").strip()
AZURE_CLI_LOGIN_MODE = os.getenv("ENTRA_AZURE_CLI_LOGIN_MODE", "device-code").strip() or "device-code"
TOKEN_CACHE_PATH = os.getenv("ENTRA_TOKEN_CACHE_PATH", "").strip()
AZ_PATH = os.getenv("AZ_PATH", "").strip() or "az"

app = FastAPI(title="Entra LiteLLM Broker")
token_cache = EntraTokenCache(
    tenant_id=TENANT_ID,
    client_id=CLIENT_ID,
    scope=SCOPE,
    refresh_skew_seconds=REFRESH_SKEW_SECONDS,
    auth_mode=AUTH_MODE,
    public_client_id=PUBLIC_CLIENT_ID,
    login_mode=AZURE_CLI_LOGIN_MODE,
    token_cache_path=TOKEN_CACHE_PATH,
    az_path=AZ_PATH,
)
http_client = httpx.AsyncClient(
    timeout=None,
    follow_redirects=False,
    limits=httpx.Limits(max_keepalive_connections=0, max_connections=100),
)


@app.on_event("shutdown")
async def _shutdown() -> None:
    await http_client.aclose()


def _check_local_api_key(request: Request) -> None:
    if not LOCAL_API_KEY:
        return

    provided = _normalize_token(request.headers.get("authorization", ""))
    if provided != LOCAL_API_KEY:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid local broker API key.",
        )


@app.get("/healthz")
async def healthz() -> JSONResponse:
    return JSONResponse({"status": "ok"})


@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"])
async def proxy_request(path: str, request: Request) -> Response:
    _check_local_api_key(request)

    access_token = await token_cache.get_access_token()
    body = await request.body()
    headers = _filter_request_headers(request.headers.items())
    headers["Authorization"] = f"Bearer {access_token}"

    upstream_url = f"{UPSTREAM_BASE_URL}/{path.lstrip('/')}"
    upstream_response = await _send_upstream_with_retry(
        request,
        upstream_url=upstream_url,
        body=body,
        headers=headers,
    )
    response_headers = _filter_response_headers(upstream_response.headers)
    content_type = upstream_response.headers.get("content-type", "")

    if content_type.startswith("text/event-stream"):
        return StreamingResponse(
            upstream_response.aiter_raw(),
            status_code=upstream_response.status_code,
            headers=response_headers,
            background=BackgroundTask(upstream_response.aclose),
        )

    payload = await upstream_response.aread()
    await upstream_response.aclose()
    return Response(
        content=payload,
        status_code=upstream_response.status_code,
        headers=response_headers,
    )


if __name__ == "__main__":
    uvicorn.run(
        app,
        host=os.getenv("BROKER_HOST", "127.0.0.1"),
        port=int(os.getenv("BROKER_PORT", "8787")),
        reload=False,
        log_level=os.getenv("BROKER_LOG_LEVEL", "info").lower(),
    )

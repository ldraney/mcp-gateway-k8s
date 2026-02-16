"""Main entrypoint — configures the notion-mcp FastMCP instance with OAuth
and serves it over Streamable HTTP.
"""

from __future__ import annotations

import logging
import os
import sys

from dotenv import load_dotenv

load_dotenv()

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

NOTION_OAUTH_CLIENT_ID = os.environ["NOTION_OAUTH_CLIENT_ID"]
NOTION_OAUTH_CLIENT_SECRET = os.environ["NOTION_OAUTH_CLIENT_SECRET"]
SESSION_SECRET = os.environ["SESSION_SECRET"]
BASE_URL = os.environ["BASE_URL"]
HOST = os.environ.get("HOST", "127.0.0.1")
PORT = int(os.environ.get("PORT", "8000"))

logging.basicConfig(level=logging.INFO, stream=sys.stderr)
logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# 1. Apply the per-request client monkey-patch BEFORE importing mcp
#    (notion_mcp registers tools at import time)
# ---------------------------------------------------------------------------

from client_patch import apply_patch  # noqa: E402

apply_patch()

# ---------------------------------------------------------------------------
# 2. Import the already-constructed FastMCP instance from notion-mcp
# ---------------------------------------------------------------------------

from notion_mcp.server import mcp  # noqa: E402

# ---------------------------------------------------------------------------
# 3. Set up auth provider and storage
# ---------------------------------------------------------------------------

from auth.provider import NotionOAuthProvider  # noqa: E402
from auth.storage import TokenStore  # noqa: E402

store = TokenStore(secret=SESSION_SECRET)
provider = NotionOAuthProvider(
    store=store,
    notion_client_id=NOTION_OAUTH_CLIENT_ID,
    notion_client_secret=NOTION_OAUTH_CLIENT_SECRET,
    base_url=BASE_URL,
)

# ---------------------------------------------------------------------------
# 4. Configure auth on the existing mcp instance
#    (bypassing constructor validation since instance is already built)
# ---------------------------------------------------------------------------

from mcp.server.auth.provider import ProviderTokenVerifier  # noqa: E402
from mcp.server.auth.settings import (  # noqa: E402
    AuthSettings,
    ClientRegistrationOptions,
    RevocationOptions,
)

mcp.settings.auth = AuthSettings(
    issuer_url=BASE_URL,
    resource_server_url=f"{BASE_URL}/mcp",
    client_registration_options=ClientRegistrationOptions(enabled=True),
    revocation_options=RevocationOptions(enabled=True),
)
mcp._auth_server_provider = provider
mcp._token_verifier = ProviderTokenVerifier(provider)

# ---------------------------------------------------------------------------
# 5. Configure HTTP transport settings
# ---------------------------------------------------------------------------

mcp.settings.host = HOST
mcp.settings.port = PORT
mcp.settings.stateless_http = True

# Allow the public hostname (and any additional internal hostnames) through
# transport security. ADDITIONAL_ALLOWED_HOSTS is comma-separated, used for
# K8s internal service names (e.g. "notion-mcp-remote,notion-mcp-remote:8000")
from urllib.parse import urlparse  # noqa: E402

_allowed: list[str] = []
_parsed = urlparse(BASE_URL)
if _parsed.hostname:
    _allowed.append(_parsed.hostname)
    if _parsed.port:
        _allowed.append(f"{_parsed.hostname}:{_parsed.port}")
_extra = os.environ.get("ADDITIONAL_ALLOWED_HOSTS", "")
if _extra:
    _allowed.extend(h.strip() for h in _extra.split(",") if h.strip())
if _allowed:
    mcp.settings.transport_security.allowed_hosts = _allowed

# ---------------------------------------------------------------------------
# 6. Custom routes (health check + Notion OAuth callback)
# ---------------------------------------------------------------------------

from starlette.requests import Request  # noqa: E402
from starlette.responses import JSONResponse, RedirectResponse, Response  # noqa: E402


@mcp.custom_route("/health", methods=["GET"])
async def health(request: Request) -> Response:
    return JSONResponse({"status": "ok"})


# Note: MCP SDK auto-generates /.well-known/oauth-protected-resource/mcp
# via create_protected_resource_routes() when resource_server_url is set


@mcp.custom_route("/oauth/callback", methods=["GET"])
async def notion_oauth_callback(request: Request) -> Response:
    """Handle Notion's OAuth redirect after user authorizes.

    Exchanges Notion's auth code for an access token, generates our own
    auth code, and redirects back to Claude's redirect_uri.
    """
    code = request.query_params.get("code")
    state = request.query_params.get("state")
    error = request.query_params.get("error")

    if error:
        logger.error("Notion OAuth error: %s", error)
        return JSONResponse(
            {"error": "notion_oauth_error", "detail": error}, status_code=400
        )

    if not code or not state:
        return JSONResponse(
            {"error": "missing_params", "detail": "code and state are required"},
            status_code=400,
        )

    try:
        redirect_url = await provider.exchange_notion_code(code, state)
        return RedirectResponse(url=redirect_url, status_code=302)
    except ValueError as exc:
        logger.error("OAuth callback failed: %s", exc)
        return JSONResponse(
            {"error": "callback_failed", "detail": str(exc)}, status_code=400
        )
    except Exception as exc:
        logger.exception("Unexpected error in OAuth callback")
        return JSONResponse(
            {"error": "internal_error", "detail": "An internal error occurred"},
            status_code=500,
        )


# ---------------------------------------------------------------------------
# 7. Build the app with custom auth middleware for unauthenticated discovery
# ---------------------------------------------------------------------------

from auth.discovery_auth import MethodAwareAuthMiddleware  # noqa: E402


def _build_app():
    """Build the Starlette app and patch /mcp auth to allow tool discovery."""
    app = mcp.streamable_http_app()

    for route in app.routes:
        if hasattr(route, "path") and route.path == "/mcp":
            auth_middleware = route.app
            if not hasattr(auth_middleware, "app"):
                logger.warning("Cannot patch /mcp route — unexpected middleware structure")
                break
            inner_app = auth_middleware.app
            route.app = MethodAwareAuthMiddleware(
                app=inner_app,
                auth_middleware=auth_middleware,
            )
            logger.info("Patched /mcp with MethodAwareAuthMiddleware")
            break
    else:
        logger.warning("Could not find /mcp route to patch")

    return app


# ---------------------------------------------------------------------------
# 8. Run
# ---------------------------------------------------------------------------


def main():
    import uvicorn  # noqa: E402

    logger.info("Starting notion-mcp-remote on %s:%d", HOST, PORT)
    logger.info("Base URL: %s", BASE_URL)
    logger.info("MCP endpoint: %s/mcp", BASE_URL)
    app = _build_app()
    uvicorn.run(app, host=HOST, port=PORT)


if __name__ == "__main__":
    main()

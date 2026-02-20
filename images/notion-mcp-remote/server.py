"""Main entrypoint — configures the notion-mcp FastMCP instance with OAuth
and serves it over Streamable HTTP using mcp-remote-auth.
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
BASE_URL = os.environ.get("BASE_URL", "https://example.com")
HOST = os.environ.get("HOST", "127.0.0.1")
PORT = int(os.environ.get("PORT", "8000"))
ONBOARD_SECRET = os.environ.get("ONBOARD_SECRET", "")

logging.basicConfig(level=logging.INFO, stream=sys.stderr)
logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# 1. Apply the per-request client monkey-patch BEFORE importing mcp
#    (notion_mcp registers tools at import time)
# ---------------------------------------------------------------------------

from client_patch import apply_patch, set_client_for_request  # noqa: E402

apply_patch()

# ---------------------------------------------------------------------------
# 2. Import the already-constructed FastMCP instance from notion-mcp
# ---------------------------------------------------------------------------

from notion_mcp.server import mcp  # noqa: E402

# ---------------------------------------------------------------------------
# 3. Configure auth via mcp-remote-auth
# ---------------------------------------------------------------------------

from mcp_remote_auth import (  # noqa: E402
    ProviderConfig,
    TokenStore,
    OAuthProxyProvider,
    configure_mcp_auth,
    configure_transport_security,
    register_standard_routes,
    register_onboarding_routes,
    build_app_with_middleware,
)


def _setup_notion_client(token_data, config):
    """Inject a per-request NotionClient from the stored Notion token."""
    set_client_for_request(api_key=token_data["notion_token"])


def _extract_notion_identity(token_response):
    """Extract identity from Notion token response (owner.user.name + workspace)."""
    owner = token_response.get("owner", {})
    user = owner.get("user", {})
    name = user.get("name")
    workspace = token_response.get("workspace_name")
    if name and workspace:
        return f"{name} ({workspace})"
    return name or workspace or None


config = ProviderConfig(
    provider_name="Notion",
    authorize_url="https://api.notion.com/v1/oauth/authorize",
    token_url="https://api.notion.com/v1/oauth/token",
    client_id=NOTION_OAUTH_CLIENT_ID,
    client_secret=NOTION_OAUTH_CLIENT_SECRET,
    base_url=BASE_URL,
    scopes="",
    extra_authorize_params={"owner": "user"},
    token_exchange_format="json_basic_auth",
    upstream_token_key="notion_token",
    upstream_response_token_field="access_token",
    access_token_lifetime=31536000,
    setup_client_for_request=_setup_notion_client,
    extract_identity_from_token_response=_extract_notion_identity,
)

store = TokenStore(secret=SESSION_SECRET)
provider = OAuthProxyProvider(store=store, config=config)

configure_mcp_auth(mcp, provider, BASE_URL)
mcp.settings.host = HOST
mcp.settings.port = PORT
mcp.settings.stateless_http = False
configure_transport_security(mcp, BASE_URL, os.environ.get("ADDITIONAL_ALLOWED_HOSTS", ""))
register_standard_routes(mcp, provider, BASE_URL)
register_onboarding_routes(mcp, provider, store, config, ONBOARD_SECRET)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main():
    import uvicorn  # noqa: E402

    logger.info("Starting notion-mcp-remote on %s:%d", HOST, PORT)
    app = build_app_with_middleware(mcp, use_body_inspection=False)
    uvicorn.run(app, host=HOST, port=PORT)


if __name__ == "__main__":
    main()

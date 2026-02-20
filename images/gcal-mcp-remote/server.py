"""Main entrypoint — configures the gcal-mcp FastMCP instance with OAuth
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

GCAL_OAUTH_CLIENT_ID = os.environ["GCAL_OAUTH_CLIENT_ID"]
GCAL_OAUTH_CLIENT_SECRET = os.environ["GCAL_OAUTH_CLIENT_SECRET"]
SESSION_SECRET = os.environ["SESSION_SECRET"]
BASE_URL = os.environ.get("BASE_URL", "https://example.com")
HOST = os.environ.get("HOST", "127.0.0.1")
PORT = int(os.environ.get("PORT", "8001"))
ONBOARD_SECRET = os.environ.get("ONBOARD_SECRET", "")

logging.basicConfig(level=logging.INFO, stream=sys.stderr)
logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# 1. Apply the per-request client monkey-patch BEFORE importing mcp
#    (gcal_mcp registers tools at import time)
# ---------------------------------------------------------------------------

from gcal_mcp_remote.client_patch import apply_patch, set_client_for_request  # noqa: E402

apply_patch()

# ---------------------------------------------------------------------------
# 2. Import the already-constructed FastMCP instance from gcal-mcp
# ---------------------------------------------------------------------------

from gcal_mcp.server import mcp  # noqa: E402

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

GCAL_SCOPES = "https://www.googleapis.com/auth/calendar"


def _setup_gcal_client(token_data, config):
    """Inject a per-request GCalClient from the stored Google refresh token."""
    set_client_for_request(
        refresh_token=token_data["google_refresh_token"],
        client_id=config.client_id,
        client_secret=config.client_secret,
    )


config = ProviderConfig(
    provider_name="Google Calendar",
    authorize_url="https://accounts.google.com/o/oauth2/auth",
    token_url="https://oauth2.googleapis.com/token",
    client_id=GCAL_OAUTH_CLIENT_ID,
    client_secret=GCAL_OAUTH_CLIENT_SECRET,
    base_url=BASE_URL,
    scopes=GCAL_SCOPES,
    extra_authorize_params={"access_type": "offline", "prompt": "consent"},
    upstream_token_key="google_refresh_token",
    upstream_response_token_field="refresh_token",
    access_token_lifetime=31536000,
    setup_client_for_request=_setup_gcal_client,
    user_info_url="https://www.googleapis.com/oauth2/v2/userinfo",
    user_info_identity_field="email",
    onboard_extra_scopes="openid email",
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

    logger.info("Starting gcal-mcp-remote on %s:%d", HOST, PORT)
    app = build_app_with_middleware(mcp, use_body_inspection=False)
    uvicorn.run(app, host=HOST, port=PORT)


if __name__ == "__main__":
    main()

"""Per-request NotionClient injection via ContextVar.

Monkey-patches get_client() in notion_mcp.server and all 6 tool modules
so each authenticated request gets its own NotionClient with the user's
Notion access token.
"""

from __future__ import annotations

from contextlib import contextmanager
from contextvars import ContextVar

from notion_sdk import NotionClient

_request_client: ContextVar[NotionClient | None] = ContextVar(
    "_request_client", default=None
)


def patched_get_client() -> NotionClient:
    """Return the per-request NotionClient set by the OAuth flow."""
    client = _request_client.get()
    if client is None:
        raise RuntimeError(
            "No NotionClient set for this request — is OAuth configured?"
        )
    return client


def set_client_for_request(api_key: str) -> None:
    """Create a NotionClient with the given API key and set it on the contextvar."""
    client = NotionClient(api_key=api_key)
    _request_client.set(client)


@contextmanager
def client_context(api_key: str):
    """Context manager that sets up a per-request NotionClient."""
    token = _request_client.set(NotionClient(api_key=api_key))
    try:
        yield
    finally:
        _request_client.reset(token)


def apply_patch() -> None:
    """Replace get_client in notion_mcp.server and all tool modules."""
    import notion_mcp.server
    import notion_mcp.tools.blocks
    import notion_mcp.tools.comments
    import notion_mcp.tools.databases
    import notion_mcp.tools.pages
    import notion_mcp.tools.search
    import notion_mcp.tools.users

    notion_mcp.server.get_client = patched_get_client

    for mod in [
        notion_mcp.tools.blocks,
        notion_mcp.tools.comments,
        notion_mcp.tools.databases,
        notion_mcp.tools.pages,
        notion_mcp.tools.search,
        notion_mcp.tools.users,
    ]:
        mod.get_client = patched_get_client

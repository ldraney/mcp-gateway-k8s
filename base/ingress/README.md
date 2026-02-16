# Tailscale Funnel via K8s Operator

Each MCP service gets its own `ts.net` hostname for OAuth callbacks.
Internal service-to-service traffic stays on ClusterIP — these Funnel
services are **only** for external OAuth redirect URIs.

## Hostnames

| Service | Hostname | OAuth callback |
|---------|----------|----------------|
| Notion | `notion-mcp.<tailnet>.ts.net` | `/oauth/callback` |
| Google Calendar | `gcal-mcp.<tailnet>.ts.net` | `/oauth/callback` |
| Gmail | `gmail-mcp.<tailnet>.ts.net` | `/oauth/callback` |
| LinkedIn | `linkedin-mcp.<tailnet>.ts.net` | `/oauth/callback` |

## Setup (one-time)

### 1. Create Tailscale OAuth client

Go to https://login.tailscale.com/admin/settings/oauth
- Scopes: `devices` (write), `auth_keys` (write)
- Tag: `tag:k8s`

Save the client ID and secret to `config.env`:
```
TAILSCALE_OAUTH_CLIENT_ID=...
TAILSCALE_OAUTH_CLIENT_SECRET=...
```

### 2. Configure Tailscale ACL

At https://login.tailscale.com/admin/acls, add:

```json
"tagOwners": {
  "tag:k8s": ["autogroup:admin"]
},
"nodeAttrs": [
  { "target": ["tag:k8s"], "attr": ["funnel"] }
]
```

### 3. Install the operator

```bash
make tailscale-operator
```

### 4. Apply the Funnel services

```bash
make ingress
```

### 5. Verify the new routes work

From a device **outside** the tailnet (e.g. phone on cellular), or using
the proxy pod directly:

```bash
# Check Funnel status inside each proxy pod
kubectl exec -n tailscale <proxy-pod> -c tailscale -- tailscale funnel status

# Verify from external device (Funnel doesn't work from same tailnet)
curl https://gmail-mcp.<tailnet>.ts.net/
```

All 4 should show `Funnel on` and return an HTTP response (401/404 is fine — it means the service is reachable).

### 6. Remove old manual Funnel routes

Only after step 5 confirms the operator-managed routes work:
```bash
sudo tailscale funnel reset
sudo tailscale serve status  # should show empty
```

## Migrating from manual Funnel

Previously, Notion and GCal used manual `tailscale funnel` commands
on the host with different ports (:443, :8443). The operator approach
replaces this — each service gets a dedicated hostname on :443.

After migration, update `config.env` base URLs and the OAuth redirect
URIs in Google Cloud Console / Notion / LinkedIn developer portals.

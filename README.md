# openclaw-k8s

Kubernetes manifests for the OpenClaw platform on archbox.

## Architecture

```
                    ┌─────────────────────────────────────────────┐
                    │               K8s: openclaw namespace        │
                    │                                             │
  Telegram ──────►  │  ┌──────────────────┐                       │
                    │  │ openclaw-gateway  │                       │
                    │  │ (Node.js)         │──► ollama:11434       │
                    │  │ + mcp-bridge      │    (llama3.3:70b)     │
                    │  │   plugin          │                       │
                    │  └──┬───────┬────────┘                       │
                    │     │       │                                │
                    │     ▼       ▼                                │
                    │  notion-   gcal-                             │
                    │  mcp:8000  mcp:8001                          │
                    │                                             │
                    │  [token-db PVC] ◄── shared SQLite            │
                    └─────────────────────────────────────────────┘
```

## Components

| Pod | Image | Port | Purpose |
|-----|-------|------|---------|
| `openclaw-gateway` | `openclaw:latest` | 18789 | Main bot + bridge plugin |
| `notion-mcp-remote` | `notion-mcp-remote:latest` | 8000 | Notion MCP server with OAuth |
| `gcal-mcp-remote` | `gcal-mcp-remote:latest` | 8001 | Google Calendar MCP server with OAuth |
| `ollama` | `ollama/ollama:latest` | 11434 | LLM serving (GPU) |

## Prerequisites

- K8s cluster on archbox (k3s recommended)
- NVIDIA GPU runtime for Ollama
- Container images built locally (see below)

## Quick Start

### 1. Build images

```bash
# OpenClaw (from the openclaw fork)
cd ~/openclaw
docker build -t openclaw:latest .

# Notion MCP
cd ~/notion-mcp-remote
docker build -t notion-mcp-remote:latest -f ~/openclaw-k8s/images/notion-mcp-remote/Dockerfile .

# Google Calendar MCP
cd ~/gcal-mcp-remote
docker build -t gcal-mcp-remote:latest -f ~/openclaw-k8s/images/gcal-mcp-remote/Dockerfile .
```

### 2. Create secrets

```bash
kubectl create namespace openclaw

kubectl create secret generic openclaw-secrets -n openclaw \
  --from-literal=gateway-token="$(openssl rand -hex 32)" \
  --from-literal=telegram-bot-token="YOUR_BOT_TOKEN"

kubectl create secret generic notion-mcp-secrets -n openclaw \
  --from-literal=base-url="https://archbox.tail5b443a.ts.net" \
  --from-literal=oauth-client-id="YOUR_NOTION_CLIENT_ID" \
  --from-literal=oauth-client-secret="YOUR_NOTION_CLIENT_SECRET" \
  --from-literal=session-secret="$(openssl rand -hex 32)"

kubectl create secret generic gcal-mcp-secrets -n openclaw \
  --from-literal=base-url="https://archbox.tail5b443a.ts.net:8001" \
  --from-literal=oauth-client-id="YOUR_GCAL_CLIENT_ID" \
  --from-literal=oauth-client-secret="YOUR_GCAL_CLIENT_SECRET" \
  --from-literal=session-secret="$(openssl rand -hex 32)"
```

### 3. Deploy

```bash
./deploy.sh
```

### 4. Pull the Ollama model

```bash
kubectl exec -n openclaw deploy/ollama -- ollama pull llama3.3:70b
```

### 5. Verify

```bash
kubectl get pods -n openclaw
kubectl logs -n openclaw deploy/openclaw-gateway --tail=50
```

## Bot Setup

1. Message [@BotFather](https://t.me/BotFather) on Telegram
2. `/newbot` -> name it (e.g. "OpenClaw Dev") -> username (e.g. `OpenClawDevBot`)
3. Copy the token into the `openclaw-secrets` secret
4. Restart the gateway: `kubectl rollout restart -n openclaw deploy/openclaw-gateway`
5. DM your bot -- it should respond via Ollama

## Token DB

The `token-db` PVC is mounted at `/data/tokens` in the openclaw-gateway pod. The bridge plugin's SQLite database lives there. When the `/connect` flow is implemented, OAuth callbacks will write tokens to this same database.

## Network

MCP servers communicate internally via K8s ClusterIP services. External OAuth callbacks (Notion/Google redirects) reach the MCP servers through Tailscale. The Telegram bot uses outbound polling -- no inbound port needed.

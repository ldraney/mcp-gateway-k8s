# mcp-gateway-k8s

Self-hosted AI assistant on Kubernetes. Bridges [MCP](https://modelcontextprotocol.io/) servers (Notion, Google Calendar, etc.) to chat platforms (Telegram, Slack) using a free local model via Ollama.

Built on [OpenClaw](https://github.com/ldraney/openclaw) + [openclaw-mcp-bridge](https://github.com/ldraney/openclaw-mcp-bridge).

## Architecture

```
                    ┌─────────────────────────────────────────────┐
                    │               K8s: openclaw namespace        │
                    │                                             │
  Telegram ──────►  │  ┌──────────────────┐                       │
                    │  │ openclaw-gateway  │                       │
                    │  │ (Node.js)         │──► ollama:11434       │
                    │  │ + mcp-bridge      │    (your model)       │
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

## Prerequisites

- K8s cluster (k3s recommended for single-node)
- NVIDIA GPU runtime for Ollama
- Container images built locally (see [Build Images](#2-build-images))

## Quick Start

### 1. Configure

```bash
cp config.env.example config.env
# Edit config.env with your values
```

`config.env` is gitignored -- your secrets stay local.

### 2. Build Images

```bash
# OpenClaw gateway
cd ~/openclaw && docker build -t openclaw:latest .

# MCP servers (Dockerfiles in images/)
cd ~/notion-mcp-remote && docker build -t notion-mcp-remote:latest \
  -f ~/mcp-gateway-k8s/images/notion-mcp-remote/Dockerfile .
cd ~/gcal-mcp-remote && docker build -t gcal-mcp-remote:latest \
  -f ~/mcp-gateway-k8s/images/gcal-mcp-remote/Dockerfile .
```

### 3. Deploy

```bash
make deploy     # Creates secrets from config.env, applies all manifests
make pull-model # Pulls the Ollama model into the pod
```

### 4. Verify

```bash
make status     # Pod status
make logs       # Tail gateway logs
```

DM your Telegram bot -- it should respond.

## Commands

| Command | Description |
|---------|-------------|
| `make deploy` | Create secrets + apply all manifests |
| `make secrets` | Create/update K8s secrets from config.env |
| `make pull-model` | Pull the configured Ollama model |
| `make status` | Show pod status |
| `make logs` | Tail gateway logs |
| `make restart` | Rolling restart all deployments |
| `make teardown` | Delete everything (destructive) |
| `make monitoring` | Install full monitoring stack (Prometheus + Grafana + Loki) |
| `make monitoring-gpu` | Install GPU metrics exporter (optional) |
| `make monitoring-status` | Show monitoring pod status |
| `make monitoring-portforward` | Port-forward Grafana to localhost:3000 |
| `make monitoring-teardown` | Remove monitoring stack (destructive) |

## Components

| Pod | Port | Purpose |
|-----|------|---------|
| `openclaw-gateway` | 18789 | Chat bot + MCP bridge plugin |
| `notion-mcp-remote` | 8000 | Notion API via MCP with OAuth |
| `gcal-mcp-remote` | 8001 | Google Calendar via MCP with OAuth |
| `ollama` | 11434 | Local LLM serving (GPU) |

## How It Works

1. User messages the Telegram bot
2. OpenClaw routes the message to Ollama for inference
3. When the model calls an MCP tool (e.g. "search Notion"), the bridge plugin forwards it to the appropriate MCP server over HTTP
4. The MCP server authenticates with the user's OAuth token and returns results
5. The model incorporates the results and responds

Each MCP server handles its own OAuth flow. Per-user tokens are stored in a shared SQLite database so the bridge can look up the right token for each user at call time.

## Adding MCP Servers

To add a new MCP server (e.g. Gmail, GitHub, Slack):

1. Create a Dockerfile and deployment in `base/your-server/`
2. Add the server to the bridge plugin config in `base/openclaw/configmap.yaml`
3. Add any required secrets to `config.env.example` and the Makefile

## Network

- MCP servers communicate internally via K8s ClusterIP services
- External OAuth callbacks reach MCP servers via your ingress (Tailscale Funnel, ngrok, Cloudflare Tunnel, etc.)
- Telegram bot uses outbound polling -- no inbound port required

## Monitoring

The monitoring stack runs in a separate `monitoring` namespace and provides:

- **Prometheus** — metrics collection (pod CPU/memory, node health, GPU utilization)
- **Grafana** — dashboards and alerting UI
- **Loki + Promtail** — centralized log aggregation from all pods
- **Alertmanager** — alert routing (PodCrashLooping, OOMKilled, disk pressure, PVC usage)

```bash
make monitoring          # Install Prometheus + Grafana + Loki + alert rules
make monitoring-gpu      # Optional: GPU metrics (requires DCGM-compatible GPU)
make monitoring-status   # Check pod health
make monitoring-portforward  # Access Grafana at localhost:3000
```

Grafana is also exposed via Tailscale Funnel at `https://grafana.<tailnet>.ts.net` after `make monitoring`.

Set `GRAFANA_ADMIN_PASSWORD` in `config.env` before installing (defaults to "admin").

## Creating Your Telegram Bot

1. Message [@BotFather](https://t.me/BotFather) on Telegram
2. Send `/newbot`, pick a name and username
3. Copy the token into `config.env` as `TELEGRAM_BOT_TOKEN`
4. Run `make secrets && make restart`

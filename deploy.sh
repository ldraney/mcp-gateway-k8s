#!/usr/bin/env bash
set -euo pipefail

# Deploy the full OpenClaw stack to K8s.
# Prerequisites:
#   - kubectl configured for your cluster
#   - Container images built (see README.md)
#   - Secrets created (see base/secrets.example.yaml)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Creating namespace..."
kubectl apply -f "$SCRIPT_DIR/base/namespace/"

echo "==> Creating shared volumes..."
kubectl apply -f "$SCRIPT_DIR/base/shared/"

echo "==> Deploying Ollama..."
kubectl apply -f "$SCRIPT_DIR/base/ollama/"

echo "==> Deploying notion-mcp-remote..."
kubectl apply -f "$SCRIPT_DIR/base/notion-mcp-remote/"

echo "==> Deploying gcal-mcp-remote..."
kubectl apply -f "$SCRIPT_DIR/base/gcal-mcp-remote/"

echo "==> Deploying OpenClaw gateway..."
kubectl apply -f "$SCRIPT_DIR/base/openclaw/"

echo ""
echo "==> Done. Check status with:"
echo "    kubectl get pods -n openclaw"
echo ""
echo "==> Pull the Ollama model:"
echo "    kubectl exec -n openclaw deploy/ollama -- ollama pull llama3.3:70b"

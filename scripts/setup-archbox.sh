#!/usr/bin/env bash
set -euo pipefail

# Setup script for archbox single-node k3s cluster
# Run this on archbox to bootstrap the OpenClaw platform.
# Prerequisites: Arch Linux, NVIDIA GPU (GTX 1070+), Tailscale installed

echo "=== Step 1: Install k3s (single-node) ==="
# Traefik disabled since we use Tailscale Funnel for ingress
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable=traefik" sh -

# Make kubeconfig accessible
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown "$(id -u):$(id -g)" ~/.kube/config
export KUBECONFIG=~/.kube/config

echo "k3s installed. Checking node..."
kubectl get nodes

echo ""
echo "=== Step 2: Install NVIDIA GPU Operator ==="
# k3s ships containerd, so we need the nvidia-container-toolkit
# On Arch: install from AUR or NVIDIA repos

# Install nvidia-container-toolkit
if ! command -v nvidia-ctk &>/dev/null; then
    echo "Installing nvidia-container-toolkit..."
    echo "On Arch Linux:"
    echo "  yay -S nvidia-container-toolkit"
    echo "Then run: sudo nvidia-ctk runtime configure --runtime=containerd"
    echo "And restart k3s: sudo systemctl restart k3s"
    echo ""
    echo "Re-run this script after installing nvidia-container-toolkit."
    exit 1
fi

# Configure containerd for NVIDIA runtime
sudo nvidia-ctk runtime configure --runtime=containerd
sudo systemctl restart k3s
sleep 5

# Install GPU operator via Helm
if ! command -v helm &>/dev/null; then
    echo "Installing Helm..."
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm repo update

# Install with driver pre-installed (Arch manages its own NVIDIA driver)
helm install gpu-operator nvidia/gpu-operator \
    --namespace gpu-operator --create-namespace \
    --set driver.enabled=false \
    --set toolkit.enabled=false \
    --wait

echo "GPU operator installed. Checking GPU visibility..."
kubectl get nodes -o json | grep -o "nvidia.com/gpu[^,]*" || echo "GPU not yet visible - may take a minute"

echo ""
echo "=== Step 3: Build container images ==="
# k3s uses containerd, so we import images directly
# Build with docker/podman, then import

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Services that install from PyPI (no source code needed)
for svc in gcal-mcp-remote; do
    echo "Building $svc from PyPI..."
    docker build -t "$svc:latest" "$REPO_ROOT/images/$svc/"
    docker save "$svc:latest" | sudo k3s ctr images import -
    echo "$svc image imported into k3s"
done

# Services that still need local source directories
for svc in notion-mcp-remote; do
    SRC_DIR="$HOME/$svc"
    if [ ! -d "$SRC_DIR" ]; then
        echo "SKIP: ~/$svc not found. Clone it first."
        continue
    fi
    echo "Building $svc..."
    cp "$REPO_ROOT/images/$svc/Dockerfile" "$SRC_DIR/Dockerfile.k8s"
    (cd "$SRC_DIR" && docker build -f Dockerfile.k8s -t "$svc:latest" .)
    docker save "$svc:latest" | sudo k3s ctr images import -
    echo "$svc image imported into k3s"
done

# gmail-mcp-remote (if repo exists)
if [ -d "$HOME/gmail-mcp-remote" ]; then
    echo "Building gmail-mcp-remote..."
    cp "$REPO_ROOT/images/gmail-mcp-remote/Dockerfile" "$HOME/gmail-mcp-remote/Dockerfile.k8s"
    (cd "$HOME/gmail-mcp-remote" && docker build -f Dockerfile.k8s -t "gmail-mcp-remote:latest" .)
    docker save "gmail-mcp-remote:latest" | sudo k3s ctr images import -
fi

# OpenClaw (assumes pre-built)
if docker image inspect openclaw:latest &>/dev/null; then
    echo "Importing openclaw image into k3s..."
    docker save openclaw:latest | sudo k3s ctr images import -
else
    echo "SKIP: openclaw:latest not found. Build it from ~/openclaw first:"
    echo "  cd ~/openclaw && docker build -t openclaw:latest ."
fi

echo ""
echo "=== Step 4: Deploy ==="
echo "Now run from the mcp-gateway-k8s repo:"
echo "  cp config.env.example config.env  # fill in values"
echo "  make deploy"
echo "  make pull-model"
echo "  make status"

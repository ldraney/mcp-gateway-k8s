# Tailscale Kubernetes Operator

Prerequisite: Install via Helm before applying these manifests.

1. Create an OAuth client at https://login.tailscale.com/admin/settings/oauth
   - Scopes: devices (write), auth_keys (write)
   - Tag: tag:k8s

2. Add tag:k8s to your tailnet ACL:
   ```json
   "tagOwners": { "tag:k8s": ["autogroup:admin"] }
   ```

3. Enable Funnel in ACL:
   ```json
   "nodeAttrs": [{ "target": ["tag:k8s"], "attr": ["funnel"] }]
   ```

4. Install the operator:
   ```bash
   helm repo add tailscale https://pkgs.tailscale.com/helmcharts
   helm repo update
   helm install tailscale-operator tailscale/tailscale-operator \
     --namespace tailscale --create-namespace \
     --set oauth.clientId=<YOUR_CLIENT_ID> \
     --set oauth.clientSecret=<YOUR_CLIENT_SECRET> \
     --set operatorConfig.defaultTags=tag:k8s
   ```

After the operator is running, apply the service patches in this directory
to expose MCP servers via Tailscale Funnel.

> **Note:** This file is intentionally a README (not a YAML manifest).
> The actual operator is installed via Helm (see instructions above).
> The service patches in this directory handle the exposure.

.PHONY: secrets deploy teardown status logs build help ingress tailscale-operator \
	monitoring-repos monitoring-install monitoring-loki monitoring-gpu \
	monitoring-manifests monitoring-status monitoring-portforward monitoring-teardown monitoring

CONFIG_ENV ?= config.env

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'

check-config:
	@test -f $(CONFIG_ENV) || (echo "Error: $(CONFIG_ENV) not found. Run: cp config.env.example config.env" && exit 1)

secrets: check-config ## Create K8s secrets from config.env
	@set -a && . ./$(CONFIG_ENV) && set +a && \
	kubectl create namespace openclaw --dry-run=client -o yaml | kubectl apply -f - && \
	kubectl create secret generic openclaw-secrets -n openclaw \
		--from-literal=gateway-token="$$OPENCLAW_GATEWAY_TOKEN" \
		--from-literal=telegram-bot-token="$$TELEGRAM_BOT_TOKEN" \
		--dry-run=client -o yaml | kubectl apply -f - && \
	kubectl create secret generic notion-mcp-secrets -n openclaw \
		--from-literal=base-url="$$NOTION_BASE_URL" \
		--from-literal=oauth-client-id="$$NOTION_OAUTH_CLIENT_ID" \
		--from-literal=oauth-client-secret="$$NOTION_OAUTH_CLIENT_SECRET" \
		--from-literal=session-secret="$$NOTION_SESSION_SECRET" \
		--dry-run=client -o yaml | kubectl apply -f - && \
	kubectl create secret generic gcal-mcp-secrets -n openclaw \
		--from-literal=base-url="$$GCAL_BASE_URL" \
		--from-literal=oauth-client-id="$$GCAL_OAUTH_CLIENT_ID" \
		--from-literal=oauth-client-secret="$$GCAL_OAUTH_CLIENT_SECRET" \
		--from-literal=session-secret="$$GCAL_SESSION_SECRET" \
		--dry-run=client -o yaml | kubectl apply -f - && \
	kubectl create secret generic gmail-mcp-secrets -n openclaw \
		--from-literal=base-url="$$GMAIL_BASE_URL" \
		--from-literal=oauth-client-id="$$GMAIL_OAUTH_CLIENT_ID" \
		--from-literal=oauth-client-secret="$$GMAIL_OAUTH_CLIENT_SECRET" \
		--from-literal=session-secret="$$GMAIL_SESSION_SECRET" \
		--dry-run=client -o yaml | kubectl apply -f - && \
	kubectl create secret generic linkedin-scheduler-secrets -n openclaw \
		--from-literal=base-url="$$LINKEDIN_BASE_URL" \
		--from-literal=oauth-client-id="$$LINKEDIN_OAUTH_CLIENT_ID" \
		--from-literal=oauth-client-secret="$$LINKEDIN_OAUTH_CLIENT_SECRET" \
		--from-literal=session-secret="$$LINKEDIN_SESSION_SECRET" \
		--dry-run=client -o yaml | kubectl apply -f - && \
	kubectl create secret generic billing-secrets -n openclaw \
		--from-literal=stripe-api-key="$$STRIPE_API_KEY" \
		--from-literal=stripe-webhook-secret="$$STRIPE_WEBHOOK_SECRET" \
		--dry-run=client -o yaml | kubectl apply -f - && \
	echo "Secrets created in openclaw namespace."

deploy: secrets ## Deploy the full stack
	kubectl apply -f base/namespace/
	kubectl apply -f base/shared/
	kubectl apply -f base/backup/
	kubectl apply -f base/ollama/
	kubectl apply -f base/notion-mcp-remote/
	kubectl apply -f base/gcal-mcp-remote/
	kubectl apply -f base/gmail-mcp-remote/
	kubectl apply -f base/linkedin-scheduler-remote/
	kubectl apply -f base/billing/
	kubectl apply -f base/openclaw/
	@echo ""
	@echo "Deployed. Run 'make status' to check pods."
	@echo "Pull the model: make pull-model"

pull-model: check-config ## Pull the Ollama model into the running pod
	@set -a && . ./$(CONFIG_ENV) && set +a && \
	kubectl exec -n openclaw deploy/ollama -- ollama pull "$$OLLAMA_MODEL"

status: ## Show pod status
	kubectl get pods -n openclaw

logs: ## Tail openclaw-gateway logs
	kubectl logs -n openclaw deploy/openclaw-gateway -f --tail=50

teardown: ## Delete the entire openclaw namespace (destructive!)
	@echo "This will delete ALL resources in the openclaw namespace."
	@read -p "Are you sure? [y/N] " confirm && [ "$$confirm" = "y" ] && \
		kubectl delete namespace openclaw || echo "Aborted."

tailscale-operator: check-config ## Install/upgrade the Tailscale K8s Operator
	@set -a && . ./$(CONFIG_ENV) && set +a && \
	helm repo add tailscale https://pkgs.tailscale.com/helmcharts 2>/dev/null || true && \
	helm repo update tailscale && \
	helm upgrade --install tailscale-operator tailscale/tailscale-operator \
		--namespace tailscale --create-namespace \
		--set oauth.clientId="$$TAILSCALE_OAUTH_CLIENT_ID" \
		--set oauth.clientSecret="$$TAILSCALE_OAUTH_CLIENT_SECRET" \
		--set operatorConfig.defaultTags=tag:k8s \
		--wait && \
	echo "Tailscale operator installed. Run 'make ingress' to expose services."

ingress: ## Deploy Tailscale Funnel services for OAuth callbacks
	kubectl apply -f base/ingress/

restart: ## Restart all deployments
	kubectl rollout restart -n openclaw deploy/openclaw-gateway
	kubectl rollout restart -n openclaw deploy/notion-mcp-remote
	kubectl rollout restart -n openclaw deploy/gcal-mcp-remote
	kubectl rollout restart -n openclaw deploy/gmail-mcp-remote
	kubectl rollout restart -n openclaw deploy/linkedin-scheduler-remote
	kubectl rollout restart -n openclaw deploy/pal-e-billing

# --- Monitoring Stack (Prometheus + Grafana + Loki) ---

monitoring-repos:
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
	helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
	helm repo add nvidia https://nvidia.github.io/dcgm-exporter/helm-charts 2>/dev/null || true
	helm repo update prometheus-community grafana nvidia

monitoring-install: check-config monitoring-repos ## Install kube-prometheus-stack (Prometheus + Grafana + Alertmanager)
	@set -a && . ./$(CONFIG_ENV) && set +a && \
	kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f - && \
	helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
		--namespace monitoring \
		--values helm/kube-prometheus-stack/values.yaml \
		--set grafana.adminPassword="$${GRAFANA_ADMIN_PASSWORD:-admin}" \
		--wait --timeout 10m && \
	echo "kube-prometheus-stack installed."

monitoring-loki: monitoring-repos ## Install Loki + Promtail for log aggregation
	kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f - && \
	helm upgrade --install loki-stack grafana/loki-stack \
		--namespace monitoring \
		--values helm/loki-stack/values.yaml \
		--wait --timeout 5m && \
	echo "loki-stack installed."

monitoring-gpu: monitoring-repos ## Install dcgm-exporter for GPU metrics (may fail on consumer GPUs)
	@kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f - && \
	helm upgrade --install dcgm-exporter nvidia/dcgm-exporter \
		--namespace monitoring \
		--values helm/dcgm-exporter/values.yaml \
		--wait --timeout 3m && \
	echo "dcgm-exporter installed." || \
	echo "WARNING: dcgm-exporter failed to install. GTX 1070 may not be supported. See issue #18 for fallback options."

monitoring-manifests: ## Apply PrometheusRules and Loki datasource ConfigMap
	kubectl apply -k base/monitoring/

monitoring-status: ## Show monitoring pod status
	kubectl get pods -n monitoring

monitoring-portforward: ## Port-forward Grafana to localhost:3000
	@echo "Grafana available at http://localhost:3000"
	@echo "Default login: admin / (your GRAFANA_ADMIN_PASSWORD)"
	kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80

monitoring-teardown: ## Delete the monitoring namespace (destructive!)
	@echo "This will delete ALL monitoring resources (Prometheus, Grafana, Loki, alerts)."
	@read -p "Are you sure? [y/N] " confirm && [ "$$confirm" = "y" ] && ( \
		helm uninstall kube-prometheus-stack -n monitoring 2>/dev/null || true; \
		helm uninstall loki-stack -n monitoring 2>/dev/null || true; \
		helm uninstall dcgm-exporter -n monitoring 2>/dev/null || true; \
		kubectl delete namespace monitoring \
	) || echo "Aborted."

monitoring: monitoring-install monitoring-loki monitoring-manifests ## Install full monitoring stack
	@echo "Full monitoring stack installed. Run 'make monitoring-status' to verify."

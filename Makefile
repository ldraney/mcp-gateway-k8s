.PHONY: secrets deploy teardown status logs build help ingress

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

ingress: ## Deploy Tailscale Funnel services for OAuth callbacks
	kubectl apply -f base/ingress/

restart: ## Restart all deployments
	kubectl rollout restart -n openclaw deploy/openclaw-gateway
	kubectl rollout restart -n openclaw deploy/notion-mcp-remote
	kubectl rollout restart -n openclaw deploy/gcal-mcp-remote
	kubectl rollout restart -n openclaw deploy/gmail-mcp-remote
	kubectl rollout restart -n openclaw deploy/linkedin-scheduler-remote

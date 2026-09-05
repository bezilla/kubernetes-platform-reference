# Every target here is what CI runs, so a green local run means a green CI run.
# Where they differ, CI is the authority.

SHELL := /usr/bin/env bash

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

# --- the platform -------------------------------------------------------------

.PHONY: up
up: ## Build the whole platform from nothing (needs Docker with 8 GiB)
	@./scripts/up.sh

.PHONY: down
down: ## Delete the cluster and .work/
	@./scripts/down.sh

.PHONY: status
status: ## Applications, edge, guardrails and tenant workloads
	@./scripts/status.sh

.PHONY: argo
argo: ## Port-forward the Argo CD UI and print the admin password
	@./scripts/argo-ui.sh

.PHONY: publish
publish: ## This setup's `git push`: mirror HEAD to the in-cluster Git server
	@./scripts/publish.sh

.PHONY: wait
wait: ## Block until every Application is Synced and Healthy (fails closed)
	@./scripts/wait-for-platform.sh

# --- proving it works ---------------------------------------------------------

.PHONY: demo
demo: demo-https demo-guardrails demo-gitops ## All three proofs, in order

.PHONY: demo-https
demo-https: ## The sample app over HTTPS through Gateway API
	@./scripts/demo-https.sh

.PHONY: demo-guardrails
demo-guardrails: ## Six violations rejected, the compliant deploy admitted
	@./scripts/demo-guardrails.sh

.PHONY: demo-gitops
demo-gitops: ## Commit a replica change and watch Argo CD apply it
	@./scripts/demo-gitops.sh

# --- checks that need no cluster ----------------------------------------------

.PHONY: lint
lint: ## helm lint + template the authored chart, and validate every manifest
	@./scripts/lint.sh

.PHONY: policy-test
policy-test: ## Run the Kyverno policies against known-good and known-bad resources
	@./scripts/policy-test.sh

.PHONY: check
check: lint policy-test identity ## Everything CI runs that does not need a cluster

# --- the gate -----------------------------------------------------------------

.PHONY: init
init: ## Step 1 for any clone: install the pre-push gate
	@git config core.hooksPath .githooks
	@echo "core.hooksPath = $$(git config --get core.hooksPath)"
	@command -v gitleaks >/dev/null 2>&1 \
		|| { echo "gitleaks is not installed. The pre-push gate fails closed without it: brew install gitleaks"; exit 1; }
	@echo "pre-push gate installed"

.PHONY: identity
identity: ## Run the pre-push gate over all of this repository's history
	@./.githooks/pre-push --all-history

.PHONY: test-hook
test-hook: ## Prove the gate still rejects each thing it claims to reject
	@./.githooks/selftest.sh

.PHONY: versions
versions: ## Every pinned version, in one place
	@grep -vE '^\s*#|^\s*$$' versions.env | sed 's/^/  /'

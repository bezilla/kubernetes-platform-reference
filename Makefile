# Every target here is what CI runs, so a green local run means a green CI run.
# Where they differ, CI is the authority.

# A recipe runs as plain `bash -c`, where a pipeline reports only its LAST
# command's status. `make up` died at the Argo CD install with a timeout and
# still reported exit 0, because the failure was upstream of a pipe. -e stops the
# recipe on that failure, -o pipefail makes the pipeline carry it, and -u catches
# an unset variable instead of silently expanding it to nothing.
#
# The flags go in SHELL, not .SHELLFLAGS, on purpose: macOS ships GNU Make 3.81,
# which predates .SHELLFLAGS (3.82) and ignores it without a word -- which is how
# a "fix" here can look applied and change nothing. `env` passes them through to
# bash, so this works on 3.81 and on modern make alike. Verified with
# `make shell-check`, which fails loudly if the options are not actually set.
SHELL := /usr/bin/env bash -e -u -o pipefail
.SHELLFLAGS := -c

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
demo: demo-https demo-guardrails demo-gitops demo-telemetry ## All four proofs, in order

.PHONY: demo-https
demo-https: ## The sample app over HTTPS through Gateway API
	@./scripts/demo-https.sh

.PHONY: demo-guardrails
demo-guardrails: ## Six violations rejected, the compliant deploy admitted
	@./scripts/demo-guardrails.sh

.PHONY: demo-gitops
demo-gitops: ## Commit a replica change and watch Argo CD apply it
	@./scripts/demo-gitops.sh

.PHONY: demo-telemetry
demo-telemetry: ## Spans arriving at a collector the app team never named
	@./scripts/demo-telemetry.sh

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

.PHONY: shell-check
shell-check: ## Prove recipes run with -e and -o pipefail (guards the make 3.81 trap)
	@case "$$SHELLOPTS" in *pipefail*) ;; *) echo "shell-check: pipefail NOT set in recipes"; exit 1;; esac
	@case "$$SHELLOPTS" in *errexit*) ;; *) echo "shell-check: errexit NOT set in recipes"; exit 1;; esac
	@echo "shell-check: recipes run with errexit and pipefail"

.PHONY: versions
versions: ## Every pinned version, in one place
	@grep -vE '^\s*#|^\s*$$' versions.env | sed 's/^/  /'

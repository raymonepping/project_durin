SHELL := /bin/sh

.DEFAULT_GOAL := help

STACKS     := vault infra backend ui identity observability
PROJECT_ROOT := $(shell pwd)

.PHONY: help check status storage ps images volumes network compose-config \
	$(addsuffix -up,$(STACKS)) $(addsuffix -down,$(STACKS)) $(addsuffix -logs,$(STACKS)) \
	gen-certs vault-bootstrap unseal vault-status vault-down vault-up \
	tf-init tf-plan tf-apply tf-transit tf-database tf-destroy \
	backend-build ui-build ui-rebuild ui-dev test-frontend test-frontend-ui \
	identity-bootstrap identity-secrets identity-verify rbac-test authority-test \
	db-migrate db-migrate-status seed reset reset-rotate demo-status verify \
	isolation-test threat-model-test security-test test-all vault-failover-test vault-lb-stats \
	hardening-test security-review

help: ## Show available commands
	@awk 'BEGIN {FS = ":.*## "; printf "Durin — Vault Enterprise Data Protection Reference\n\n"} /^[a-zA-Z0-9_-]+:.*## / {printf "  %-24s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# ── Podman ────────────────────────────────────────────────────────────────────

check: ## Verify Podman machine and Compose provider
	@./scripts/podman-check.sh

status: check ## Show Durin containers and networks
	@printf '\nDurin containers\n'
	@podman ps -a --filter label=io.podman.compose.project --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
	@printf '\nShared network\n'
	@podman network inspect durin-internal >/dev/null 2>&1 && echo 'durin-internal: present' || echo 'durin-internal: not created'

storage: ## Report Podman machine, image, container and volume storage
	@./scripts/podman-storage.sh

ps: ## List all containers
	@podman ps -a

images: ## List local images
	@podman images

volumes: ## List named volumes
	@podman volume ls

network: ## Create durin-internal network if absent
	@podman network exists durin-internal || podman network create durin-internal
	@echo "durin-internal: ready"

compose-config: ## Validate all compose.yaml files
	@found=0; \
	for stack in $(STACKS); do \
		if [ -f "compose/$$stack/compose.yaml" ]; then \
			found=1; ./scripts/compose.sh "$$stack" config --quiet || exit $$?; \
		fi; \
	done; \
	if [ "$$found" -eq 0 ]; then echo 'No compose.yaml files exist yet.'; fi

# ── Stack lifecycle ───────────────────────────────────────────────────────────

define STACK_TARGETS
$(1)-up: ## Start the $(1) stack
	@./scripts/compose.sh "$(1)" config --quiet
	@$(MAKE) --no-print-directory network
	@./scripts/compose.sh "$(1)" up -d

$(1)-down: ## Stop the $(1) stack
	@./scripts/compose.sh "$(1)" down

$(1)-logs: ## Follow $(1) logs
	@./scripts/compose.sh "$(1)" logs -f
endef

$(foreach stack,$(STACKS),$(eval $(call STACK_TARGETS,$(stack))))

# ── Vault ─────────────────────────────────────────────────────────────────────

gen-certs: ## Generate Vault TLS certificates (vault-tls/)
	@./scripts/vault-gen-certs.sh

vault-bootstrap: ## Bootstrap the Vault cluster (run once on fresh volumes)
	@./scripts/vault-bootstrap.sh

unseal: ## Unseal vault-s (idempotent)
	@./scripts/vault-unseal.sh

vault-status: ## Show Vault node status and Raft peers
	@./scripts/vault-status.sh

# ── Terraform ────────────────────────────────────────────────────────────────

tf-init: ## terraform init (vault-platform)
	@cd terraform/vault-platform && terraform init -input=false

tf-plan: ## terraform plan (vault-platform)
	@cd terraform/vault-platform && terraform plan -input=false

tf-apply: ## terraform apply (vault-platform — auth, policies, namespaces, audit)
	@cd terraform/vault-platform && terraform init -input=false && \
	  terraform apply -input=false -auto-approve

tf-transit: ## terraform apply (vault-transit — per-tenant Transit keys)
	@cd terraform/vault-transit && terraform init -input=false && \
	  terraform apply -input=false -auto-approve

tf-database: ## terraform apply (vault-database — needs make db-migrate first: durin_app/durin_owner roles)
	@set -a; . ./.env; set +a; \
	  export TF_VAR_postgres_user="$${TF_VAR_postgres_user:-$$POSTGRES_USER}" \
	         TF_VAR_postgres_password="$${TF_VAR_postgres_password:-$$POSTGRES_PASSWORD}" \
	         TF_VAR_postgres_db="$${TF_VAR_postgres_db:-$$POSTGRES_DB}"; \
	  cd terraform/vault-database && terraform init -input=false && \
	  terraform apply -input=false -auto-approve

tf-destroy: ## Destroy ALL Terraform-managed Vault resources (destructive — prompts for confirmation)
	@printf '\033[31mWARNING: This will destroy all Terraform-managed Vault resources (keys, auth, policies).\033[0m\n'
	@printf 'Type YES to continue: '; read ans; [ "$$ans" = "YES" ] || (echo "Aborted."; exit 1)
	@cd terraform/vault-database && terraform destroy -input=false -auto-approve || true
	@cd terraform/vault-transit   && terraform destroy -input=false -auto-approve || true
	@cd terraform/vault-platform  && terraform destroy -input=false -auto-approve || true

backend-build: ## Build the durin-backend container image
	@podman build -t durin-backend:local -f backend/Containerfile backend/

# ── Web Console (prompts/frontend/01_02, 01_03) ───────────────────────────────
# macOS provenance xattrs make podman tar AppleDouble ._ files that break the
# Nitro build — strip them and keep COPYFILE_DISABLE set.

ui-build: ## Build the durin-ui container image (Nuxt SPA + BFF)
	@xattr -rc ui 2>/dev/null || true
	@COPYFILE_DISABLE=1 podman build -t durin-ui:local -f ui/Containerfile ui/

ui-rebuild: ui-build ## Rebuild durin-ui and recreate it (re-renders the OIDC secret from Vault)
	@./scripts/identity-secrets.sh >/dev/null
	@./scripts/compose.sh ui up -d --force-recreate
	@echo "Web Console: http://localhost:3000"

ui-dev: ## Run the console with hot reload on the host (needs backend + identity; secret from Vault)
	@cd ui && NUXT_API_INTERNAL_URL=http://127.0.0.1:3001 \
	  NUXT_OIDC_INTERNAL_ISSUER=http://localhost:8083/realms/durin \
	  NUXT_OIDC_CLIENT_SECRET="$$(../scripts/identity-secrets.sh --show-secret oidc-client-secret)" npx nuxt dev

test-frontend: ## Playwright journeys J0–J9 against the live console (not @failover)
	@cd ui && npx playwright test --grep-invert "@failover|@screens|@narrative"

test-frontend-ui: ## Playwright journeys, headed
	@cd ui && npx playwright test --headed --grep-invert "@failover|@screens|@narrative"

# ── Identity ─────────────────────────────────────────────────────────────────

identity-secrets: ## Seed identity secrets in Vault KV + AppRole creds for identity-secrets-init (idempotent)
	@./scripts/identity-secrets.sh

identity-bootstrap: ## Identity stack from Vault-sourced secrets: LDAP users + passwords, Keycloak realm (idempotent)
	@$(MAKE) --no-print-directory network
	@./scripts/identity-secrets.sh
	@./scripts/compose.sh identity up -d
	@./scripts/compose.sh identity --profile init run --rm ldap-bootstrap
	@./scripts/compose.sh identity --profile init run --rm keycloak-bootstrap

identity-verify: ## Log in as every Durin user; check roles, tenants, audience in real tokens
	@./scripts/identity-verify.sh

authority-test: ## Identity-derived Vault authority: compromised backend holds nothing; Vault verifies the person
	@./scripts/test-authority.sh

rbac-test: ## RBAC + tenant-claim + JWT-negative matrix against the backend (needs auth enabled)
	@./scripts/test-rbac.sh

# ── Demo data ────────────────────────────────────────────────────────────────

db-migrate: ## Apply schema migrations as durin_owner (the backend never runs DDL)
	@./scripts/db-migrate.sh

db-migrate-status: ## Show applied schema migrations
	@./scripts/db-migrate.sh --status

seed: ## Seed demo data (tenants, customers, documents)
	@./scripts/seed.sh

reset: ## Reset demo to baseline (wipe + re-seed, keeps key versions)
	@./scripts/reset.sh

reset-rotate: ## Reset demo and rotate all Transit keys to a new version
	@./scripts/reset.sh --rotate

demo-status: ## Show current scenario state
	@curl -sf http://localhost:3001/api/v1/scenarios/state | python3 -m json.tool

# ── Verification ──────────────────────────────────────────────────────────────

verify: ## Smoke-test the running stack
	@./scripts/verify-stack.sh

hardening-test: ## Run the full hardening test matrix
	@./scripts/test-hardening.sh

isolation-test: ## Run the tenant isolation test matrix
	@./scripts/test-isolation.sh

threat-model-test: ## Run the threat model validation tests
	@./scripts/test-threat-model.sh

security-test: ## End-to-end security journeys (MUTATING: rotates keys, ends with reset+seed)
	@./scripts/test-security-journeys.sh

vault-failover-test: ## Stop the Vault leader under load; expect automatic failover via vault-lb
	@./scripts/test-vault-failover.sh

vault-lb-stats: ## Show vault-lb backend state (which node is active)
	@curl -s 'http://127.0.0.1:18404/stats;csv' | awk -F, '$$1=="vault_active"{print $$2, $$18}'

test-all: verify identity-verify authority-test rbac-test isolation-test hardening-test threat-model-test security-test ## Run every backend test suite

security-review: ## Open the security review document
	@cat docs/security-review.md

ops: ## Open the operations guide
	@cat docs/operations.md

# ── Failure behavior test helpers ──────────────────────────────────────────

vault-down: ## Stop Vault nodes (for failure behavior testing)
	@./scripts/compose.sh vault stop vault-s vault-1 vault-2 vault-3 2>/dev/null || \
	 ./scripts/compose.sh vault stop 2>/dev/null || true
	@echo "Vault nodes stopped — backend should now return 503 for protected operations"

vault-up: ## Start Vault nodes and unseal (after vault-down)
	@./scripts/compose.sh vault up -d
	@sleep 3
	@./scripts/vault-unseal.sh || true
	@echo "Vault nodes started — run 'make verify' to confirm recovery"

# ── Convenience: bring up the full stack in order ────────────────────────────

up: ## Bring up vault + infra + backend (in dependency order; then make identity-bootstrap and make ui-rebuild)
	@$(MAKE) --no-print-directory network
	@$(MAKE) --no-print-directory vault-up
	@$(MAKE) --no-print-directory infra-up
	@$(MAKE) --no-print-directory db-migrate
	@$(MAKE) --no-print-directory backend-up

down: ## Bring down all Durin stacks
	@for stack in ui backend observability identity infra vault; do \
		./scripts/compose.sh "$$stack" down 2>/dev/null || true; \
	done

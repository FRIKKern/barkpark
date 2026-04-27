.PHONY: rebuild restart status logs seed setup dev clean tui api domain-cutover precheck web web-build hooks format format-check

SSH_HOST ?= root@89.167.28.206
PROD_APP_DIR ?= /opt/barkpark

# ── Server operations (run on Hetzner VPS) ───────────────────────────────────

rebuild: ## Rebuild Phoenix + TUI after code changes, restart service
	@echo ">> Cleaning ALL compiled artifacts (prevents stale BEAM)..."
	rm -rf api/_build/prod
	@echo ">> Building Phoenix API..."
	cd api && MIX_ENV=prod mix deps.get && mix deps.compile --force && mix compile
	@echo ">> Building Go TUI..."
	go mod tidy && go build -o bin/barkpark .
	@echo ">> Restarting service..."
	sudo systemctl restart barkpark
	@echo ">> Done. Check: make status"

restart: ## Restart the Phoenix service
	sudo systemctl restart barkpark

stop: ## Stop the Phoenix service
	sudo systemctl stop barkpark

status: ## Show service status
	@systemctl status barkpark --no-pager || true

logs: ## Tail Phoenix service logs
	@journalctl -u barkpark -f --no-pager

seed: ## Re-seed the database
	cd api && MIX_ENV=prod mix run priv/repo/seeds.exs

migrate: ## Run database migrations
	cd api && MIX_ENV=prod mix ecto.migrate

reset-db: ## Drop, recreate, migrate, and seed the database
	cd api && MIX_ENV=prod mix ecto.reset

# ── Local development ────────────────────────────────────────────────────────

dev: ## Start tmux dev session (CC + TUI + Phoenix)
	./dev.sh

api: ## Start Phoenix API locally (dev mode)
	cd api && mix phx.server

tui: ## Build and run the Go TUI locally
	go run .

web: ## Start the Next.js Vercel demo (web/) locally on :3000
	cd web && pnpm dev

web-build: ## Build the Next.js Vercel demo (web/) for production
	cd web && pnpm build

run: ## Start Phoenix (if needed) and run TUI
	./run.sh

build: ## Build Go TUI binary
	go build -o bin/barkpark .

clean: ## Remove build artifacts
	rm -rf bin/ tmp/
	cd api && rm -rf _build/

# ── Docker (alternative to native) ──────────────────────────────────────────

docker-build: ## Build Docker containers
	docker compose build

docker-up: ## Start Docker containers
	docker compose up -d

docker-down: ## Stop Docker containers
	docker compose down

docker-logs: ## Tail Docker logs
	docker compose logs -f

deploy: ## Pull latest from GitHub, rebuild, restart (one command)
	git pull
	rm -rf api/_build/prod
	cd api && MIX_ENV=prod mix deps.get && mix deps.compile --force && mix compile
	go mod tidy && go build -o bin/barkpark .
	sudo systemctl restart barkpark
	@echo ">> Deployed. Waiting for API..."
	@sleep 10
	@curl -s --max-time 5 http://localhost:4000/api/schemas > /dev/null && echo ">> API is live!" || echo ">> Still warming up, check: make logs"

# ── Domain cutover (prod env-only change, no code redeploy) ──────────────────
# Safely update PHX_HOST/PHX_SCHEME on the running prod server and restart.
# Does NOT rebuild or redeploy code. Does NOT touch Caddy, DNS, or secrets.
# See docs/ops/studio-nav-bug-2026-04-19.md for why this exists (task #11).

domain-cutover: ## Update prod PHX_HOST=<DOMAIN> + PHX_SCHEME=https, restart, verify
	@if [ -z "$(DOMAIN)" ]; then \
	  echo "ERROR: DOMAIN is required."; \
	  echo "  Usage: make domain-cutover DOMAIN=api.barkpark.cloud"; \
	  echo "  See docs/ops/studio-nav-bug-2026-04-19.md (task #11)."; \
	  exit 2; \
	fi
	@echo ">> Updating $(SSH_HOST):$(PROD_APP_DIR)/.env — PHX_HOST=$(DOMAIN) PHX_SCHEME=https"
	ssh $(SSH_HOST) 'cd $(PROD_APP_DIR) && cp .env .env.bak.$$(date +%s) && sed -i "s|^PHX_HOST=.*|PHX_HOST=$(DOMAIN)|" .env && { grep -q "^PHX_SCHEME=" .env || echo "PHX_SCHEME=https" >> .env; }'
	@echo ">> Restarting barkpark.service"
	ssh $(SSH_HOST) 'systemctl restart barkpark.service && sleep 3 && systemctl is-active barkpark.service'
	@echo ">> Last 20 log lines"
	ssh $(SSH_HOST) 'journalctl -u barkpark -n 20 --no-pager'
	@echo ">> Verify Studio HTTP (expect 200)"
	curl -sI https://$(DOMAIN)/studio/production | head -5
	@echo ">> Verify WebSocket (must NOT be 403)"
	curl -sI -H 'Origin: https://$(DOMAIN)' -H 'Upgrade: websocket' -H 'Connection: Upgrade' -H 'Sec-WebSocket-Key: test' -H 'Sec-WebSocket-Version: 13' https://$(DOMAIN)/live/websocket | head -5

# ── Pre-merge gate ───────────────────────────────────────────────────────────
# Mirrors .github/workflows/elixir.yml `mix-prod-compile`. Run before pushing.
# See docs/ops/merge-gates.md for the full rationale (PR #42 lessons-learned).

precheck: ## Run the prod-compile merge gate locally (mirrors CI)
	@echo ">> Pre-merge gate: clean prod build + warnings-as-errors compile"
	rm -rf api/_build/prod
	cd api && MIX_ENV=prod mix deps.get && \
	  MIX_ENV=prod mix deps.compile --force && \
	  MIX_ENV=prod mix compile --warnings-as-errors
	@echo ">> precheck OK — safe to push"

# ── Format enforcement ───────────────────────────────────────────────────────
# See .githooks/pre-commit + .github/workflows/elixir.yml `format` job.
# Task #29 — eliminate recurring "mix format pass" hotfixes (PR #58, #59).

hooks: ## Install repo hooks (.githooks/) into git config — enables pre-commit format check
	git config core.hooksPath .githooks
	@echo ">> core.hooksPath=.githooks — pre-commit format check active."
	@echo "   Bypass with: git commit --no-verify (CI will still block the PR)."

format: ## Run mix format on api/ (writes changes)
	cd api && mix format

format-check: ## Run mix format --check-formatted on api/ (read-only, mirrors CI gate)
	cd api && mix format --check-formatted

# ── Setup ────────────────────────────────────────────────────────────────────

setup: ## First-time setup on a fresh server (run deploy.sh instead)
	@echo "Run: ssh root@YOUR_VPS 'bash -s' < deploy.sh"

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help

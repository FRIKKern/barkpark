.PHONY: rebuild restart status logs seed setup dev clean tui api

# ── Server operations (run on Hetzner VPS) ───────────────────────────────────

rebuild: ## Rebuild Phoenix + TUI after code changes, restart service
	@echo ">> Cleaning ALL compiled artifacts (prevents stale BEAM)..."
	rm -rf api/_build/prod
	@echo ">> Building Phoenix API..."
	cd api && MIX_ENV=prod mix deps.get && mix deps.compile --force && mix compile
	@echo ">> Building Go TUI..."
	go mod tidy && go build -o bin/barkpark .
	@echo ">> Restarting service..."
	sudo systemctl restart barkpark-cms
	@echo ">> Done. Check: make status"

restart: ## Restart the Phoenix service
	sudo systemctl restart barkpark-cms

stop: ## Stop the Phoenix service
	sudo systemctl stop barkpark-cms

status: ## Show service status
	@systemctl status barkpark-cms --no-pager || true

logs: ## Tail Phoenix service logs
	@journalctl -u barkpark-cms -f --no-pager

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

# ── Setup ────────────────────────────────────────────────────────────────────

setup: ## First-time setup on a fresh server (run deploy.sh instead)
	@echo "Run: ssh root@YOUR_VPS 'bash -s' < deploy.sh"

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help

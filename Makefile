.PHONY: deploy rebuild restart status logs seed setup dev update clean tui api domain-cutover precheck web web-build hooks format format-check cli-build cli-release cli-checksums cli-assets-sync cli-assets-check provisioner-catalog-sync

SSH_HOST ?= root@89.167.28.206
PROD_APP_DIR ?= /opt/barkpark

# ── Server operations (run on Hetzner VPS) ───────────────────────────────────

rebuild: ## Rebuild Phoenix + TUI after code changes, restart service
	@echo ">> Cleaning ALL compiled artifacts (prevents stale BEAM)..."
	rm -rf api/_build/prod
	@echo ">> Building Phoenix API..."
	cd api && MIX_ENV=prod mix deps.get && mix deps.compile --force && mix compile
	@echo ">> Building Go TUI..."
	go mod tidy && go build -o bin/barkpark-tui ./cmd/barkpark
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
	cd api && bash start.sh mix run priv/repo/seeds.exs

migrate: ## Run database migrations
	cd api && bash start.sh mix ecto.migrate

reset-db: ## Drop, recreate, migrate, and seed the database
	cd api && bash start.sh mix ecto.reset

# ── Local development ────────────────────────────────────────────────────────

dev: ## Start tmux dev session (CC + TUI + Phoenix)
	./dev.sh

update: ## LOCAL: pull + rebuild bp + deps + migrations + digest of what changed
	@bash scripts/local-update.sh

api: ## Start Phoenix API locally (dev mode)
	cd api && mix phx.server

tui: ## Build and run the Go TUI locally
	go run ./cmd/barkpark

web: ## Start the Next.js Vercel demo (web/) locally on :3000
	cd web && pnpm dev

web-build: ## Build the Next.js Vercel demo (web/) for production
	cd web && pnpm build

run: ## Start Phoenix (if needed) and run TUI
	./run.sh

build: ## Build Go TUI binary
	@# bin/barkpark is the TRACKED personal-local launcher script — the compiled
	@# TUI must NOT share its name (go build refuses to overwrite a non-binary).
	go build -o bin/barkpark-tui ./cmd/barkpark

clean: ## Remove build artifacts
	rm -rf bin/ tmp/
	cd api && rm -rf _build/

# ── bp CLI release (M4 GA) ───────────────────────────────────────────────────
# Cross-compile the single `bp` binary (root package main: CLI + TUI) for the
# four supported targets into dist/. dist/ is gitignored — these are build
# artifacts consumed by scripts/install-cli.sh (curl|sh installer) and the
# cli-release.yml workflow (cli-v* tags).
# -s -w strips symbol tables + DWARF; -trimpath strips builder paths from
# panics; CGO_ENABLED=0 keeps cross-compiles static (dep tree is pure Go).
# VERSION/COMMIT/DATE are injected into internal/cli via -ldflags -X — plain
# `go build` stays "dev".

VERSION ?= dev
COMMIT  ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
DATE    ?= $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
MODULE  := github.com/FRIKKern/barkpark
GOFLAGS_RELEASE := -trimpath
LDFLAGS := -s -w \
  -X $(MODULE)/internal/cli.cliVersion=$(VERSION) \
  -X $(MODULE)/internal/cli.cliCommit=$(COMMIT) \
  -X $(MODULE)/internal/cli.cliDate=$(DATE)
CLI_TARGETS := bp-darwin-arm64 bp-darwin-amd64 bp-linux-arm64 bp-linux-amd64 bp-windows-amd64.exe bp-windows-arm64.exe

# deploy.sh is go:embedded into bp (internal/cli/setup/assets/) so a
# curl-installed binary can deploy without a checkout. The canonical script
# stays at the repo root; sync copies it in before every build, and check is
# the CI drift guard (cli-release.yml runs it against the committed asset).
cli-assets-sync: ## Sync deploy.sh into the go:embed asset (internal/cli/setup/assets/)
	cp deploy.sh internal/cli/setup/assets/deploy.sh

cli-assets-check: ## Fail when the embedded deploy.sh drifted from the repo-root copy
	cmp deploy.sh internal/cli/setup/assets/deploy.sh

# The deploy templates (templates/<name>/) are go:embedded into the provisioner
# (internal/provisioner/catalog/templates/) for the dwb-4 content bootstrap.
# The canonical files stay at the repo root; sync re-copies the manifest +
# schemas + seed per template, and TestEmbeddedCatalogMatchesRepoRoot is the
# per-test-run drift guard.
provisioner-catalog-sync: ## Sync deploy templates into the provisioner's go:embed catalog
	@for t in place-directory website-starter blog-starter; do \
	  mkdir -p internal/provisioner/catalog/templates/$$t/schemas; \
	  cp templates/$$t/barkpark.template.json internal/provisioner/catalog/templates/$$t/; \
	  cp templates/$$t/schemas/*.json internal/provisioner/catalog/templates/$$t/schemas/; \
	  cp templates/$$t/seed-*.json internal/provisioner/catalog/templates/$$t/ 2>/dev/null || true; \
	done
	@echo ">> provisioner catalog synced"

# The DEPLOYABLE app trees (js/packages/create-barkpark-app/templates/<slug>/)
# are vendored into the control plane (cloud/priv/templates/) so the gh-3
# "Create GitHub repo" flow can push a template's Next.js app into the user's
# repo — cloud/Dockerfile COPYs only lib/ priv/ config/, so the js/ source is
# NOT reachable at run time. The canonical files stay under create-barkpark-app;
# sync re-copies each app tree byte-for-byte, and
# BarkparkCloud.Templates.AppFilesDriftTest is the per-test-run drift guard.
# Only templates that ship a deployable app (create-barkpark-app AVAILABLE_TEMPLATES
# = website-starter, blog-starter) are vendored — place-directory has no app tree.
cloud-templates-sync: ## Vendor the deployable app trees into the control plane (cloud/priv/templates)
	@for t in website-starter blog-starter; do \
	  rm -rf cloud/priv/templates/$$t; \
	  mkdir -p cloud/priv/templates/$$t; \
	  ( cd js/packages/create-barkpark-app/templates/$$t && find . -type f -print0 ) \
	    | ( cd js/packages/create-barkpark-app/templates/$$t; while IFS= read -r -d '' f; do \
	          mkdir -p "$(CURDIR)/cloud/priv/templates/$$t/$$(dirname "$$f")"; \
	          cp "$$f" "$(CURDIR)/cloud/priv/templates/$$t/$$f"; \
	        done ); \
	done
	@echo ">> control-plane app templates synced"

cli-build: cli-assets-sync ## Build native bp binary into dist/ (this host's GOOS/GOARCH)
	@echo ">> Building native bp $(VERSION) -> dist/bp..."
	CGO_ENABLED=0 go build $(GOFLAGS_RELEASE) -ldflags "$(LDFLAGS)" -o dist/bp ./cmd/barkpark
	@echo ">> Done: dist/bp"

cli-release: cli-assets-sync ## Cross-compile bp for darwin/linux/windows × arm64/amd64 into dist/
	@echo ">> Cross-compiling bp $(VERSION) for 6 targets into dist/..."
	CGO_ENABLED=0 GOOS=darwin  GOARCH=arm64 go build $(GOFLAGS_RELEASE) -ldflags "$(LDFLAGS)" -o dist/bp-darwin-arm64 ./cmd/barkpark
	CGO_ENABLED=0 GOOS=darwin  GOARCH=amd64 go build $(GOFLAGS_RELEASE) -ldflags "$(LDFLAGS)" -o dist/bp-darwin-amd64 ./cmd/barkpark
	CGO_ENABLED=0 GOOS=linux   GOARCH=arm64 go build $(GOFLAGS_RELEASE) -ldflags "$(LDFLAGS)" -o dist/bp-linux-arm64 ./cmd/barkpark
	CGO_ENABLED=0 GOOS=linux   GOARCH=amd64 go build $(GOFLAGS_RELEASE) -ldflags "$(LDFLAGS)" -o dist/bp-linux-amd64 ./cmd/barkpark
	CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build $(GOFLAGS_RELEASE) -ldflags "$(LDFLAGS)" -o dist/bp-windows-amd64.exe ./cmd/barkpark
	CGO_ENABLED=0 GOOS=windows GOARCH=arm64 go build $(GOFLAGS_RELEASE) -ldflags "$(LDFLAGS)" -o dist/bp-windows-arm64.exe ./cmd/barkpark
	@echo ">> Done. Artifacts:"
	@ls -lh dist/bp-*

cli-checksums: ## Write dist/checksums.txt (sha256 of the 4 release binaries)
	@echo ">> Writing dist/checksums.txt..."
	cd dist && { command -v sha256sum >/dev/null 2>&1 && sha256sum $(CLI_TARGETS) || shasum -a 256 $(CLI_TARGETS); } > checksums.txt
	@cat dist/checksums.txt

# ── Docker (alternative to native) ──────────────────────────────────────────

docker-build: ## Build Docker containers
	docker compose build

docker-up: ## Start Docker containers
	docker compose up -d

docker-down: ## Stop Docker containers
	docker compose down

docker-logs: ## Tail Docker logs
	docker compose logs -f

deploy: ## Deploy: pull main — the .githooks/post-merge hook does the clean rebuild + restart
	@# The deploy is the `.githooks/post-merge` hook (core.hooksPath=.githooks): it
	@# sources asdf+.env, `rm -rf api/_build/prod`, recompiles, restarts the service,
	@# then rebuilds the Go TUI. So `git pull` IS the deploy. This recipe used to
	@# DUPLICATE that (a second rm+compile+restart) — and broke when run via
	@# non-interactive ssh because `mix` is off the PATH, deleting _build/prod then
	@# failing → a from-scratch restart-recompile = prod downtime. Now we delegate.
	@#
	@# First discard build-artifact modifications that would block the pull: the hook's
	@# `go mod tidy` retidies go.sum, and older hooks built the TUI over the TRACKED
	@# bin/barkpark launcher script (fixed — the TUI now builds to bin/barkpark-tui —
	@# but a server that clobbered it before the fix still needs the restore). The
	@# hook regenerates go.sum, so discarding the server-local versions is safe.
	-@git checkout -- bin/barkpark bin/barkpark-pg go.sum 2>/dev/null
	git pull
	@echo ">> Pulled. .githooks/post-merge cleaned _build/prod, recompiled, and restarted."
	@sleep 8
	@curl -s --max-time 5 http://localhost:4000/api/schemas > /dev/null && echo ">> API is live!" || echo ">> Warming up — check: make logs"

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
	curl -sIL https://$(DOMAIN)/studio/production | head -8
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

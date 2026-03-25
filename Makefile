.DEFAULT_GOAL := help

SERVER_DIR := loomkin-server
MOBILE_DIR := apps/mobile
DESKTOP_DIR := apps/desktop
CLI_DIR := apps/cli

.PHONY: help setup dev self-edit test format db.up db.down db.reset dev.up dev.down \
	mobile.dev mobile.ios mobile.android mobile.test \
	desktop.dev desktop.build \
	cli.dev cli.build cli.test cli.type cli.lint cli.fmt \
	mobile.e2e.build mobile.e2e.seed mobile.e2e.ios mobile.e2e.android

help:          ## Show available targets
	@grep -E '^[a-zA-Z_.-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

setup:         ## Install all dependencies and configure the project
	brew bundle
	localias start
	mise install
	pnpm install
	lefthook install
	$(MAKE) db.up
	cd $(SERVER_DIR) && mix setup
	@echo ""
	@echo "If mise-managed tools are not active, add this to your shell config (~/.zshrc or ~/.bashrc):"
	@echo "  eval \"\$$(mise activate zsh)\"   # zsh"
	@echo "  eval \"\$$(mise activate bash)\"  # bash"
	@echo "Then open a new terminal or run: eval \"\$$(mise activate zsh)\""

dev:           ## Start the dev server
	cd $(SERVER_DIR) && mix phx.server

self-edit:     ## Start in self-edit mode (code reloader off for agent edits)
	cd $(SERVER_DIR) && LOOMKIN_SELF_EDIT=1 mix phx.server

test:          ## Run the test suite
	cd $(SERVER_DIR) && mix test

format:        ## Format Elixir source files
	cd $(SERVER_DIR) && mix format

db.up:         ## Start the Postgres container
	docker compose up -d --wait

db.down:       ## Stop the Postgres container
	docker compose down

db.reset:      ## Reset the database (drop, create, migrate, seed)
	cd $(SERVER_DIR) && mix ecto.reset

dev.up:   ## Start the shared dev container
	docker compose -f .devcontainer/docker-compose.yml up -d --build

dev.down: ## Stop the shared dev container
	docker compose -f .devcontainer/docker-compose.yml down

# ── Mobile ─────────────────────────────────────────────────────────────

mobile.dev:    ## Start Expo dev server
	cd $(MOBILE_DIR) && pnpm start

mobile.ios:    ## Run mobile app on iOS simulator
	cd $(MOBILE_DIR) && pnpm ios

mobile.android: ## Run mobile app on Android emulator
	cd $(MOBILE_DIR) && pnpm android

mobile.test:   ## Run mobile unit tests
	cd $(MOBILE_DIR) && pnpm test

# ── Desktop ────────────────────────────────────────────────────────────

desktop.dev:   ## Start Tauri desktop in dev mode
	cd $(DESKTOP_DIR) && pnpm tauri:dev

desktop.build: ## Build Tauri desktop app
	cd $(DESKTOP_DIR) && pnpm tauri:build

# ── CLI ────────────────────────────────────────────────────────────────

cli.dev:       ## Start CLI TUI in dev mode
	cd $(CLI_DIR) && bun run dev

cli.build:     ## Build CLI for distribution
	cd $(CLI_DIR) && bun run build

cli.test:      ## Run CLI tests
	cd $(CLI_DIR) && bun run test

cli.type:      ## Type-check CLI source files
	cd $(CLI_DIR) && pnpm typecheck

cli.lint:      ## Lint CLI source files
	cd $(CLI_DIR) && pnpm lint

cli.fmt:       ## Format CLI source files
	cd $(CLI_DIR) && pnpm fmt

# ── E2E ────────────────────────────────────────────────────────────────

mobile.e2e.build: ## Build Expo dev client for e2e
	cd $(MOBILE_DIR) && bash e2e/scripts/build-dev-client.sh

mobile.e2e.seed: ## Seed backend with e2e test data
	cd $(SERVER_DIR) && mix run priv/repo/seeds/e2e_seeds.exs

mobile.e2e.ios: ## Run Maestro e2e tests on iOS
	cd $(MOBILE_DIR) && bash e2e/scripts/run-maestro-ios.sh

mobile.e2e.android: ## Run Maestro e2e tests on Android
	cd $(MOBILE_DIR) && bash e2e/scripts/run-maestro-android.sh

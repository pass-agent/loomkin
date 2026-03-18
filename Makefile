.DEFAULT_GOAL := help

.PHONY: help setup dev self-edit test format db.up db.down db.reset dev.up dev.down

help:          ## Show available targets
	@grep -E '^[a-zA-Z_.-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

setup:         ## Install all dependencies and configure the project
	brew bundle
	localias start
	mise install
	npm install
	lefthook install
	$(MAKE) db.up
	mix setup
	@echo ""
	@echo "If mise-managed tools are not active, add this to your shell config (~/.zshrc or ~/.bashrc):"
	@echo "  eval \"\$$(mise activate zsh)\"   # zsh"
	@echo "  eval \"\$$(mise activate bash)\"  # bash"
	@echo "Then open a new terminal or run: eval \"\$$(mise activate zsh)\""

dev:           ## Start the dev server
	mix phx.server

self-edit:     ## Start in self-edit mode (code reloader off for agent edits)
	LOOMKIN_SELF_EDIT=1 mix phx.server

test:          ## Run the test suite
	mix test

format:        ## Format Elixir source files
	mix format

db.up:         ## Start the Postgres container
	docker compose up -d --wait

db.down:       ## Stop the Postgres container
	docker compose down

db.reset:      ## Reset the database (drop, create, migrate, seed)
	mix ecto.reset

dev.up:   ## Start the shared dev container
	docker compose -f .devcontainer/docker-compose.yml up -d --build

dev.down: ## Stop the shared dev container
	docker compose -f .devcontainer/docker-compose.yml down


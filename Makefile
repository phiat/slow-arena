.PHONY: help setup deps db db.stop db.reset server iex test cli format lint clean

help: ## Show help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

setup: deps db ## Full project setup
	mix compile

deps: ## Fetch dependencies
	mix deps.get

db: ## Start SurrealDB via Docker
	docker compose up -d surrealdb
	@echo "Waiting for SurrealDB..."
	@sleep 2
	@echo "SurrealDB ready at http://localhost:8000"

db.stop: ## Stop SurrealDB
	docker compose down

db.reset: ## Reset SurrealDB data
	docker compose down -v
	$(MAKE) db

db.seed: ## Seed database with game data
	mix run priv/seeds/seed.exs

server: ## Start Phoenix server
	mix phx.server

iex: ## Start IEx with Phoenix
	iex -S mix phx.server

test: ## Run tests
	mix test

test.watch: ## Run tests in watch mode
	mix test --stale --listen-on-stdin

cli: ## Open game CLI
	mix game.cli

cli.status: ## Show game engine status
	mix game.status

format: ## Format code
	mix format

lint: ## Run code checks
	mix format --check-formatted

clean: ## Clean build artifacts
	mix clean
	rm -rf _build deps

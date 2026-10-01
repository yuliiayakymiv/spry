-include .env

COMPOSE := docker compose
DB_PORT ?= 5432
LOCAL_DATABASE_URL := $(subst @db:5432,@localhost:$(DB_PORT),$(DATABASE_URL))
s ?=

.DEFAULT_GOAL := help
.PHONY: help env build up down restart logs ps migrate migration seed psql test lint format \
	dev-backend dev-frontend install clean

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(firstword $(MAKEFILE_LIST)) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

env: ## Create .env from .env.example if missing
	@test -f .env || (cp .env.example .env && echo "Created .env")

build: env ## Build all images
	$(COMPOSE) build

up: env ## Build and start the whole stack
	$(COMPOSE) up -d --build
	@echo "App:      http://localhost:3000"
	@echo "API docs: http://localhost:8000/api/docs"

down: ## Stop the stack
	$(COMPOSE) down

restart: down up ## Restart the stack

logs: ## Follow logs (optionally: make logs s=backend)
	$(COMPOSE) logs -f $(s)

ps: ## Show running services
	$(COMPOSE) ps

migrate: ## Apply database migrations
	$(COMPOSE) exec backend alembic upgrade head

migration: ## Generate a migration: make migration m="add something" (db must be up)
	@test -n "$(m)" || (echo 'Usage: make migration m="message"' && exit 1)
	cd backend && DATABASE_URL=$(LOCAL_DATABASE_URL) uv run alembic revision --autogenerate -m "$(m)"

seed: ## Insert sample participants and meetings
	$(COMPOSE) exec backend python -m app.seed

psql: ## Open psql in the db container
	$(COMPOSE) exec db psql -U $(POSTGRES_USER) -d $(POSTGRES_DB)

test: ## Run backend tests (against the <db>_test database)
	$(COMPOSE) exec backend pytest -v

lint: ## Lint backend and frontend
	cd backend && uv run ruff check . && uv run ruff format --check .
	cd frontend && npm run lint && npx prettier --check .

format: ## Format backend and frontend
	cd backend && uv run ruff check --fix . && uv run ruff format .
	cd frontend && npm run format

install: ## Install local dev dependencies (uv + npm)
	cd backend && uv sync
	cd frontend && npm install

dev-backend: env ## Run backend locally with reload (db runs in Docker)
	$(COMPOSE) up -d db
	cd backend && DATABASE_URL=$(LOCAL_DATABASE_URL) uv run alembic upgrade head
	cd backend && DATABASE_URL=$(LOCAL_DATABASE_URL) uv run uvicorn app.main:app --reload --port 8000

dev-frontend: ## Run Vite dev server on http://localhost:5173 (proxies /api to :8000)
	cd frontend && npm run dev

clean: ## Stop the stack and delete the database volume
	$(COMPOSE) down -v

# ---------------------------------------------------------------------------
# Deploy to AWS — the deploy contract. GitHub Actions runs exactly these targets.
# On Windows run them from Git Bash (needs make, jq, node, docker, aws in PATH).
# Credentials: `aws configure` locally, OIDC in CI. Never in this file or in .env.
# ---------------------------------------------------------------------------
AWS_REGION      ?= eu-central-1
ECR_REPOSITORY  ?= spry-backend
ECS_CLUSTER     ?= spry
ECS_SERVICE     ?= spry-backend
ECS_TASK_FAMILY ?= spry-backend
CONTAINER_NAME  ?= spry-backend
S3_BUCKET       ?=
CLOUDFRONT_DISTRIBUTION_ID ?=
VITE_API_URL    ?=
# Tag images with the commit SHA, never "latest": you always know what is running,
# and a rollback is "deploy the previous tag".
IMAGE_TAG       ?= $(shell git rev-parse HEAD)

DEPLOY_ENV := AWS_REGION="$(AWS_REGION)" ECR_REPOSITORY="$(ECR_REPOSITORY)" \
	ECS_CLUSTER="$(ECS_CLUSTER)" ECS_SERVICE="$(ECS_SERVICE)" ECS_TASK_FAMILY="$(ECS_TASK_FAMILY)" \
	CONTAINER_NAME="$(CONTAINER_NAME)" IMAGE_TAG="$(IMAGE_TAG)" S3_BUCKET="$(S3_BUCKET)" \
	CLOUDFRONT_DISTRIBUTION_ID="$(CLOUDFRONT_DISTRIBUTION_ID)" VITE_API_URL="$(VITE_API_URL)"

.PHONY: deploy-backend release-backend rollback-backend deploy-frontend

deploy-backend: ## Build image, push to ECR as :<commit sha>, roll the ECS service
	$(DEPLOY_ENV) bash infra/aws/deploy-backend.sh

release-backend: ## Point ECS at an image already in ECR (IMAGE_TAG=<sha>)
	$(DEPLOY_ENV) bash infra/aws/release-backend.sh

rollback-backend: ## Redeploy an earlier image, no rebuild: make rollback-backend TAG=<sha>
	@test -n "$(TAG)" || (echo 'Usage: make rollback-backend TAG=<commit-sha>' && exit 1)
	$(MAKE) release-backend IMAGE_TAG=$(TAG)

deploy-frontend: ## Build with VITE_API_URL, sync to S3, invalidate CloudFront
	$(DEPLOY_ENV) bash infra/aws/deploy-frontend.sh

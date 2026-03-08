.PHONY: help build up down clean logs test status shell rebuild jobs quick-test version set-version build-all test-version test-all

.DEFAULT_GOAL := help

SUPPORTED_VERSIONS := 24.11.7 25.05.6 25.11.2
DEFAULT_VERSION := 25.11.2

CYAN := $(shell tput -Txterm setaf 6)
RESET := $(shell tput -Txterm sgr0)

help:  ## Show this help message
	@echo "Slurm Docker (All-in-One) - Available Commands"
	@echo "==============================================="
	@echo ""
	@echo "Cluster Management:"
	@printf "  ${CYAN}%-15s${RESET} %s\n" "build" "Build Docker image"
	@printf "  ${CYAN}%-15s${RESET} %s\n" "up" "Start container"
	@printf "  ${CYAN}%-15s${RESET} %s\n" "down" "Stop container"
	@printf "  ${CYAN}%-15s${RESET} %s\n" "clean" "Remove container and volumes"
	@printf "  ${CYAN}%-15s${RESET} %s\n" "rebuild" "Clean, rebuild, and start"
	@echo ""
	@echo "Quick Commands:"
	@printf "  ${CYAN}%-15s${RESET} %s\n" "shell" "Open shell in container"
	@printf "  ${CYAN}%-15s${RESET} %s\n" "status" "Show cluster status"
	@printf "  ${CYAN}%-15s${RESET} %s\n" "jobs" "View job queue"
	@printf "  ${CYAN}%-15s${RESET} %s\n" "quick-test" "Submit a quick test job"
	@printf "  ${CYAN}%-15s${RESET} %s\n" "logs" "Show container logs"
	@echo ""
	@echo "Testing:"
	@printf "  ${CYAN}%-15s${RESET} %s\n" "test" "Run test suite"
	@printf "  ${CYAN}%-15s${RESET} %s\n" "test-version" "Test specific version (VER=...)"
	@printf "  ${CYAN}%-15s${RESET} %s\n" "test-all" "Test all supported versions"
	@echo ""
	@echo "Multi-Version:"
	@printf "  ${CYAN}%-15s${RESET} %s\n" "version" "Show current Slurm version"
	@printf "  ${CYAN}%-15s${RESET} %s\n" "set-version" "Set Slurm version (VER=...)"
	@printf "  ${CYAN}%-15s${RESET} %s\n" "build-all" "Build all supported versions"
	@echo ""
	@echo "Examples:"
	@echo "  make set-version VER=24.11.7"
	@echo "  make test-version VER=25.05.6"

build:  ## Build Docker image
	docker compose --progress plain build

up:  ## Start container
	docker compose up -d

down:  ## Stop container
	docker compose down

clean:  ## Remove container and volumes
	docker compose down -v

logs:  ## Show container logs
	docker compose logs -f

test:  ## Run test suite
	./test_cluster.sh

status:  ## Show cluster status
	@echo "=== Container ==="
	@docker compose ps
	@echo ""
	@echo "=== Cluster ==="
	@docker exec slurm sinfo 2>/dev/null || echo "Not ready"

shell:  ## Open shell in container
	docker exec -it slurm bash

quick-test:  ## Submit a quick test job
	docker exec slurm bash -c "cd /data && sbatch --wrap='hostname' && sleep 3 && squeue && cat slurm-*.out 2>/dev/null | tail -5"

jobs:  ## View job queue
	docker exec slurm squeue

version:  ## Show current Slurm version
	@if [ -f .env ]; then \
		grep SLURM_VERSION .env || echo "SLURM_VERSION not set (default: $(DEFAULT_VERSION))"; \
	else \
		echo "No .env file (default: $(DEFAULT_VERSION))"; \
	fi

set-version:  ## Set Slurm version (usage: make set-version VER=24.11.7)
	@if [ -z "$(VER)" ]; then \
		echo "Usage: make set-version VER=24.11.7"; \
		echo "Supported: $(SUPPORTED_VERSIONS)"; \
		exit 1; \
	fi
	@echo "SLURM_VERSION=$(VER)" > .env
	@echo "Set SLURM_VERSION=$(VER) — run 'make rebuild' to apply"

build-all:  ## Build images for all supported versions
	@for version in $(SUPPORTED_VERSIONS); do \
		echo ""; \
		echo "======== Building Slurm $$version ========"; \
		echo "SLURM_VERSION=$$version" > .env; \
		docker compose build || exit 1; \
		echo "Built slurm-docker:$$version"; \
	done
	@echo ""
	@echo "All versions built"

test-version:  ## Test a specific version (usage: make test-version VER=24.11.7)
	@if [ -z "$(VER)" ]; then \
		echo "Usage: make test-version VER=24.11.7"; \
		echo "Supported: $(SUPPORTED_VERSIONS)"; \
		exit 1; \
	fi
	@echo "======== Testing Slurm $(VER) ========"
	@echo "SLURM_VERSION=$(VER)" > .env
	@$(MAKE) clean
	@docker compose up -d
	@echo "Waiting for services to start..."
	@sleep 30
	@./test_cluster.sh
	@$(MAKE) clean

test-all:  ## Test all supported versions
	@for version in $(SUPPORTED_VERSIONS); do \
		$(MAKE) test-version VER=$$version || exit 1; \
	done
	@echo ""
	@echo "All version tests passed"

rebuild: clean build up

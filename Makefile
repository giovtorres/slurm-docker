.PHONY: help build up down clean logs test status shell rebuild jobs quick-test version set-version set-os build-all test-version test-all

.DEFAULT_GOAL := help

SUPPORTED_VERSIONS := 24.11.7 25.05.7 25.11.4
DEFAULT_VERSION := 25.11.4

SUPPORTED_ROCKY_VERSIONS := 8 9 10
DEFAULT_ROCKY_VERSION := 10
ROCKY_VERSION ?= $(DEFAULT_ROCKY_VERSION)

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
	@printf "  ${CYAN}%-15s${RESET} %s\n" "set-os" "Set Rocky Linux version (OS=8|9|10)"
	@printf "  ${CYAN}%-15s${RESET} %s\n" "build-all" "Build all version/OS combinations"
	@echo ""
	@echo "Examples:"
	@echo "  make set-version VER=24.11.7"
	@echo "  make set-os OS=9"
	@echo "  make test-version VER=25.05.7 OS=9"

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
	@CURRENT_OS=$$(grep ROCKY_VERSION .env 2>/dev/null | cut -d= -f2 || echo $(DEFAULT_ROCKY_VERSION)); \
	 echo "SLURM_VERSION=$(VER)" > .env; \
	 echo "ROCKY_VERSION=$$CURRENT_OS" >> .env
	@echo "Set SLURM_VERSION=$(VER) — run 'make rebuild' to apply"

set-os:  ## Set Rocky Linux version (usage: make set-os OS=9)
	@if [ -z "$(OS)" ]; then \
		echo "Usage: make set-os OS=9"; \
		echo "Supported: $(SUPPORTED_ROCKY_VERSIONS)"; \
		exit 1; \
	fi
	@CURRENT_VER=$$(grep SLURM_VERSION .env 2>/dev/null | cut -d= -f2 || echo $(DEFAULT_VERSION)); \
	 echo "SLURM_VERSION=$$CURRENT_VER" > .env; \
	 echo "ROCKY_VERSION=$(OS)" >> .env
	@echo "Set ROCKY_VERSION=$(OS) — run 'make rebuild' to apply"

build-all:  ## Build images for all supported version/OS combinations
	@for version in $(SUPPORTED_VERSIONS); do \
		for os in $(SUPPORTED_ROCKY_VERSIONS); do \
			echo ""; \
			echo "======== Building Slurm $$version on RL$$os ========"; \
			printf 'SLURM_VERSION=%s\nROCKY_VERSION=%s\n' $$version $$os > .env; \
			docker compose build || exit 1; \
			echo "Built slurm-docker:$$version-rl$$os"; \
		done; \
	done
	@echo ""
	@echo "All version/OS combinations built"

test-version:  ## Test a specific version/OS combo (usage: make test-version VER=24.11.7 OS=9)
	@if [ -z "$(VER)" ]; then \
		echo "Usage: make test-version VER=24.11.7 [OS=8|9|10]"; \
		echo "Supported versions: $(SUPPORTED_VERSIONS)"; \
		echo "Supported OS: $(SUPPORTED_ROCKY_VERSIONS)"; \
		exit 1; \
	fi
	@echo "======== Testing Slurm $(VER) on RL$(or $(OS),$(DEFAULT_ROCKY_VERSION)) ========"
	@printf 'SLURM_VERSION=%s\nROCKY_VERSION=%s\n' $(VER) $(or $(OS),$(DEFAULT_ROCKY_VERSION)) > .env
	@$(MAKE) clean
	@docker compose up -d
	@echo "Waiting for services to start..."
	@sleep 30
	@./test_cluster.sh
	@$(MAKE) clean

test-all:  ## Test all supported version/OS combinations
	@for version in $(SUPPORTED_VERSIONS); do \
		for os in $(SUPPORTED_ROCKY_VERSIONS); do \
			$(MAKE) test-version VER=$$version OS=$$os || exit 1; \
		done; \
	done
	@echo ""
	@echo "All version/OS tests passed"

rebuild: clean build up

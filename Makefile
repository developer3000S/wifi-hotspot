# WiFi Hotspot Docker Makefile
# Provides convenient commands for building, running, and managing the Docker container

.PHONY: help build run start stop restart shell logs status clean pull test

# Configuration
DOCKER_COMPOSE = docker-compose
DOCKER = docker
CONTAINER_NAME = wifi-hotspot
IMAGE_NAME = wifi-hotspot

# Default action
help:
	@echo "WiFi Hotspot Docker Management"
	@echo "=============================="
	@echo ""
	@echo "Available commands:"
	@echo "  make build          - Build the Docker image"
	@echo "  make run            - Build and run the container"
	@echo "  make start          - Start the container"
	@echo "  make stop           - Stop the container"
	@echo "  make restart        - Restart the container"
	@echo "  make shell          - Open shell in running container"
	@echo "  make logs           - View container logs"
	@echo "  make status         - Show container status"
	@echo "  make clean          - Stop and remove containers"
	@echo "  make pull           - Pull latest base images"
	@echo "  make test           - Run container tests"
	@echo "  make setup          - Setup configurations only"
	@echo "  make init           - Initialize database and configs"
	@echo ""
	@echo "With management profile:"
	@echo "  make run-mgmt       - Run with daloRadius management"
	@echo ""

# Build the Docker image
build:
	$(DOCKER_COMPOSE) build

# Build and run the container
run: build
	$(DOCKER_COMPOSE) up -d
	@echo "Container started. Run 'make logs' to see output."

# Run with management profile (includes daloRadius)
run-mgmt: build
	$(DOCKER_COMPOSE) --profile management up -d
	@echo "Container started with management profile. Run 'make logs' to see output."

# Start the container
start:
	$(DOCKER_COMPOSE) start

# Stop the container
stop:
	$(DOCKER_COMPOSE) stop

# Restart the container
restart:
	$(DOCKER_COMPOSE) restart

# Open shell in running container
shell:
	$(DOCKER_COMPOSE) exec wifi-hotspot /bin/bash

# Alternative shell entry
shell-root:
	$(DOCKER) exec -it $(CONTAINER_NAME) /bin/bash

# View container logs
logs:
	$(DOCKER_COMPOSE) logs -f

# Show container status
status:
	$(DOCKER_COMPOSE) ps
	@echo ""
	$(DOCKER) ps -a

# Stop and remove containers
clean:
	$(DOCKER_COMPOSE) down
	@echo "Containers stopped and removed."

# Pull latest base images
pull:
	$(DOCKER_COMPOSE) pull

# Run tests
test:
	$(DOCKER_COMPOSE) exec wifi-hotspot /usr/local/bin/init-hotspot test

# Setup configurations only
setup:
	$(DOCKER_COMPOSE) exec wifi-hotspot /usr/local/bin/init-hotspot setup

# Initialize database and configs
init:
	$(DOCKER_COMPOSE) exec wifi-hotspot /usr/local/bin/init-hotspot init

# Rebuild completely
rebuild: clean build run

# Create data directories
init-data:
	mkdir -p docker/data/mysql
	mkdir -p docker/data/logs
	mkdir -p docker/data/chilli
	mkdir -p docker/data/hostapd
	mkdir -p docker/data/freeradius
	mkdir -p docker/data/nginx
	mkdir -p docker/data/dnsmasq
	mkdir -p docker/data/daloradius
	@echo "Data directories created."

# Generate SSL certificates for development
gen-ssl:
	@echo "Generating self-signed SSL certificates..."
	mkdir -p docker/config/ssl
	openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
		-keyout docker/config/ssl/snakeoil.key \
		-out docker/config/ssl/snakeoil.pem \
		-subj "/C=US/ST=State/L=City/O=Org/CN=hotspot.example.com"
	@echo "SSL certificates generated."

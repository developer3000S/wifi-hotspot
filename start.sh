#!/bin/bash

# WiFi Hotspot Docker Start Script
# This script removes old containers and images, then starts the project

set -e

echo "=== WiFi Hotspot Docker Setup ==="
echo ""

# Step 1: Stop and remove old containers
echo "[1/5] Stopping and removing old containers..."
docker stop wifi-hotspot daloradius 2>/dev/null || true
docker rm -f wifi-hotspot daloradius 2>/dev/null || true
echo "✓ Old containers removed"
echo ""

# Step 2: Remove old images
echo "[2/5] Removing old images..."
# Get the project image name (built from Dockerfile)
PROJECT_IMAGE=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep -E "wifi-hotspot|${PWD##*/}" | head -1 || true)
if [ -n "$PROJECT_IMAGE" ]; then
    docker rmi -f "$PROJECT_IMAGE" 2>/dev/null || true
    echo "✓ Removed project image: $PROJECT_IMAGE"
fi

# Remove dangling images
docker image prune -f 2>/dev/null || true
echo "✓ Dangling images removed"
echo ""

# Step 3: Remove old volumes and networks
echo "[3/5] Cleaning up old volumes and networks..."
docker compose down -v 2>/dev/null || true
echo "✓ Volumes and networks cleaned"
echo ""

# Step 4: Configure host sysctls (required for network_mode: host)
echo "[4/5] Configuring host network settings..."
sysctl -w net.ipv4.ip_forward=1 2>/dev/null || true
sysctl -w net.ipv4.conf.all.rp_filter=2 2>/dev/null || true
echo "✓ Host network settings configured"
echo ""

# Step 5: Build and start the project
echo "[5/5] Building and starting the project..."
docker compose up -d --build
echo ""
echo "=== Setup Complete ==="
echo "WiFi Hotspot is now running in Docker!"
echo ""
echo "To check status:"
echo "  docker compose ps"
echo ""
echo "To view logs:"
echo "  docker compose logs -f"

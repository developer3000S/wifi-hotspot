#!/bin/bash

# WiFi Hotspot Docker Start Script
# This script removes old containers and images, then starts the project

set -e

echo "=== WiFi Hotspot Docker Setup ==="
echo ""

# Step 1: Stop and remove old containers
echo "[1/6] Stopping and removing old containers..."
docker stop wifi-hotspot daloradius 2>/dev/null || true
docker rm -f wifi-hotspot daloradius 2>/dev/null || true
echo "✓ Old containers removed"
echo ""

# Step 2: Remove old images
echo "[2/6] Removing old images..."
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
echo "[3/6] Cleaning up old volumes and networks..."
docker compose down -v 2>/dev/null || true
echo "✓ Volumes and networks cleaned"
echo ""

# Step 4: Free port 3306 if occupied (required for network_mode: host)
echo "[4/6] Checking port 3306..."
if ss -tlnp | grep -q ':3306'; then
    echo "  Port 3306 is in use, freeing..."
    # Stop systemd mariadb socket/service if active
    systemctl stop mariadb.socket mariadb.service 2>/dev/null || true
    systemctl disable mariadb.socket mariadb.service 2>/dev/null || true
    # Kill any remaining process holding port 3306
    PIDS=$(ss -tlnp | grep ':3306' | grep -oP 'pid=\K[0-9]+' || true)
    if [ -n "$PIDS" ]; then
        echo "  Killing PIDs: $PIDS"
        kill -9 $PIDS 2>/dev/null || true
        sleep 1
    fi
    if ss -tlnp | grep -q ':3306'; then
        echo "✗ ERROR: Could not free port 3306. Please stop the service using it manually."
        exit 1
    fi
    echo "✓ Port 3306 freed"
else
    echo "✓ Port 3306 is free"
fi
echo ""

# Step 5: Configure host sysctls (required for network_mode: host)
echo "[5/6] Configuring host network settings..."
sysctl -w net.ipv4.ip_forward=1 2>/dev/null || true
sysctl -w net.ipv4.conf.all.rp_filter=2 2>/dev/null || true
echo "✓ Host network settings configured"
echo ""

# Step 6: Build and start the project
echo "[6/6] Building and starting the project..."
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

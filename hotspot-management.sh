#!/bin/bash

#########################################################################
# WiFi Hotspot Service Management Script
# Usage: ./hotspot-management.sh {start|stop|restart|status} [service]
#
# Manages WiFi hotspot components: PostgreSQL, FreeRADIUS, dnsmasq, hostapd, nginx, chilli
#########################################################################

# Load configuration from .env file if it exists
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then
    source "$SCRIPT_DIR/.env"
fi

SERVICES=(
    "postgresql"
    "freeradius"
    "dnsmasq"
    "hostapd"
    "nginx"
    "chilli"
)

COMMAND=${1:-}
SERVICE=${2:-}

# Function to check if a service is running
is_running() {
    systemctl is-active --quiet "$1"
}

# Wait until PostgreSQL accepts connections
wait_for_postgres() {
    command -v pg_isready >/dev/null 2>&1 || return 0
    for _ in $(seq 1 30); do
        if pg_isready -h "${DB_HOST:-localhost}" -p "${DB_PORT:-5432}" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    echo "WARNING: PostgreSQL is not ready on ${DB_HOST:-localhost}:${DB_PORT:-5432}"
    return 1
}

# Function to start a service
start_service() {
    if ! is_running "$1"; then
        echo "Starting $1..."
        systemctl start "$1"
        sleep 2
        [ "$1" = "postgresql" ] && wait_for_postgres
        systemctl status "$1" --no-pager 2>&1 | head -n 5
    else
        echo "$1 is already running"
    fi
}

# Function to stop a service
stop_service() {
    if is_running "$1"; then
        echo "Stopping $1..."
        systemctl stop "$1"
        echo "$1 stopped"
    else
        echo "$1 is already stopped"
    fi
}

# Function to restart a service
restart_service() {
    echo "Restarting $1..."
    systemctl restart "$1"
    sleep 2
    [ "$1" = "postgresql" ] && wait_for_postgres
    systemctl status "$1" --no-pager 2>&1 | head -n 5
}

# Function to get detailed status
get_status() {
    systemctl status "$1" --no-pager 2>&1 | head -n 20
}

# Main logic
case "$COMMAND" in
    start)
        if [ -z "$SERVICE" ]; then
            echo "Starting all WiFi hotspot services..."
            echo "========================================"
            for service in "${SERVICES[@]}"; do
                start_service "$service"
                echo ""
            done
            echo "All services started."
        else
            start_service "$SERVICE"
        fi
        ;;
    stop)
        if [ -z "$SERVICE" ]; then
            echo "Stopping all WiFi hotspot services..."
            echo "========================================"
            # Stop in reverse order of dependencies
            for ((i=${#SERVICES[@]}-1; i>=0; i--)); do
                stop_service "${SERVICES[$i]}"
            done
            echo "All services stopped."
        else
            stop_service "$SERVICE"
        fi
        ;;
    restart)
        if [ -z "$SERVICE" ]; then
            echo "Restarting all WiFi hotspot services..."
            echo "========================================"
            for service in "${SERVICES[@]}"; do
                restart_service "$service"
                echo ""
            done
            echo "All services restarted."
        else
            restart_service "$SERVICE"
        fi
        ;;
    status)
        if [ -z "$SERVICE" ]; then
            echo "Status of WiFi hotspot services:"
            echo "=================================="
            for service in "${SERVICES[@]}"; do
                echo "=== Status of $service ==="
                get_status "$service"
                echo ""
            done
        else
            get_status "$SERVICE"
        fi
        ;;
    start-all)
        echo "Starting all services..."
        for service in "${SERVICES[@]}"; do
            start_service "$service"
        done
        ;;
    stop-all)
        echo "Stopping all services..."
        for ((i=${#SERVICES[@]}-1; i>=0; i--)); do
            stop_service "${SERVICES[$i]}"
        done
        ;;
    *)
        echo "WiFi Hotspot Service Manager"
        echo "=============================="
        echo "Usage: $0 {start|stop|restart|status} [service]"
        echo ""
        echo "Available services: ${SERVICES[*]}"
        echo ""
        echo "Examples:"
        echo "  $0 start              # Start all services"
        echo "  $0 stop               # Stop all services"
        echo "  $0 restart            # Restart all services"
        echo "  $0 status             # Check status of all services"
        echo "  $0 start freeradius   # Start specific service"
        echo "  $0 stop nginx         # Stop specific service"
        exit 1
        ;;
esac

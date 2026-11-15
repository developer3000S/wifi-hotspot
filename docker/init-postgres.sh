#!/bin/bash
# PostgreSQL initialization script for WiFi Hotspot

set -e

DB_NAME="${RADIUS_DB_NAME:-radius}"
DB_USER="${RADIUS_DB_USER:-freerad}"
DB_PASSWORD="${RADIUS_DB_PASSWORD:-radtesting123}"

echo "Initializing PostgreSQL databases for WiFi Hotspot..."

# Create or update the RADIUS role
if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1; then
    runuser -u postgres -- psql -c "CREATE ROLE \"$DB_USER\" LOGIN PASSWORD '$DB_PASSWORD';"
else
    runuser -u postgres -- psql -c "ALTER ROLE \"$DB_USER\" WITH LOGIN PASSWORD '$DB_PASSWORD';"
fi

# Create the RADIUS database
if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1; then
    runuser -u postgres -- createdb -O "$DB_USER" "$DB_NAME"
fi

# Import the FreeRADIUS schema
SCHEMA_FILE="/etc/freeradius/3.0/mods-config/sql/main/postgresql/schema.sql"
if [ -f "$SCHEMA_FILE" ]; then
    echo "Importing FreeRADIUS schema from $SCHEMA_FILE..."
    PGPASSWORD="$DB_PASSWORD" psql -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" -f "$SCHEMA_FILE"
fi

# Add the default test user
PGPASSWORD="$DB_PASSWORD" psql -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" <<EOF
DELETE FROM radcheck WHERE username = 'usertest';
INSERT INTO radcheck (username, attribute, op, value)
VALUES ('usertest', 'Cleartext-Password', ':=', 'passwd');
EOF

echo "PostgreSQL initialization complete!"

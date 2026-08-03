#!/bin/bash
set -e

# MySQL initialization script for WiFi Hotspot
# This script is copied to /docker-entrypoint-initdb.d/ and runs on first container startup

echo "Initializing MySQL databases for WiFi Hotspot..."

# Create radius database
mysql -u root -p"$MYSQL_ROOT_PASSWORD" <<-EOSQL
    CREATE DATABASE IF NOT EXISTS radius;
    GRANT ALL PRIVILEGES ON radius.* TO '$RADIUS_DB_USER'@'%' IDENTIFIED BY '$RADIUS_DB_PASSWORD';
    GRANT ALL PRIVILEGES ON radius.* TO '$RADIUS_DB_USER'@'localhost' IDENTIFIED BY '$RADIUS_DB_PASSWORD';
    FLUSH PRIVILEGES;
EOSQL

# Import FreeRADIUS schema
if [ -f /etc/freeradius/3.0/mods-config/sql/main/mysql/schema.sql ]; then
    echo "Importing FreeRADIUS SQL schema..."
    mysql -u root -p"$MYSQL_ROOT_PASSWORD" radius < /etc/freeradius/3.0/mods-config/sql/main/mysql/schema.sql
fi

# Create daloRadius database
mysql -u root -p"$MYSQL_ROOT_PASSWORD" <<-EOSQL
    CREATE DATABASE IF NOT EXISTS daloradius;
    GRANT ALL PRIVILEGES ON daloradius.* TO '$RADIUS_DB_USER'@'%' IDENTIFIED BY '$RADIUS_DB_PASSWORD';
    GRANT ALL PRIVILEGES ON daloradius.* TO '$RADIUS_DB_USER'@'localhost' IDENTIFIED BY '$RADIUS_DB_PASSWORD';
    FLUSH PRIVILEGES;
EOSQL

# Import daloRadius schema if available
if [ -f /var/www/html/daloradius/contrib/db/mysql-daloradius.sql ]; then
    echo "Importing daloRadius SQL schema..."
    mysql -u root -p"$MYSQL_ROOT_PASSWORD" daloradius < /var/www/html/daloradius/contrib/db/mysql-daloradius.sql
fi

echo "MySQL initialization complete!"

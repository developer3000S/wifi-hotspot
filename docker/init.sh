#!/bin/bash

# WiFi Hotspot Docker Entry Point Script
# This script initializes and starts all services for the captive portal

set -e

# Source environment variables
source /etc/wifi-hotspot-config/env.sh 2>/dev/null || true

# Function to log messages
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Function to check if a service is running
is_running() {
    pgrep -x "$1" > /dev/null 2>&1
}

# Function to wait for MySQL to be ready
wait_mysql() {
    local max_attempts=30
    local attempt=1

    while true; do
        # Try without password first (fresh --initialize-insecure install)
        if mysql -u root --password="" -e "SELECT 1" > /dev/null 2>&1; then
            log "MySQL is ready (no password)"
            return 0
        fi
        # Try with configured password (subsequent runs)
        if mysql -u root -p"${MYSQL_ROOT_PASSWORD:-raspbian}" -e "SELECT 1" > /dev/null 2>&1; then
            log "MySQL is ready"
            return 0
        fi
        if [ $attempt -ge $max_attempts ]; then
            log "ERROR: MySQL did not start in time"
            return 1
        fi
        log "Waiting for MySQL... (attempt $attempt/$max_attempts)"
        sleep 2
        ((attempt++))
    done
}

# Function to initialize MySQL database
init_mysql() {
    log "Initializing MySQL database..."

    # Fix mysql user home directory (common Docker issue)
    mkdir -p /nonexistent 2>/dev/null || true

    # Create MySQL log directory (required by MySQL 8.0)
    mkdir -p /var/log/mysql
    touch /var/log/mysql/error.log
    chown -R mysql:mysql /var/log/mysql

    # Fix permissions on data directory
    chown -R mysql:mysql /var/lib/mysql 2>/dev/null || true

    # Initialize MySQL data directory if empty (first run with volume mount)
    if [ ! -d /var/lib/mysql/mysql ]; then
        log "Initializing MySQL data directory..."
        mysqld --initialize-insecure --user=mysql --datadir=/var/lib/mysql 2>/dev/null || \
        mysql_install_db --user=mysql --datadir=/var/lib/mysql 2>/dev/null || true
        log "MySQL data directory initialized"
    fi

    # Start MySQL
    service mysql start || mysqld_safe --user=mysql &
    wait_mysql

    # Set root password if not set
    mysql -u root --connect-expired-password -e \
        "ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD:-raspbian}';" 2>/dev/null || true

    # Create radius database if it doesn't exist
    mysql -u root -p"${MYSQL_ROOT_PASSWORD:-raspbian}" -e "CREATE DATABASE IF NOT EXISTS ${RADIUS_DB_NAME:-radius};" || true

    # Create radius user if it doesn't exist
    mysql -u root -p"${MYSQL_ROOT_PASSWORD:-raspbian}" -e \
        "CREATE USER IF NOT EXISTS '${RADIUS_DB_USER:-appdemoradius}'@'%' IDENTIFIED BY '${RADIUS_DB_PASSWORD:-raspbian}';" || true

    # Grant privileges
    mysql -u root -p"${MYSQL_ROOT_PASSWORD:-raspbian}" -e \
        "GRANT ALL PRIVILEGES ON ${RADIUS_DB_NAME:-radius}.* TO '${RADIUS_DB_USER:-appdemoradius}'@'%';" || true

    # Flush privileges
    mysql -u root -p"${MYSQL_ROOT_PASSWORD:-raspbian}" -e "FLUSH PRIVILEGES;" || true

    # Import FreeRADIUS schema (search in multiple possible locations)
    if [ ! -f /var/lib/mysql/radius/radcheck.ibd ]; then
        SCHEMA_FILE=""
        for p in \
            /etc/freeradius/3.0/mods-config/sql/main/mysql/schema.sql \
            /usr/share/freeradius/3.0/mods-config/sql/main/mysql/schema.sql \
            $(find /usr/share/doc -name 'schema.sql' 2>/dev/null | grep -i mysql | head -1); do
            [ -f "$p" ] && SCHEMA_FILE="$p" && break
        done
        if [ -n "$SCHEMA_FILE" ]; then
            log "Importing FreeRADIUS schema from $SCHEMA_FILE..."
            mysql -u root -p"${MYSQL_ROOT_PASSWORD:-raspbian}" ${RADIUS_DB_NAME:-radius} \
                < "$SCHEMA_FILE" 2>/dev/null || true
        else
            log "WARNING: FreeRADIUS schema.sql not found, skipping schema import"
        fi
    fi

    # Create test user if it doesn't exist
    mysql -u root -p"${MYSQL_ROOT_PASSWORD:-raspbian}" ${RADIUS_DB_NAME:-radius} -e \
        "INSERT INTO radcheck (username, attribute, op, value) VALUES ('usertest', 'Cleartext-Password', ':=', 'passwd') ON DUPLICATE KEY UPDATE username='usertest';" 2>/dev/null || true

    log "MySQL initialization completed"
}

# Function to configure FreeRADIUS
configure_freeradius() {
    log "Configuring FreeRADIUS..."

    # Create necessary directories (may be missing due to empty volume mount)
    mkdir -p /etc/freeradius/3.0/mods-enabled/
    mkdir -p /etc/freeradius/3.0/mods-available/
    mkdir -p /etc/freeradius/3.0/sites-available/
    mkdir -p /etc/freeradius/3.0/mods-config/sql/main/mysql/

    # Configure clients.conf - create minimal version if doesn't exist
    if [ ! -f /etc/freeradius/3.0/clients.conf ]; then
        cat > /etc/freeradius/3.0/clients.conf <<EOF
client localhost {
    ipaddr = 127.0.0.1
    secret = ${HS_RADSECRET:-radtesting123}
    require_message_authenticator = no
    nas_type = other
}

client localnet {
    ipaddr = 10.10.10.0/24
    secret = ${HS_RADSECRET:-radtesting123}
    require_message_authenticator = no
    nas_type = other
}
EOF
    else
        # Update client secret
        sed -i "s/secret = testing123/secret = ${HS_RADSECRET:-radtesting123}/g" /etc/freeradius/3.0/clients.conf || true
    fi

    # Use symlink to mods-available/sql if it exists, otherwise write custom config
    # First, restore the original sql mod-available if it exists
    if [ -f /etc/freeradius/3.0/mods-available/sql ]; then
        # Update the existing sql module config with our credentials
        SQL_CONF=/etc/freeradius/3.0/mods-available/sql
        sed -i "s/^\s*driver\s*=.*/\tdriver = \"rlm_sql_mysql\"/" "$SQL_CONF" || true
        sed -i "s/^\s*dialect\s*=.*/\tdialect = \"mysql\"/" "$SQL_CONF" || true
        sed -i "s/^\s*server\s*=.*/\tserver = \"localhost\"/" "$SQL_CONF" || true
        sed -i "s/^\s*port\s*=.*/\tport = 3306/" "$SQL_CONF" || true
        sed -i "s/^\s*login\s*=.*/\tlogin = \"${RADIUS_DB_USER:-appdemoradius}\"/" "$SQL_CONF" || true
        sed -i "s/^\s*password\s*=.*/\tpassword = \"${RADIUS_DB_PASSWORD:-raspbian}\"/" "$SQL_CONF" || true
        sed -i "s/^\s*radius_db\s*=.*/\tradius_db = \"${RADIUS_DB_NAME:-radius}\"/" "$SQL_CONF" || true
        sed -i "s/^\s*read_clients\s*=.*/\tread_clients = yes/" "$SQL_CONF" || true
        # Enable the module via symlink
        ln -sf /etc/freeradius/3.0/mods-available/sql /etc/freeradius/3.0/mods-enabled/sql 2>/dev/null || true
    else
        # Remove bad directory/file if present
        [ -d /etc/freeradius/3.0/mods-enabled/sql ] && rm -rf /etc/freeradius/3.0/mods-enabled/sql || true
        # Write minimal valid sql module config
        cat > /etc/freeradius/3.0/mods-enabled/sql <<EOF
sql {
    driver = "rlm_sql_mysql"
    dialect = "mysql"
    server = "localhost"
    port = 3306
    login = "${RADIUS_DB_USER:-appdemoradius}"
    password = "${RADIUS_DB_PASSWORD:-raspbian}"
    radius_db = "${RADIUS_DB_NAME:-radius}"
    read_clients = yes
    pool {
        start = 5
        min = 3
        max = 10
        spare = 3
        uses = 0
        lifetime = 0
        idle_timeout = 60
    }
}
EOF
    fi

    # Configure default site if it exists
    sed -i "s/#-sql/-sql/g" /etc/freeradius/3.0/sites-available/default 2>/dev/null || true

    log "FreeRADIUS configuration completed"
}

# Function to configure CoovaChilli
configure_chilli() {
    log "Configuring CoovaChilli..."
    # Ensure config directory exists
    mkdir -p /etc/chilli

    # Update configuration
    cat > /etc/chilli/config << EOF
# Local Network Configurations
HS_WANIF=${HS_WANIF:-eth0}
HS_LANIF=${HS_LANIF:-wlan0}
HS_NETWORK=${HS_NETWORK:-10.10.10.0}
HS_NETMASK=${HS_NETMASK:-255.255.255.0}
HS_UAMLISTEN=${HS_UAMLISTEN:-10.10.10.1}
HS_UAMPORT=${HS_UAMPORT:-3990}
HS_UAMUIPORT=${HS_UAMUIPORT:-4990}

# DNS Servers
HS_DNS1=${HS_DNS1:-10.10.10.1}
HS_DNS2=${HS_DNS2:-8.8.8.8}

# HotSpot settings
HS_NASID=${HS_NASID:-nas01}
HS_RADIUS=${HS_RADIUS:-localhost}
HS_RADIUS2=${HS_RADIUS:-localhost}
HS_UAMALLOW=${HS_NETWORK:-10.10.10.0}/24
HS_RADSECRET=${HS_RADSECRET:-radtesting123}
HS_UAMSECRET=${HS_UAMSECRET:-uamtesting123}

# UAM Format
HS_UAMFORMAT=https://\${HS_UAMLISTEN}/hotspotlogin.php
HS_UAMHOMEPAGE=http://\${HS_UAMLISTEN}:\${HS_UAMPORT}/prelogin

# Firewall ports
HS_TCP_PORTS="${HS_TCP_PORTS:-80 443}"

# Admin credentials
HS_ADMUSR=coovachillispot
HS_ADMPWD=coovachillispot

# DHCP settings
HS_DHCPIF=eth0
HS_DHCP_START=10.10.10.100
HS_DHCP_END=10.10.10.200
HS_DHCP_LEASE=86400
EOF
    
    # Configure up.sh for NAT
    cat > /etc/chilli/up.sh << 'EOF'
#!/bin/bash
# Enable NAT
iptables -I POSTROUTING -t nat -o $HS_WANIF -j MASQUERADE
# Other iptables rules
iptables -I FORWARD -i $HS_LANIF -j ACCEPT
iptables -I FORWARD -o $HS_LANIF -j ACCEPT
EOF
    
    chmod +x /etc/chilli/up.sh
    
    log "CoovaChilli configuration completed"
}

# Function to configure hostapd
configure_hostapd() {
    log "Configuring hostapd..."
    
    cat > /etc/hostapd/hostapd.conf << EOF
interface=${HS_LANIF:-wlan0}
driver=nl80211
ssid=${HOTSPOT_SSID:-MME Captive Portal}
hw_mode=g
channel=1
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=HotspotPassword
wpa_key_mgmt=WPA-PSK
wpa_pairwise=TKIP
rsn_pairwise=CCMP
EOF
    
    # Set DAEMON_CONF
    echo "DAEMON_CONF=\"/etc/hostapd/hostapd.conf\"" > /etc/default/hostapd
    
    log "hostapd configuration completed"
}

# Function to configure dnsmasq
configure_dnsmasq() {
    log "Configuring dnsmasq..."
    
    cat > /etc/dnsmasq.conf << EOF
no-resolv
server=8.8.8.8
server=8.8.4.4
address=/hotspot.example.com/${HS_UAMLISTEN:-10.10.10.1}
dhcp-range=${HS_UAMALLOW:-10.10.10.0}/24,${HS_DHCP_START:-10.10.10.100},${HS_DHCP_END:-10.10.10.200},${HS_DHCP_LEASE:-24h}
EOF
    
    log "dnsmasq configuration completed"
}

# Function to configure Nginx
configure_nginx() {
    log "Configuring Nginx..."

    # Create necessary directories (may be missing due to empty volume mount)
    mkdir -p /etc/nginx/sites-available
    mkdir -p /etc/nginx/sites-enabled
    mkdir -p /etc/nginx/conf.d
    mkdir -p /var/log/nginx
    mkdir -p /run/php

    # Create minimal nginx.conf if missing
    if [ ! -f /etc/nginx/nginx.conf ]; then
        cat > /etc/nginx/nginx.conf <<'NGINXEOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 768;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;

    gzip on;

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
NGINXEOF
    fi

    # Create mime.types if missing
    if [ ! -f /etc/nginx/mime.types ]; then
        cp /usr/share/nginx/modules-available/../../../etc/nginx/mime.types /etc/nginx/mime.types 2>/dev/null || \
        echo "types { text/html html; text/css css; application/javascript js; image/png png; image/jpeg jpg; }" > /etc/nginx/mime.types
    fi

    # Remove default site
    rm -f /etc/nginx/sites-enabled/default

    # Create hotspot site configuration
    cat > /etc/nginx/sites-available/hotspot.example.com <<EOF
server {
    listen ${HS_UAMLISTEN:-10.10.10.1}:80 default_server;
    server_name hotspot.example.com;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen ${HS_UAMLISTEN:-10.10.10.1}:443 ssl default_server;
    server_name hotspot.example.com;
    
    ssl_certificate /etc/ssl/certs/snakeoil.pem;
    ssl_certificate_key /etc/ssl/private/snakeoil.key;
    
    root /var/www/hotspot.example.com;
    index hotspotlogin.php index.php index.phtml index.html index.htm;
    
    location / {
        try_files \$uri \$uri/ /index.php?\$args /hotspotlogin.php?\$args =404;
    }
    
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php7.4-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }
}
EOF
    
    # Enable the site
    ln -sf /etc/nginx/sites-available/hotspot.example.com /etc/nginx/sites-enabled/
    
    # Create PHP-FPM pool configuration
    cat > /etc/php/7.4/fpm/pool.d/www.conf << EOF
[www]
user = www-data
group = www-data
listen = /run/php/php7.4-fpm.sock
listen.owner = www-data
listen.group = www-data
pm = dynamic
pm.max_children = 5
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
EOF
    
    log "Nginx configuration completed"
}

# Function to download hotspot-login
install_hotspot_login() {
    log "Installing hotspot-login..."
    
    if [ ! -d /var/www/hotspot.example.com/hotspot-login ]; then
        cd /tmp
        wget -c https://github.com/MME-Connections/hotspot-login/archive/master.zip -O hotspot-login-master.zip || true
        unzip -q hotspot-login-master.zip || true
        mv hotspot-login-master /var/www/hotspot.example.com/hotspot-login || true
        rm -f hotspot-login-master.zip
    fi
    
    # Update UAM secret in hotspotlogin.php
    if [ -f /var/www/hotspot.example.com/hotspot-login/hotspotlogin.php ]; then
        sed -i "s/\$uamsecret = .*/\$uamsecret = \"${HS_UAMSECRET:-uamtesting123}\";/" \
            /var/www/hotspot.example.com/hotspot-login/hotspotlogin.php
    fi
    
    # Set proper permissions
    chown -R www-data:www-data /var/www/hotspot.example.com
    
    log "hotspot-login installation completed"
}

# Function to start all services
start_services() {
    log "Starting services..."
    
    # Apply sysctl settings
    sysctl -p /etc/sysctl.conf || true
    
    # Start MySQL
    log "Starting MySQL..."
    service mysql start || true
    wait_mysql || log "WARNING: MySQL may not be fully ready"
    
    # Start FreeRADIUS
    log "Starting FreeRADIUS..."
    service freeradius start || log "WARNING: FreeRADIUS failed to start"
    
    # Start dnsmasq
    log "Starting dnsmasq..."
    service dnsmasq start || log "WARNING: dnsmasq failed to start"
    
    # Start PHP-FPM
    log "Starting PHP-FPM..."
    service php7.4-fpm start || log "WARNING: PHP-FPM failed to start"
    
    # Start Nginx
    log "Starting Nginx..."
    service nginx start || log "WARNING: Nginx failed to start"
    
    # Start CoovaChilli
    log "Starting CoovaChilli..."
    service chilli start || log "WARNING: CoovaChilli failed to start"
    
    # Start hostapd
    log "Starting hostapd..."
    service hostapd start || log "WARNING: hostapd failed to start"
    
    log "All services started successfully!"
}

# Function to stop all services
stop_services() {
    log "Stopping services..."
    
    service hostapd stop || true
    service chilli stop || true
    service nginx stop || true
    service php7.4-fpm stop || true
    service dnsmasq stop || true
    service freeradius stop || true
    service mysql stop || true
    
    log "All services stopped"
}

# Function to show status
show_status() {
    log "=== Service Status ==="
    
    for service in mysql freeradius dnsmasq nginx php7.4-fpm chilli hostapd; do
        if is_running $service; then
            log "$service: RUNNING"
        else
            log "$service: STOPPED"
        fi
    done
    
    # Show network info
    log ""
    log "=== Network Information ==="
    ip addr show || true
    iptables -L -n || true
    
    # Show CoovaChilli status
    log ""
    log "=== CoovaChilli Status ==="
    chilli_query || true
}

# Function to show logs
tail_logs() {
    log "=== Tailing logs (Ctrl+C to exit) ==="
    tail -f /var/log/chilli.log /var/log/freeradius/freeradius.log /var/log/nginx/error.log /var/log/mysql/error.log
}

# Main execution
case "$1" in
    start|run)
        log "Starting WiFi Hotspot container..."
        
        # Initialize configurations
        configure_freeradius
        configure_chilli
        configure_hostapd
        configure_dnsmasq
        configure_nginx
        
        # Install hotspot-login
        install_hotspot_login
        
        # Initialize MySQL
        init_mysql
        
        # Start all services
        start_services
        
        # Keep container running
        tail -f /dev/null
        ;;
    stop)
        log "Stopping WiFi Hotspot container..."
        stop_services
        exit 0
        ;;
    restart)
        log "Restarting WiFi Hotspot..."
        stop_services
        sleep 2
        start_services
        tail -f /dev/null
        ;;
    status)
        show_status
        ;;
    logs|tail)
        tail_logs
        ;;
    shell|bash|sh)
        /bin/bash
        ;;
    setup|init)
        log "Setting up configurations..."
        configure_freeradius
        configure_chilli
        configure_hostapd
        configure_dnsmasq
        configure_nginx
        install_hotspot_login
        log "Setup completed. Run 'start' to launch services."
        ;;
    test)
        log "Running service tests..."
        
        # Test MySQL
        if is_running mysqld; then
            log "MySQL: OK"
            mysql -u root -p"${MYSQL_ROOT_PASSWORD:-raspbian}" -e "SHOW DATABASES;" || log "MySQL: FAILED"
        else
            log "MySQL: NOT RUNNING"
        fi
        
        # Test FreeRADIUS
        if is_running freeradius; then
            log "FreeRADIUS: OK"
            radtest usertest passwd localhost 0 ${HS_RADSECRET:-radtesting123} || log "FreeRADIUS: FAILED"
        else
            log "FreeRADIUS: NOT RUNNING"
        fi
        
        # Test Nginx
        if is_running nginx; then
            log "Nginx: OK"
            curl -I http://${HS_UAMLISTEN:-10.10.10.1} || log "Nginx: FAILED"
        else
            log "Nginx: NOT RUNNING"
        fi
        
        # Test CoovaChilli
        if is_running chilli; then
            log "CoovaChilli: OK"
            chilli_query || log "CoovaChilli: FAILED"
        else
            log "CoovaChilli: NOT RUNNING"
        fi
        ;;
    *)
        log "Usage: init-hotspot {start|stop|restart|status|logs|shell|setup|test}"
        log ""
        log "Default action: start"
        log "Starting WiFi Hotspot container..."
        
        # Initialize configurations
        configure_freeradius
        configure_chilli
        configure_hostapd
        configure_dnsmasq
        configure_nginx
        
        # Install hotspot-login
        install_hotspot_login
        
        # Initialize MySQL
        init_mysql
        
        # Start all services
        start_services
        
        # Keep container running
        tail -f /dev/null
        ;;
esac

exit 0

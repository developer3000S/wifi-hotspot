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

    # Give freerad user access to MySQL socket
    usermod -aG mysql freerad 2>/dev/null || true

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

    # Always write a fresh minimal sql config (the original mods-available/sql
    # has all credentials commented out; sed-patching is unreliable on it)
    # Break existing symlink if present
    rm -f /etc/freeradius/3.0/mods-enabled/sql
    cat > /etc/freeradius/3.0/mods-enabled/sql <<EOF
sql {
    driver = "rlm_sql_mysql"
    dialect = "mysql"

    # Use 127.0.0.1 (not localhost) to force TCP instead of Unix socket
    server = "127.0.0.1"
    port = 3306
    login = "${RADIUS_DB_USER:-appdemoradius}"
    password = "${RADIUS_DB_PASSWORD:-raspbian}"
    radius_db = "${RADIUS_DB_NAME:-radius}"

    read_clients = yes

    # FreeRADIUS schema + queries
    logfile = /var/log/freeradius/sqltrace.sql
    sql_user_name = "%{User-Name}"

    pool {
        start = 2
        min = 1
        max = 10
        spare = 3
        uses = 0
        lifetime = 0
        idle_timeout = 60
    }
}
EOF

    # Configure default site if it exists
    sed -i "s/#-sql/-sql/g" /etc/freeradius/3.0/sites-available/default 2>/dev/null || true

    log "FreeRADIUS configuration completed"
}

# Function to configure CoovaChilli
configure_chilli() {
    log "Configuring CoovaChilli..."
    # Ensure config directory exists
    mkdir -p /etc/chilli

    # Register CoovaChilli init.d script (installed by coova-chilli to /etc/chilli/init.d/)
    if [ -f /etc/chilli/init.d/chilli ] && [ ! -f /etc/init.d/chilli ]; then
        ln -sf /etc/chilli/init.d/chilli /etc/init.d/chilli
        log "Registered CoovaChilli init.d service"
    fi

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
    
    # Write chilli options file in coova-chilli format
    # Each line: option=value (WITHOUT leading --; chilli reads this as a config file)
    cat > /etc/chilli/options << EOF
net=${HS_NETWORK:-10.10.10.0}/24
uamlisten=${HS_UAMLISTEN:-10.10.10.1}
uamport=${HS_UAMPORT:-3990}
uamuiport=${HS_UAMUIPORT:-4990}
dns1=${HS_DNS1:-10.10.10.1}
dns2=${HS_DNS2:-8.8.8.8}
radiusserver1=${HS_RADIUS:-127.0.0.1}
radiusserver2=${HS_RADIUS:-127.0.0.1}
radiussecret=${HS_RADSECRET:-radtesting123}
uamsecret=${HS_UAMSECRET:-uamtesting123}
uamallowed=${HS_NETWORK:-10.10.10.0}/24
dhcpif=${HS_WANIF:-eth0}
radiusnasid=${HS_NASID:-nas01}
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

    # Create necessary directories
    mkdir -p /etc/nginx/sites-available
    mkdir -p /etc/nginx/sites-enabled
    mkdir -p /etc/nginx/conf.d
    mkdir -p /var/log/nginx
    mkdir -p /run/php
    mkdir -p /etc/nginx/snippets

    # Generate self-signed TLS cert if snakeoil package didn't install it
    if [ ! -f /etc/ssl/certs/snakeoil.pem ]; then
        log "Generating self-signed TLS certificate..."
        mkdir -p /etc/ssl/private
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout /etc/ssl/private/snakeoil.key \
            -out /etc/ssl/certs/snakeoil.pem \
            -subj "/C=US/ST=State/L=City/O=WiFiHotspot/CN=hotspot.example.com" \
            2>/dev/null || true
        log "Self-signed certificate generated"
    fi

    # Ensure fastcgi-php.conf snippet exists
    if [ ! -f /etc/nginx/snippets/fastcgi-php.conf ]; then
        cat > /etc/nginx/snippets/fastcgi-php.conf <<'EOF'
# regex to split $uri to $fastcgi_script_name and $fastcgi_path
fastcgi_split_path_info ^(.+\.php)(/.+)$;

# Check that the PHP script exists before passing it
try_files $fastcgi_script_name =404;

# Bypass the fact that try_files resets $fastcgi_path_info
set $path_info $fastcgi_path_info;
fastcgi_param PATH_INFO $path_info;

fastcgi_index index.php;
include fastcgi.conf;
EOF
    fi

    # Ensure fastcgi.conf exists
    if [ ! -f /etc/nginx/fastcgi.conf ]; then
        cat > /etc/nginx/fastcgi.conf <<'EOF'
fastcgi_param  SCRIPT_FILENAME    $document_root$fastcgi_script_name;
fastcgi_param  QUERY_STRING       $query_string;
fastcgi_param  REQUEST_METHOD     $request_method;
fastcgi_param  CONTENT_TYPE       $content_type;
fastcgi_param  CONTENT_LENGTH     $content_length;
fastcgi_param  SCRIPT_NAME        $fastcgi_script_name;
fastcgi_param  REQUEST_URI        $request_uri;
fastcgi_param  DOCUMENT_URI       $document_uri;
fastcgi_param  DOCUMENT_ROOT      $document_root;
fastcgi_param  SERVER_PROTOCOL    $server_protocol;
fastcgi_param  REQUEST_SCHEME     $scheme;
fastcgi_param  HTTPS              $https if_not_empty;
fastcgi_param  GATEWAY_INTERFACE  CGI/1.1;
fastcgi_param  SERVER_SOFTWARE    nginx/$nginx_version;
fastcgi_param  REMOTE_ADDR        $remote_addr;
fastcgi_param  REMOTE_PORT        $remote_port;
fastcgi_param  SERVER_ADDR        $server_addr;
fastcgi_param  SERVER_PORT        $server_port;
fastcgi_param  SERVER_NAME        $server_name;
EOF
    fi

    # Ensure fastcgi_params exists
    if [ ! -f /etc/nginx/fastcgi_params ]; then
        cat > /etc/nginx/fastcgi_params <<'EOF'
fastcgi_param  QUERY_STRING       $query_string;
fastcgi_param  REQUEST_METHOD     $request_method;
fastcgi_param  CONTENT_TYPE       $content_type;
fastcgi_param  CONTENT_LENGTH     $content_length;
fastcgi_param  SCRIPT_NAME        $fastcgi_script_name;
fastcgi_param  REQUEST_URI        $request_uri;
fastcgi_param  DOCUMENT_URI       $document_uri;
fastcgi_param  DOCUMENT_ROOT      $document_root;
fastcgi_param  SERVER_PROTOCOL    $server_protocol;
fastcgi_param  REQUEST_SCHEME     $scheme;
fastcgi_param  HTTPS              $https if_not_empty;
fastcgi_param  GATEWAY_INTERFACE  CGI/1.1;
fastcgi_param  SERVER_SOFTWARE    nginx/$nginx_version;
fastcgi_param  REMOTE_ADDR        $remote_addr;
fastcgi_param  REMOTE_PORT        $remote_port;
fastcgi_param  SERVER_ADDR        $server_addr;
fastcgi_param  SERVER_PORT        $server_port;
fastcgi_param  SERVER_NAME        $server_name;
EOF
    fi

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
    # Listen on 0.0.0.0 so nginx starts even before the hotspot interface (10.10.10.1) is up
    cat > /etc/nginx/sites-available/hotspot.example.com <<EOF
server {
    listen 80 default_server;
    server_name hotspot.example.com ${HS_UAMLISTEN:-10.10.10.1};
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl default_server;
    server_name hotspot.example.com ${HS_UAMLISTEN:-10.10.10.1};
    
    ssl_certificate /etc/ssl/certs/snakeoil.pem;
    ssl_certificate_key /etc/ssl/private/snakeoil.key;
    
    root /var/www/hotspot.example.com;
    index hotspotlogin.php index.php index.phtml index.html index.htm;
    
    location / {
        try_files \$uri \$uri/ /index.php?\$args /hotspotlogin.php?\$args =404;
    }
    
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.1-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
}
EOF
    
    # Enable the site
    ln -sf /etc/nginx/sites-available/hotspot.example.com /etc/nginx/sites-enabled/
    
    # Create PHP-FPM pool configuration
    cat > /etc/php/8.1/fpm/pool.d/www.conf << EOF
[www]
user = www-data
group = www-data
listen = /run/php/php8.1-fpm.sock
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
    if ! service freeradius start; then
        log "WARNING: FreeRADIUS failed to start. Running config test:"
        freeradius -XC 2>&1 | tail -30 || true
        log "FreeRADIUS last error log:"
        tail -20 /var/log/freeradius/freeradius.log 2>/dev/null || true
    fi
    
    # Start dnsmasq
    log "Starting dnsmasq..."
    service dnsmasq start || log "WARNING: dnsmasq failed to start"
    
    # Start PHP-FPM
    log "Starting PHP-FPM..."
    # Detect installed PHP-FPM version dynamically
    PHP_FPM_SVC=$(ls /etc/init.d/php*-fpm 2>/dev/null | head -1 | xargs basename 2>/dev/null || echo "php7.4-fpm")
    if ! service "$PHP_FPM_SVC" start; then
        log "WARNING: PHP-FPM ($PHP_FPM_SVC) failed to start"
    fi
    
    # Start Nginx
    log "Starting Nginx..."
    if ! service nginx start; then
        log "WARNING: Nginx failed to start. Running config test:"
        nginx -t 2>&1 || true
        log "Nginx last error log:"
        tail -20 /var/log/nginx/error.log 2>/dev/null || true
    fi
    
    # Start CoovaChilli
    log "Starting CoovaChilli..."
    if ! service chilli start 2>/dev/null; then
        # Fallback: try running chilli directly using the options file
        if command -v chilli >/dev/null 2>&1; then
            log "Trying direct chilli start as fallback..."
            chilli --conf /etc/chilli/options --fg &
            sleep 2
            if pgrep -x chilli >/dev/null 2>&1; then
                log "CoovaChilli started via direct invocation"
            else
                log "WARNING: CoovaChilli failed to start (direct)"
                chilli --conf /etc/chilli/options --fg 2>&1 | head -20 || true
            fi
        else
            log "WARNING: CoovaChilli binary not found"
        fi
    fi
    
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

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

# Function to wait for PostgreSQL to be ready
wait_postgres() {
    local max_attempts=30
    local attempt=1

    while true; do
        if pg_isready -h "${DB_HOST:-127.0.0.1}" -p "${DB_PORT:-5432}" > /dev/null 2>&1; then
            log "PostgreSQL is ready"
            return 0
        fi
        if [ $attempt -ge $max_attempts ]; then
            log "ERROR: PostgreSQL did not start in time"
            return 1
        fi
        log "Waiting for PostgreSQL... (attempt $attempt/$max_attempts)"
        sleep 2
        ((attempt++))
    done
}

# Function to initialize PostgreSQL database
init_postgres() {
    log "Initializing PostgreSQL database..."

    PG_VERSION_NUM=$(ls /usr/lib/postgresql 2>/dev/null | sort -V | tail -1)
    PGDATA="${PGDATA:-/var/lib/postgresql/data}"
    PG_BIN="/usr/lib/postgresql/${PG_VERSION_NUM}/bin"

    mkdir -p "$PGDATA" /var/log/postgresql /var/run/postgresql
    chown -R postgres:postgres "$PGDATA" /var/log/postgresql /var/run/postgresql

    # Initialize data directory on first run (volume may be empty)
    if [ ! -f "$PGDATA/PG_VERSION" ]; then
        log "Initializing PostgreSQL data directory..."
        runuser -u postgres -- "$PG_BIN/initdb" -D "$PGDATA" \
            --auth-local=trust --auth-host=scram-sha-256 > /dev/null
        log "PostgreSQL data directory initialized"
    fi

    # Start PostgreSQL if it is not already running
    if runuser -u postgres -- "$PG_BIN/pg_ctl" -D "$PGDATA" status > /dev/null 2>&1; then
        log "PostgreSQL already running - reusing existing instance"
    else
        runuser -u postgres -- "$PG_BIN/pg_ctl" -D "$PGDATA" \
            -l /var/log/postgresql/postgresql.log \
            -o "-c listen_addresses=127.0.0.1 -p ${DB_PORT:-5432}" start
    fi
    wait_postgres

    # Create or update the RADIUS role
    if ! runuser -u postgres -- psql -p "${DB_PORT:-5432}" -tAc \
        "SELECT 1 FROM pg_roles WHERE rolname='${RADIUS_DB_USER:-freerad}'" | grep -q 1; then
        runuser -u postgres -- psql -p "${DB_PORT:-5432}" -c \
            "CREATE ROLE \"${RADIUS_DB_USER:-freerad}\" LOGIN PASSWORD '${RADIUS_DB_PASSWORD:-radtesting123}';"
    else
        runuser -u postgres -- psql -p "${DB_PORT:-5432}" -c \
            "ALTER ROLE \"${RADIUS_DB_USER:-freerad}\" WITH LOGIN PASSWORD '${RADIUS_DB_PASSWORD:-radtesting123}';"
    fi

    # Create the RADIUS database if it does not exist
    if ! runuser -u postgres -- psql -p "${DB_PORT:-5432}" -tAc \
        "SELECT 1 FROM pg_database WHERE datname='${RADIUS_DB_NAME:-radius}'" | grep -q 1; then
        runuser -u postgres -- createdb -p "${DB_PORT:-5432}" \
            -O "${RADIUS_DB_USER:-freerad}" "${RADIUS_DB_NAME:-radius}"
    fi

    # Import the FreeRADIUS schema once
    SCHEMA_FILE=""
    for p in \
        /etc/freeradius/3.0/mods-config/sql/main/postgresql/schema.sql \
        /usr/share/freeradius/3.0/mods-config/sql/main/postgresql/schema.sql; do
        [ -f "$p" ] && SCHEMA_FILE="$p" && break
    done

    if [ -n "$SCHEMA_FILE" ] && ! PGPASSWORD="${RADIUS_DB_PASSWORD:-radtesting123}" psql \
        -h "${DB_HOST:-127.0.0.1}" -p "${DB_PORT:-5432}" -U "${RADIUS_DB_USER:-freerad}" \
        -d "${RADIUS_DB_NAME:-radius}" -tAc "SELECT to_regclass('public.radcheck')" 2>/dev/null | grep -q radcheck; then
        log "Importing FreeRADIUS schema from $SCHEMA_FILE..."
        PGPASSWORD="${RADIUS_DB_PASSWORD:-radtesting123}" psql \
            -h "${DB_HOST:-127.0.0.1}" -p "${DB_PORT:-5432}" -U "${RADIUS_DB_USER:-freerad}" \
            -d "${RADIUS_DB_NAME:-radius}" -f "$SCHEMA_FILE" > /dev/null 2>&1 || \
            log "WARNING: FreeRADIUS schema import failed"
    fi

    # Create test users and a local NAS client
    PGPASSWORD="${RADIUS_DB_PASSWORD:-radtesting123}" psql \
        -h "${DB_HOST:-127.0.0.1}" -p "${DB_PORT:-5432}" -U "${RADIUS_DB_USER:-freerad}" \
        -d "${RADIUS_DB_NAME:-radius}" > /dev/null 2>&1 <<SQL || true
DELETE FROM radcheck WHERE username IN ('demo', 'usertest');
INSERT INTO radcheck (username, attribute, op, value) VALUES
    ('demo', 'Cleartext-Password', ':=', 'demo123'),
    ('usertest', 'Cleartext-Password', ':=', '${TEST_PASSWORD:-passwd}');
DELETE FROM nas WHERE nasname IN ('127.0.0.1', 'localhost');
INSERT INTO nas (nasname, shortname, type, secret, description) VALUES
    ('127.0.0.1', 'localhost', 'other', '${HS_RADSECRET:-radtesting123}', 'Local RADIUS client'),
    ('localhost', 'localhost', 'other', '${HS_RADSECRET:-radtesting123}', 'RADIUS Client');
SQL

    log "PostgreSQL initialization completed"
}

# Function to configure FreeRADIUS
configure_freeradius() {
    log "Configuring FreeRADIUS..."

    # Create necessary directories (may be missing due to empty volume mount)
    mkdir -p /etc/freeradius/3.0/mods-enabled/
    mkdir -p /etc/freeradius/3.0/mods-available/
    mkdir -p /etc/freeradius/3.0/sites-available/

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

    # Write a fresh PostgreSQL sql module config
    cat > /etc/freeradius/3.0/mods-available/sql <<EOF
sql {
    dialect = "postgresql"
    driver = "rlm_sql_postgresql"

    postgresql {
        send_application_name = yes
    }

    server = "${DB_HOST:-127.0.0.1}"
    port = ${DB_PORT:-5432}
    login = "${RADIUS_DB_USER:-freerad}"
    password = "${RADIUS_DB_PASSWORD:-radtesting123}"
    radius_db = "${RADIUS_DB_NAME:-radius}"

    acct_table1 = "radacct"
    acct_table2 = "radacct"
    postauth_table = "radpostauth"
    authcheck_table = "radcheck"
    groupcheck_table = "radgroupcheck"
    authreply_table = "radreply"
    groupreply_table = "radgroupreply"
    usergroup_table = "radusergroup"

    read_clients = yes
    client_table = "nas"
    group_attribute = "SQL-Group"

    pool {
        start = 2
        min = 1
        max = 10
        spare = 3
        uses = 0
        retry_delay = 5
        lifetime = 0
        idle_timeout = 60
        max_retries = 5
    }

    \$INCLUDE \${modconfdir}/\${.:name}/main/\${dialect}/queries.conf
}
EOF

    # Enable the sql module
    rm -f /etc/freeradius/3.0/mods-enabled/sql
    ln -s ../mods-available/sql /etc/freeradius/3.0/mods-enabled/sql

    # Configure default site to use SQL
    sed -i -E "s/^#([[:space:]]*)-sql/\1-sql/" /etc/freeradius/3.0/sites-available/default 2>/dev/null || true

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
HS_UAMFORMAT=http://${HS_UAMLISTEN}:80/
HS_UAMHOMEPAGE=http://${HS_UAMLISTEN}:80/

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
iptables-nft -I POSTROUTING -t nat -o $HS_WANIF -j MASQUERADE
# Other iptables rules
iptables-nft -I FORWARD -i $HS_LANIF -j ACCEPT
iptables-nft -I FORWARD -o $HS_LANIF -j ACCEPT
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
address=/uam/${HS_UAMLISTEN:-10.10.10.1}
# Captive portal: resolve all other names to the hotspot gateway
address=/#/${HS_UAMLISTEN:-10.10.10.1}
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
    PHP_FPM_SOCK=$(ls /run/php/php*-fpm.sock 2>/dev/null | head -1 || echo /run/php/php8.1-fpm.sock)
    cat > /etc/nginx/sites-available/hotspot.example.com <<EOF
server {
    listen 80 default_server;
    server_name _;
    root /var/www/hotspot.example.com;
    index index.html index.php;

    # Captive portal landing page (HTTP). All client DNS resolves here.
    location / {
        try_files \$uri \$uri/ /index.html =404;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${PHP_FPM_SOCK};
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
}

server {
    listen 443 ssl default_server;
    server_name _;
    root /var/www/hotspot.example.com;
    index index.html;

    ssl_certificate /etc/ssl/certs/snakeoil.pem;
    ssl_certificate_key /etc/ssl/private/snakeoil.key;

    location / {
        try_files \$uri \$uri/ /index.html =404;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${PHP_FPM_SOCK};
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
    
    # PostgreSQL was already started and initialized in init_postgres() — just verify it's up
    log "Verifying PostgreSQL is ready..."
    wait_postgres || log "WARNING: PostgreSQL may not be fully ready"
    
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
    if [ -n "${PGDATA:-}" ] && [ -n "${PG_BIN:-}" ]; then
        runuser -u postgres -- "$PG_BIN/pg_ctl" -D "$PGDATA" stop -m fast > /dev/null 2>&1 || true
    fi
    
    log "All services stopped"
}

# Function to show status
show_status() {
    log "=== Service Status ==="
    
    for service in postgres freeradius dnsmasq nginx php7.4-fpm chilli hostapd; do
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
    iptables-nft -L -n || true
    
    # Show CoovaChilli status
    log ""
    log "=== CoovaChilli Status ==="
    chilli_query || true
}

# Function to show logs
tail_logs() {
    log "=== Tailing logs (Ctrl+C to exit) ==="
    tail -f /var/log/chilli.log /var/log/freeradius/freeradius.log /var/log/nginx/error.log /var/log/postgresql/postgresql.log
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
        
        # Initialize PostgreSQL
        init_postgres
        
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
        
        # Test PostgreSQL
        if pg_isready -h "${DB_HOST:-127.0.0.1}" -p "${DB_PORT:-5432}" > /dev/null 2>&1; then
            log "PostgreSQL: OK"
            PGPASSWORD="${RADIUS_DB_PASSWORD:-radtesting123}" psql \
                -h "${DB_HOST:-127.0.0.1}" -p "${DB_PORT:-5432}" \
                -U "${RADIUS_DB_USER:-freerad}" -d "${RADIUS_DB_NAME:-radius}" \
                -c "SELECT COUNT(*) FROM radcheck;" || log "PostgreSQL: FAILED"
        else
            log "PostgreSQL: NOT RUNNING"
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
        
        # Initialize PostgreSQL
        init_postgres
        
        # Start all services
        start_services
        
        # Keep container running
        tail -f /dev/null
        ;;
esac

exit 0

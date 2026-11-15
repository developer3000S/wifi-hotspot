#!/bin/bash

# Wi-Fi Hotspot with Captive Portal - Local Installation Script
# Installs and configures: CoovaChilli, hostapd, FreeRADIUS, PostgreSQL, Nginx, dnsmasq

set -e

# Load configuration from .env file if it exists
if [ -f "$(dirname "$0")/.env" ]; then
    source "$(dirname "$0")/.env"
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check for root privileges
if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must be run as root"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEB_DIR="/var/www/hotspot"
CHILLI_CONF="/etc/chilli/config"
HOSTAPD_CONF="/etc/hostapd/hostapd.conf"
DNSMASQ_CONF="/etc/dnsmasq.conf"
SYSCTL_CONF="/etc/sysctl.conf"
UP_SCRIPT="/etc/chilli/up.sh"

# Configuration variables (with defaults if not in .env)
WIFI_SSID="${WIFI_SSID:-FREEHOTSPOT}"
WIFI_CHANNEL="${WIFI_CHANNEL:-1}"
WIFI_INTERFACE="${WIFI_INTERFACE:-tun0}"
WAN_INTERFACE="${WAN_INTERFACE:-eth0}"
HOTSPOT_NETWORK="${HOTSPOT_NETWORK:-10.10.10.0}"
HOTSPOT_NETMASK="${HOTSPOT_NETMASK:-255.255.255.0}"
HOTSPOT_IP="${HOTSPOT_IP:-10.10.10.1}"
UAM_PORT="${UAM_PORT:-3990}"
UAM_UI_PORT="${UAM_UI_PORT:-4990}"
RADIUS_SECRET="${RADIUS_SECRET:-radtesting123}"
UAM_SECRET="${UAM_SECRET:-uamtesting123}"
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-radius}"
DB_USER="${DB_USER:-freerad}"
DB_PASSWORD="${DB_PASSWORD:-radtesting123}"
RADIUS_DB_PASSWORD="${RADIUS_DB_PASSWORD:-$DB_PASSWORD}"

# ==============================================================================
# STEP 1: Install required packages
# ==============================================================================
log_info "Step 1: Installing required packages..."

apt-get update

apt-get install -y \
    hostapd \
    freeradius \
    freeradius-postgresql \
    postgresql \
    postgresql-client \
    nginx \
    dnsmasq \
    php-fpm \
    php-pgsql \
    php-gd \
    php-cli \
    curl \
    git \
    wget \
    iptables \
    haserl \
    libssl-dev \
    libjson-c-dev \
    debhelper \
    gengetopt \
    libtool \
    automake \
    build-essential

log_info "Packages installed successfully"

# ==============================================================================
# STEP 2: Configure hostapd
# ==============================================================================
log_info "Step 2: Configuring hostapd..."

cat > "$HOSTAPD_CONF" <<EOF
interface=$WIFI_INTERFACE
driver=nl80211
ssid=$WIFI_SSID
hw_mode=g
channel=$WIFI_CHANNEL
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
EOF

sed -i 's|^DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd 2>/dev/null || true

systemctl unmask hostapd 2>/dev/null || true
systemctl enable hostapd 2>/dev/null || true

log_info "hostapd configured"

# ==============================================================================
# STEP 3: Configure PostgreSQL for FreeRADIUS
# ==============================================================================
log_info "Step 3: Configuring PostgreSQL for FreeRADIUS..."

# Start PostgreSQL service
systemctl enable postgresql
systemctl start postgresql

# Wait for PostgreSQL to accept connections
for _ in $(seq 1 30); do
    pg_isready -h "$DB_HOST" -p "$DB_PORT" >/dev/null 2>&1 && break
    sleep 1
done

# Create RADIUS role (idempotent)
if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1; then
    runuser -u postgres -- psql -c "CREATE ROLE \"$DB_USER\" LOGIN PASSWORD '$DB_PASSWORD';"
else
    runuser -u postgres -- psql -c "ALTER ROLE \"$DB_USER\" WITH LOGIN PASSWORD '$DB_PASSWORD';"
fi

# Create RADIUS database (idempotent)
if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1; then
    runuser -u postgres -- createdb -O "$DB_USER" "$DB_NAME"
fi

# Import FreeRADIUS schema once
SCHEMA_FILE="/etc/freeradius/3.0/mods-config/sql/main/postgresql/schema.sql"
if [ -f "$SCHEMA_FILE" ] && ! PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT to_regclass('public.radcheck')" | grep -q radcheck; then
    PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -f "$SCHEMA_FILE"
fi

log_info "PostgreSQL configured"

# ==============================================================================
# STEP 4: Configure FreeRADIUS
# ==============================================================================
log_info "Step 4: Configuring FreeRADIUS..."

# Configure FreeRADIUS SQL module
mkdir -p /etc/freeradius/3.0/mods-enabled
mkdir -p /etc/freeradius/3.0/mods-available
cat > /etc/freeradius/3.0/mods-available/sql <<EOF
sql {
    dialect = "postgresql"
    driver = "rlm_sql_postgresql"

    postgresql {
        send_application_name = yes
    }

    server = "$DB_HOST"
    port = $DB_PORT
    login = "$DB_USER"
    password = "$DB_PASSWORD"
    radius_db = "$DB_NAME"

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

chown freerad:freerad /etc/freeradius/3.0/mods-available/sql 2>/dev/null || true
chmod 640 /etc/freeradius/3.0/mods-available/sql

# Remove existing sql link if present and create new one
rm -f /etc/freeradius/3.0/mods-enabled/sql
ln -s ../mods-available/sql /etc/freeradius/3.0/mods-enabled/sql

# Configure FreeRADIUS clients
if ! grep -q "client localhost" /etc/freeradius/3.0/clients.conf 2>/dev/null; then
    cat >> /etc/freeradius/3.0/clients.conf <<EOF

client localhost {
    ipaddr = 127.0.0.1
    secret = $RADIUS_SECRET
}
EOF
fi

# Update default site to use SQL (uncomment the sql module entries)
sed -i -E 's/^#([[:space:]]*)-sql/\1-sql/' /etc/freeradius/3.0/sites-available/default 2>/dev/null || true

if ! freeradius -XC >/dev/null 2>&1; then
    log_warn "FreeRADIUS configuration test failed, check /etc/freeradius/3.0"
fi

systemctl enable freeradius
systemctl restart freeradius

log_info "FreeRADIUS configured"

# ==============================================================================
# STEP 5: Configure CoovaChilli (if not already installed)
# ==============================================================================
log_info "Step 5: Configuring CoovaChilli..."

# Check if CoovaChilli is installed
if ! command -v chilli &> /dev/null; then
    log_warn "CoovaChilli is not installed. Skipping installation."
    log_warn "To install CoovaChilli, please run the build process first."
else
    log_info "CoovaChilli is already installed"
fi

# Create CoovaChilli configuration
cat > "$CHILLI_CONF" <<EOF
# CoovaChilli Configuration for Wi-Fi Hotspot

# Network Configuration
HS_WANIF=$WAN_INTERFACE
HS_LANIF=$WIFI_INTERFACE
HS_NETWORK=$HOTSPOT_NETWORK
HS_NETMASK=$HOTSPOT_NETMASK
HS_UAMLISTEN=$HOTSPOT_IP
HS_UAMPORT=$UAM_PORT
HS_UAMUIPORT=$UAM_UI_PORT

# DNS Configuration
HS_DNS1=8.8.8.8
HS_DNS2=8.8.4.4

# RADIUS Configuration
HS_NASID=nas01
HS_RADIUS=localhost
HS_RADIUS2=localhost
HS_RADSECRET=$RADIUS_SECRET

# UAM Configuration
HS_UAMSECRET=$UAM_SECRET
HS_UAMALLOW=$HOTSPOT_NETWORK/24
HS_UAMFORMAT=http://\$HS_UAMLISTEN:80/
HS_UAMHOMEPAGE=http://\$HS_UAMLISTEN:80/

# chilli options
HS_TCP_PORTS="80 443"

# Admin credentials
HS_ADMUSR=admin
HS_ADMPWD=admin123

# Enable ChilliSpot extensions
HS_ADMINTERVAL=300
HS_MAXLOGINS=3
EOF

# Enable chilli service
systemctl unmask chilli 2>/dev/null || true
systemctl enable chilli 2>/dev/null || true

log_info "CoovaChilli configured"

# ==============================================================================
# STEP 6: Configure iptables and routing
# ==============================================================================
log_info "Step 6: Configuring iptables and routing..."

# Enable IP forwarding
if ! grep -q "net.ipv4.ip_forward=1" "$SYSCTL_CONF" 2>/dev/null; then
    echo "net.ipv4.ip_forward=1" >> "$SYSCTL_CONF"
fi
sysctl -p "$SYSCTL_CONF" 2>/dev/null || true

# Create up.sh script for chilli
cat > "$UP_SCRIPT" <<EOF
#!/bin/bash
# Enable NAT between WAN and LAN interfaces
iptables-nft -t nat -A POSTROUTING -o $WAN_INTERFACE -j MASQUERADE
iptables-nft -A FORWARD -i $WIFI_INTERFACE -o $WAN_INTERFACE -j ACCEPT
iptables-nft -A FORWARD -i $WAN_INTERFACE -o $WIFI_INTERFACE -m state --state RELATED,ESTABLISHED -j ACCEPT
EOF

chmod +x "$UP_SCRIPT"

# Apply iptables rules immediately
iptables-nft -t nat -A POSTROUTING -o $WAN_INTERFACE -j MASQUERADE 2>/dev/null || true
iptables-nft -A FORWARD -i $WIFI_INTERFACE -o $WAN_INTERFACE -j ACCEPT 2>/dev/null || true
iptables-nft -A FORWARD -i $WAN_INTERFACE -o $WIFI_INTERFACE -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

log_info "iptables and routing configured"

# ==============================================================================
# STEP 7: Configure dnsmasq
# ==============================================================================
log_info "Step 7: Configuring dnsmasq..."

cat > "$DNSMASQ_CONF" <<EOF
# dnsmasq configuration for Wi-Fi Hotspot

# Don't use /etc/resolv.conf
no-resolv

# Upstream DNS servers
server=8.8.8.8
server=8.8.4.4

# Domain to redirect to hotspot
address=/hotspot.example.com/$HOTSPOT_IP
address=/uam/$HOTSPOT_IP
# Captive portal: resolve all other names to the hotspot gateway so clients
# are always redirected to the login page until authorised
address=/#/$HOTSPOT_IP

# DHCP Range
dhcp-range=$WIFI_INTERFACE,$HOTSPOT_NETWORK.10,$HOTSPOT_NETWORK.250,12h
dhcp-option=$WIFI_INTERFACE,3,$HOTSPOT_IP
dhcp-option=$WIFI_INTERFACE,6,$HOTSPOT_IP

# Bind to Wi-Fi interface only
interface=$WIFI_INTERFACE
EOF

systemctl enable dnsmasq
systemctl restart dnsmasq

log_info "dnsmasq configured"

# ==============================================================================
# STEP 8: Create captive portal web files
# ==============================================================================
log_info "Step 8: Creating captive portal web files..."

mkdir -p "$WEB_DIR"

# Create main page
cat > "$WEB_DIR/index.html" <<'HTMLEOF'
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Wi-Fi Hotspot - Welcome</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 0; padding: 20px; background: #f5f5f5; }
        .container { max-width: 400px; margin: 50px auto; padding: 20px; background: white; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        h1 { color: #333; text-align: center; }
        .form-group { margin-bottom: 15px; }
        label { display: block; margin-bottom: 5px; font-weight: bold; }
        input[type=text], input[type=password] { width: 100%; padding: 10px; border: 1px solid #ddd; border-radius: 4px; box-sizing: border-box; }
        button { width: 100%; padding: 12px; background: #007bff; color: white; border: none; border-radius: 4px; cursor: pointer; font-size: 16px; }
        button:hover { background: #0056b3; }
        .message { padding: 10px; margin-bottom: 15px; border-radius: 4px; }
        .error { background: #f8d7da; color: #721c24; border: 1px solid #f5c6cb; }
        .success { background: #d4edda; color: #155724; border: 1px solid #c3e6cb; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Welcome to Wi-Fi Hotspot</h1>
        <div id="message"></div>
        <form id="loginForm">
            <div class="form-group">
                <label for="username">Username:</label>
                <input type="text" id="username" name="username" required>
            </div>
            <div class="form-group">
                <label for="password">Password:</label>
                <input type="password" id="password" name="password" required>
            </div>
            <button type="submit">Connect</button>
        </form>
        <p style="text-align:center; margin-top:15px; color:#666;">
            Demo: username: <strong>demo</strong>, password: <strong>demo123</strong>
        </p>
    </div>
    <script>
        document.getElementById('loginForm').addEventListener('submit', function(e) {
            e.preventDefault();
            var username = document.getElementById('username').value;
            var password = document.getElementById('password').value;
            
            var url = window.location.origin + ':3990/logon';
            var params = 'username=' + encodeURIComponent(username) + '&password=' + encodeURIComponent(password);
            
            fetch(url, {
                method: 'POST',
                headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
                body: params
            })
            .then(function(response) {
                if (response.ok) {
                    document.getElementById('message').innerHTML = '<div class="success">Login successful! You can now access the internet.</div>';
                    setTimeout(function() { window.location.href = 'http://www.google.com'; }, 1500);
                } else {
                    document.getElementById('message').innerHTML = '<div class="error">Login failed. Please check your credentials.</div>';
                }
            })
            .catch(function(error) {
                document.getElementById('message').innerHTML = '<div class="error">Connection error. Please try again.</div>';
            });
        });
    </script>
</body>
</html>
HTMLEOF

# Create prelogin page
cat > "$WEB_DIR/prelogin" <<'HTMLEOF'
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Wi-Fi Hotspot - Login Required</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 0; padding: 20px; background: #f5f5f5; }
        .container { max-width: 400px; margin: 50px auto; padding: 20px; background: white; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); text-align: center; }
        h1 { color: #333; }
        p { color: #666; }
        .redirect { margin-top: 20px; }
        .redirect a { color: #007bff; text-decoration: none; }
    </style>
</head>
<body>
    <div class="container">
        <h1>🔒 Login Required</h1>
        <p>You need to log in to access the internet.</p>
        <p>Please enter your credentials or visit the login page.</p>
        <div class="redirect">
            <a href="/uam/">Click here to log in</a>
        </div>
    </div>
</body>
</html>
HTMLEOF

# Create captive portal landing page (HTTP) with login form
mkdir -p "$WEB_DIR/uam"
cat > "$WEB_DIR/index.html" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Wi-Fi Hotspot - Вход</title>
<style>
body{font-family:Arial,sans-serif;background:#f5f5f5;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
.card{background:#fff;padding:24px;border-radius:12px;box-shadow:0 4px 12px rgba(0,0,0,0.15);width:100%;max-width:360px;text-align:center}
h2{margin-top:0}
input{width:100%;padding:10px;margin:8px 0;border:1px solid #ccc;border-radius:6px;box-sizing:border-box}
button{width:100%;padding:10px;background:#007bff;color:#fff;border:none;border-radius:6px;cursor:pointer;font-size:16px}
button:hover{background:#0056b3}
.msg{margin-top:12px;padding:8px;border-radius:6px;display:none}
.err{background:#f8d7da;color:#721c24;border:1px solid #f5c6cb}
.ok{background:#d4edda;color:#155724;border:1px solid #c3e6cb}
</style>
</head>
<body>
<div class="card">
<h2>Wi-Fi Hotspot</h2>
<p>Войдите, чтобы получить доступ в интернет</p>
<form id="f">
<input type="text" name="username" placeholder="Логин" required autofocus>
<input type="password" name="password" placeholder="Пароль" required>
<button type="submit">Войти</button>
</form>
<div class="msg err" id="e">Неверный логин или пароль</div>
<div class="msg ok" id="s">Успешно! Вы можете пользоваться интернетом.</div>
</div>
<script>
document.getElementById("f").onsubmit=function(t){t.preventDefault();var n=new FormData(this);fetch("/uam/auth.php",{method:"POST",body:n,credentials:"same-origin"}).then(function(t){return t.ok?t.text():Promise.reject(t)}).then(function(){document.getElementById("s").style.display="block";setTimeout(function(){location.href="https://www.google.com";},1500)}).catch(function(){document.getElementById("e").style.display="block"});};
</script>
</body>
</html>
HTMLEOF

# UAM login handler: radtest against FreeRADIUS (PostgreSQL)
cat > "$WEB_DIR/uam/auth.php" <<'PHPEOF'
<?php
if ($_SERVER['REQUEST_METHOD'] !== 'POST') { http_response_code(405); exit('Метод не разрешен'); }
$username = $_POST['username'] ?? '';
$password = $_POST['password'] ?? '';
if ($username === '' || $password === '') { exit('Логин и пароль обязательны'); }
$username = escapeshellarg($username);
$password = escapeshellarg($password);
$cmd = "/usr/bin/radtest $username $password 127.0.0.1 1 radtesting123";
exec($cmd . " 2>&1", $output, $returncode);
$output_str = implode("
", $output);
if ($returncode === 0 && strpos($output_str, 'Access-Accept') !== false) {
    header('Location: /uam/?success=1');
} elseif (strpos($output_str, 'Access-Reject') !== false) {
    header('Location: /uam/?error=1');
} else {
    error_log('RADIUS ошибка: ' . $output_str);
    header('Location: /uam/?error=2');
}
exit();
PHPEOF

log_info "Captive portal web files created"

# ==============================================================================
# STEP 9: Configure Nginx
# ==============================================================================
log_info "Step 9: Configuring Nginx..."

# Create Nginx configuration
PHP_FPM_SOCK=$(ls /run/php/php*-fpm.sock 2>/dev/null | head -1 || echo /run/php/php-fpm.sock)
cat > /etc/nginx/sites-available/hotspot <<EOF
server {
    listen 80 default_server;
    server_name _;
    root $WEB_DIR;
    index index.html index.php;

    # Captive portal landing page (HTTP). All client DNS resolves here.
    location / {
        try_files \$uri \$uri/ /index.html =404;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:$PHP_FPM_SOCK;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
}

server {
    listen 443 ssl default_server;
    server_name _;
    root $WEB_DIR;
    index index.html;

    ssl_certificate /etc/ssl/certs/ssl-cert-snakeoil.pem;
    ssl_certificate_key /etc/ssl/private/ssl-cert-snakeoil.key;

    location / {
        try_files \$uri \$uri/ /index.html =404;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:$PHP_FPM_SOCK;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
}
EOF
EOF

# Enable site
ln -sf /etc/nginx/sites-available/hotspot /etc/nginx/sites-enabled/
ln -sf /etc/nginx/sites-enabled/hotspot /etc/nginx/sites-enabled/hotspot 2>/dev/null || true

# Remove default site if exists
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

# Test and restart Nginx
nginx -t && systemctl restart nginx

log_info "Nginx configured"

# ==============================================================================
# STEP 10: Create test users
# ==============================================================================
log_info "Step 10: Creating test users in FreeRADIUS..."

# Add test users to RADIUS database
PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" <<EOF
DELETE FROM radcheck WHERE username IN ('demo', 'usertest');
INSERT INTO radcheck (username, attribute, op, value) VALUES
    ('demo', 'Cleartext-Password', ':=', 'demo123'),
    ('usertest', 'Cleartext-Password', ':=', 'passwd');
DELETE FROM nas WHERE nasname IN ('127.0.0.1', 'localhost');
INSERT INTO nas (nasname, shortname, type, secret, description) VALUES
    ('127.0.0.1', 'localhost', 'other', '$RADIUS_SECRET', 'Local RADIUS client'),
    ('localhost', 'localhost', 'other', '$RADIUS_SECRET', 'RADIUS Client');
EOF

log_info "Test users created: demo/demo123 and usertest/passwd"

# ==============================================================================
# STEP 11: Final verification and summary
# ==============================================================================
log_info ""
log_info "=========================================="
log_info "Wi-Fi Hotspot Installation Complete!"
log_info "=========================================="
log_info ""
log_info "Configuration Summary:"
log_info "  Wi-Fi SSID: $WIFI_SSID"
log_info "  Wi-Fi Channel: $WIFI_CHANNEL"
log_info "  Hotspot IP: $HOTSPOT_IP"
log_info "  UAM Port: $UAM_PORT"
log_info "  RADIUS Secret: $RADIUS_SECRET"
log_info ""
log_info "Test Users:"
log_info "  Username: demo, Password: demo123"
log_info "  Username: usertest, Password: passwd"
log_info ""
log_info "To start services:"
log_info "  sudo systemctl start hostapd"
log_info "  sudo systemctl start chilli"
log_info "  sudo systemctl start dnsmasq"
log_info "  sudo systemctl start nginx"
log_info ""
log_info "Web Portal: http://$HOTSPOT_IP"
log_info ""
log_info "Note: CoovaChilli must be started after network interfaces are configured."
log_info "=========================================="

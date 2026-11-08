#!/bin/bash

# Wi-Fi Hotspot with Captive Portal - Local Installation Script
# Installs and configures: CoovaChilli, hostapd, FreeRADIUS, MySQL, Nginx, dnsmasq

set -e

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

# Configuration variables
WIFI_SSID="MyWiFiHotspot"
WIFI_CHANNEL="1"
WIFI_INTERFACE="wlan0"
WAN_INTERFACE="eth0"
HOTSPOT_NETWORK="10.10.10.0"
HOTSPOT_NETMASK="255.255.255.0"
HOTSPOT_IP="10.10.10.1"
UAM_PORT="3990"
UAM_UI_PORT="4990"
RADIUS_SECRET="radtesting123"
UAM_SECRET="uamtesting123"
MYSQL_ROOT_PASSWORD="raspbian"
RADIUS_DB_PASSWORD="radtesting123"

# ==============================================================================
# STEP 1: Install required packages
# ==============================================================================
log_info "Step 1: Installing required packages..."

apt-get update

apt-get install -y \
    hostapd \
    freeradius \
    freeradius-mysql \
    mariadb-server \
    nginx \
    dnsmasq \
    php-fpm \
    php-mysql \
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
wpa=2
wpa_key_mgmt=WPA-PSK
wpa_pairwise=CCMP
rsn_pairwise=CCMP
wpa_passphrase=password123
ignore_broadcast_ssid=0
EOF

sed -i 's|^DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd 2>/dev/null || true

systemctl unmask hostapd 2>/dev/null || true
systemctl enable hostapd 2>/dev/null || true

log_info "hostapd configured"

# ==============================================================================
# STEP 3: Configure MySQL/MariaDB for FreeRADIUS
# ==============================================================================
log_info "Step 3: Configuring MySQL/MariaDB for FreeRADIUS..."

# Start MySQL service
systemctl enable mariadb
systemctl start mariadb

# Create RADIUS database and user
mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS radius;
GRANT ALL PRIVILEGES ON radius.* TO 'radius'@'localhost' IDENTIFIED BY '$RADIUS_DB_PASSWORD';
FLUSH PRIVILEGES;
EOF

# Import FreeRADIUS schema if exists
if [ -f /etc/freeradius/3.0/mods-config/sql/main/mysql/schema.sql ]; then
    mysql -u root radius < /etc/freeradius/3.0/mods-config/sql/main/mysql/schema.sql 2>/dev/null || true
fi

log_info "MySQL/MariaDB configured"

# ==============================================================================
# STEP 4: Configure FreeRADIUS
# ==============================================================================
log_info "Step 4: Configuring FreeRADIUS..."

# Configure FreeRADIUS SQL module
mkdir -p /etc/freeradius/3.0/mods-enabled
cat > /etc/freeradius/3.0/mods-enabled/sql <<EOF
sql {
    driver = "rlm_sql_mysql"
    dialect = "mysql"

    mysql {
        server = "localhost"
        port = 3306
        login = "radius"
        password = "$RADIUS_DB_PASSWORD"
        radius_db = "radius"
    }

    read_clients = yes
    client_table = "nas"
}
EOF

# Remove existing sql link if present and create new one
rm -f /etc/freeradius/3.0/mods-enabled/sql
ln -s /etc/freeradius/3.0/mods-available/sql /etc/freeradius/3.0/mods-enabled/sql

# Configure FreeRADIUS clients
if ! grep -q "client localhost" /etc/freeradius/3.0/clients.conf 2>/dev/null; then
    cat >> /etc/freeradius/3.0/clients.conf <<EOF

client localhost {
    ipaddr = 127.0.0.1
    secret = $RADIUS_SECRET
}
EOF
fi

# Update default site to use SQL
sed -i 's/^\s*-sql/#-sql/' /etc/freeradius/3.0/sites-available/default 2>/dev/null || true
sed -i 's/^\s*sql/#sql/' /etc/freeradius/3.0/sites-available/default 2>/dev/null || true

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
HS_UAMFORMAT=https://\$HS_UAMLISTEN/uam/
HS_UAMHOMEPAGE=https://\$HS_UAMLISTEN:\$HS_UAMPORT/prelogin

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
iptables -t nat -A POSTROUTING -o $WAN_INTERFACE -j MASQUERADE
iptables -A FORWARD -i $WIFI_INTERFACE -o $WAN_INTERFACE -j ACCEPT
iptables -A FORWARD -i $WAN_INTERFACE -o $WIFI_INTERFACE -m state --state RELATED,ESTABLISHED -j ACCEPT
EOF

chmod +x "$UP_SCRIPT"

# Apply iptables rules immediately
iptables -t nat -A POSTROUTING -o $WAN_INTERFACE -j MASQUERADE 2>/dev/null || true
iptables -A FORWARD -i $WIFI_INTERFACE -o $WAN_INTERFACE -j ACCEPT 2>/dev/null || true
iptables -A FORWARD -i $WAN_INTERFACE -o $WIFI_INTERFACE -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

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

# Create simple PHP login script for uam directory
mkdir -p "$WEB_DIR/uam"
cat > "$WEB_DIR/uam/index.php" <<'PHPEOF'
<?php
$challenge = $_GET['challenge'] ?? '';
$userurl = $_GET('userurl') ?? '';
?>
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Wi-Fi Hotspot Login</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 0; padding: 20px; background: #f5f5f5; }
        .container { max-width: 400px; margin: 50px auto; padding: 20px; background: white; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        h1 { color: #333; text-align: center; }
        .form-group { margin-bottom: 15px; }
        label { display: block; margin-bottom: 5px; font-weight: bold; }
        input[type=text], input[type=password] { width: 100%; padding: 10px; border: 1px solid #ddd; border-radius: 4px; box-sizing: border-box; }
        button { width: 100%; padding: 12px; background: #007bff; color: white; border: none; border-radius: 4px; cursor: pointer; font-size: 16px; }
        button:hover { background: #0056b3; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Wi-Fi Hotspot Login</h1>
        <form action="http://<?php echo $_SERVER['SERVER_ADDR']; ?>:3990/login" method="post">
            <input type="hidden" name="challenge" value="<?php echo htmlspecialchars($challenge); ?>">
            <input type="hidden" name="userurl" value="<?php echo htmlspecialchars($userurl); ?>">
            <div class="form-group">
                <label for="username">Username:</label>
                <input type="text" id="username" name="username" required>
            </div>
            <div class="form-group">
                <label for="password">Password:</label>
                <input type="password" id="password" name="password" required>
            </div>
            <button type="submit">Login</button>
        </form>
    </div>
</body>
</html>
PHPEOF

log_info "Captive portal web files created"

# ==============================================================================
# STEP 9: Configure Nginx
# ==============================================================================
log_info "Step 9: Configuring Nginx..."

# Create Nginx configuration
cat > /etc/nginx/sites-available/hotspot <<EOF
server {
    listen $HOTSPOT_IP:80;
    server_name hotspot.example.com;

    # Redirect all HTTP to HTTPS or captive portal
    return 302 http://$HOTSPOT_IP:3990/uam/;
}

server {
    listen $HOTSPOT_IP:443 ssl;
    server_name hotspot.example.com;

    root $WEB_DIR;
    index index.php index.html;

    ssl_certificate /etc/ssl/certs/ssl-cert-snakeoil.pem;
    ssl_certificate_key /etc/ssl/private/ssl-cert-snakeoil.key;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php*-fpm.sock;
    }
}
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
mysql -u root radius <<EOF
DELETE FROM radcheck WHERE username IN ('demo', 'usertest');
INSERT INTO radcheck (username, attribute, op, value) VALUES 
    ('demo', 'Cleartext-Password', ':=', 'demo123'),
    ('usertest', 'Cleartext-Password', ':=', 'passwd');
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

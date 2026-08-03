#!/bin/bash
# WiFi Hotspot Configuration Environment Variables

# Network Configuration
export HS_WANIF="eth0"                    # WAN Interface toward the Internet
export HS_LANIF="wlan0"                   # Subscriber Interface for client devices
export HS_NETWORK="10.10.10.0"           # HotSpot Network
export HS_NETMASK="255.255.255.0"        # HotSpot Network Netmask
export HS_UAMLISTEN="10.10.10.1"         # HotSpot IP Address
export HS_UAMPORT="3990"                 # HotSpot UAM Port
export HS_UAMUIPORT="4990"               # HotSpot UAM UI Port

# DNS Configuration
export HS_DNS1="10.10.10.1"              # Primary DNS (HotSpot IP)
export HS_DNS2="8.8.8.8"                 # Secondary DNS

# HotSpot Settings
export HS_NASID="nas01"                  # NAS ID
export HS_RADIUS="localhost"             # FreeRadius server
export HS_RADIUS2="localhost"            # Backup FreeRadius server
export HS_UAMALLOW="10.10.10.0/24"        # Allowed network for UAM
export HS_RADSECRET="radtesting123"      # RADIUS shared secret
export HS_UAMSECRET="uamtesting123"      # UAM secret

# Firewall Configuration
export HS_TCP_PORTS="80 443"             # Allowed TCP ports

# DHCP Configuration
export HS_DHCPIF="eth0"                  # DHCP Interface
export HS_DHCP_START="10.10.10.100"      # DHCP range start
export HS_DHCP_END="10.10.10.200"        # DHCP range end
export HS_DHCP_LEASE="86400"             # DHCP lease time (seconds)

# Database Configuration
export MYSQL_ROOT_PASSWORD="raspbian"     # MySQL root password
export RADIUS_DB_USER="appdemoradius"    # RADIUS database user
export RADIUS_DB_PASSWORD="raspbian"    # RADIUS database password
export RADIUS_DB_NAME="radius"           # RADIUS database name

# HotSpot Settings
export HOTSPOT_SSID="MME Captive Portal" # WiFi SSID
export HOTSPOT_PASSWORD="HotspotPassword" # WiFi Password

# Admin Credentials
export HS_ADMUSR="coovachillispot"       # CoovaChilli admin username
export HS_ADMPWD="coovachillispot"       # CoovaChilli admin password

# Test User
export TEST_USERNAME="usertest"          # Test username
export TEST_PASSWORD="passwd"            # Test password

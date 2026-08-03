# WiFi Hotspot Docker Setup

This guide explains how to deploy the WiFi Hotspot with Captive Portal using Docker.

## Overview

This Docker configuration provides a complete WiFi hotspot solution with:

- **CoovaChilli** - Captive portal access controller
- **hostapd** - WiFi access point software
- **FreeRADIUS** - RADIUS authentication server
- **MySQL** - Database for FreeRADIUS
- **Nginx** - Web server for the login portal
- **PHP-FPM** - PHP processing for the login page
- **dnsmasq** - DNS and DHCP server
- **hotspot-login** - Web-based login interface

## Prerequisites

### Hardware Requirements
- **WiFi Interface**: Your host system must have a wireless network interface (wlan0 or similar)
- **Docker**: Docker Engine 20.10+
- **Docker Compose**: Version 1.29+
- **Operating System**: Linux (tested on Ubuntu 20.04+)

### Important Notes

1. **Network Interface Access**: The container needs access to your host's network interfaces
2. **Privileged Mode**: The container runs in privileged mode to manage network interfaces
3. **Host Network Mode**: Uses `network_mode: host` for direct interface access

## Quick Start

### 1. Clone and Prepare

```bash
# Clone the repository
cd /root/soft/wifi-hotspot

# Create necessary directories
mkdir -p docker/data/{mysql,logs,chilli,hostapd,freeradius,nginx,dnsmasq}

# Generate SSL certificates (optional, for development)
mkdir -p docker/config/ssl
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout docker/config/ssl/snakeoil.key \
    -out docker/config/ssl/snakeoil.pem \
    -subj "/C=US/ST=State/L=City/O=Org/CN=hotspot.example.com"
```

### 2. Build and Run

```bash
# Using Makefile (recommended)
make build
make run

# Or manually with docker-compose
docker-compose build
docker-compose up -d
```

### 3. Check Status

```bash
# Check running containers
docker-compose ps

# View logs
make logs

# Or manually
docker-compose logs -f
```

### 4. Access the Hotspot

- **WiFi Network**: `MME Captive Portal` (password: `HotspotPassword`)
- **Login Page**: https://hotspot.example.com or https://10.10.10.1
- **Test Credentials**:
  - Username: `usertest`
  - Password: `passwd`

## Configuration

### Environment Variables

Edit `docker/config/env.sh` or set environment variables in `docker-compose.yml`:

```bash
# Network Configuration
HS_WANIF=eth0           # WAN interface (internet)
HS_LANIF=wlan0          # WiFi interface
HS_NETWORK=10.10.10.0   # Hotspot network
HS_NETMASK=255.255.255.0
HS_UAMLISTEN=10.10.10.1 # Hotspot IP

# RADIUS Configuration
HS_RADSECRET=radtesting123  # Shared secret
HS_UAMSECRET=uamtesting123  # UAM secret

# Database Configuration
MYSQL_ROOT_PASSWORD=raspbian
RADIUS_DB_USER=appdemoradius
RADIUS_DB_PASSWORD=raspbian
RADIUS_DB_NAME=radius

# WiFi Configuration
HOTSPOT_SSID="My Hotspot"
HOTSPOT_PASSWORD="MyPassword"
```

### Available Makefile Commands

```bash
# Build the image
make build

# Start the container
make run

# Stop the container
make stop

# Restart the container
make restart

# Open shell in container
make shell

# View logs
make logs

# Show status
make status

# Clean up (remove containers)
make clean

# Rebuild completely
make rebuild

# Generate SSL certificates
make gen-ssl

# Create data directories
make init-data
```

## Custom Configuration

### Adding Custom Config Files

Place your custom configuration files in `docker/config/` directory:

```bash
# hostapd
docker/config/hostapd/hostapd.conf

# CoovaChilli
docker/config/chilli/config
docker/config/chilli/up.sh

# FreeRADIUS
docker/config/freeradius/clients.conf

# dnsmasq
docker/config/dnsmasq.conf

# Nginx
docker/config/nginx/hotspot.example.com
```

### Custom Network Configuration

Edit the network settings in `docker/config/env.sh`:

```bash
# Change network interface names
export HS_WANIF="eth0"      # Or your WAN interface
export HS_LANIF="wlan0"     # Or your WiFi interface

# Change IP addresses
export HS_UAMLISTEN="192.168.1.1"
export HS_NETWORK="192.168.1.0"
export HS_NETMASK="255.255.255.0"
```

## Troubleshooting

### Common Issues

1. **WiFi Interface Not Found**
   ```bash
   # Check available interfaces on host
   ip link show
   
   # Update HS_LANIF in docker-compose.yml
   # Make sure your WiFi card supports AP mode
   ```

2. **Permission Issues**
   ```bash
   # Run with proper privileges
   docker-compose down
   docker-compose up -d
   ```

3. **MySQL Not Starting**
   ```bash
   # Check MySQL logs
   docker-compose logs mysql
   
   # Or in container
   make shell
   cat /var/log/mysql/error.log
   ```

4. **FreeRADIUS Connection Issues**
   ```bash
   # Test RADIUS connection
   make shell
   radtest usertest passwd localhost 0 radtesting123
   ```

5. **CoovaChilli Not Starting**
   ```bash
   # Check chilli logs
   make logs
   
   # Check configuration
   make shell
   chilli_query
   ```

### Debug Mode

Enable debug logging:

```bash
# Edit docker-compose.override.yml
environment:
  - DEBUG=1
  - LOG_LEVEL=debug

# Then rebuild and run
docker-compose down
docker-compose up -d
```

## Security Considerations

### Change Default Credentials

**IMPORTANT**: Change these default credentials before deploying to production:

```bash
# In docker/config/env.sh or docker-compose.yml
HS_RADSECRET=your_secure_radius_secret
HS_UAMSECRET=your_secure_uam_secret
MYSQL_ROOT_PASSWORD=your_secure_mysql_password
RADIUS_DB_PASSWORD=your_secure_db_password
HOTSPOT_PASSWORD=your_secure_wifi_password
```

### SSL Certificates

Replace the self-signed certificates with your own:

```bash
# Generate proper SSL certificates
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /etc/ssl/private/hotspot.key \
    -out /etc/ssl/certs/hotspot.crt \
    -subj "/C=US/ST=State/L=City/O=Org/CN=hotspot.example.com"

# Update Nginx configuration
# In docker/config/nginx/hotspot.example.com
ssl_certificate /etc/ssl/certs/hotspot.crt;
ssl_certificate_key /etc/ssl/private/hotspot.key;
```

### Firewall Rules

Ensure your host firewall allows necessary traffic:

```bash
# Allow required ports
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 1812/tcp
sudo ufw allow 1813/tcp
```

## Advanced Usage

### With daloRadius Management

The project includes an optional daloRadius management interface:

```bash
# Start with management profile
make run-mgmt

# Access daloRadius
# http://localhost:8080/daloradius
```

### Multiple WiFi Interfaces

To use multiple WiFi interfaces, modify the configuration:

```bash
# Edit docker-compose.yml
environment:
  - HS_LANIF=wlan0,wlan1
  - HS_NETWORK=10.10.10.0
  - HS_NETMASK=255.255.255.0
```

### Custom Hotspot Login Page

Replace the default hotspot-login with your custom page:

```bash
# Clone your custom login page
git clone https://github.com/your-repo/hotspot-login.git

# Copy to the container volume
cp -r hotspot-login/* docker/data/hotspot-login/

# Or mount directly in docker-compose.yml
volumes:
  - ./custom-hotspot-login:/var/www/hotspot.example.com/hotspot-login
```

## Monitoring

### Check Service Status

```bash
# In container
make shell

# Check running processes
ps aux | grep -E "(chilli|radius|mysql|nginx|hostapd|dnsmasq)"

# Check network connections
netstat -tuln
ss -tuln
```

### View Logs

```bash
# All logs
make logs

# Specific service logs
docker-compose logs -f wifi-hotspot

# Individual log files
make shell
cat /var/log/chilli.log
cat /var/log/freeradius/freeradius.log
cat /var/log/nginx/error.log
```

## Performance Optimization

### Resource Limits

Edit `docker-compose.yml` to set resource limits:

```yaml
services:
  wifi-hotspot:
    deploy:
      resources:
        limits:
          cpus: '2'
          memory: 2G
        reservations:
          cpus: '1'
          memory: 1G
```

### Database Optimization

For MySQL optimization, add to your custom MySQL configuration:

```bash
# In docker/data/mysql/my.cnf
[mysqld]
innodb_buffer_pool_size = 256M
innodb_log_file_size = 64M
max_connections = 200
```

## Deployment Scenarios

### Development Mode

```bash
# Use override file for development
docker-compose -f docker-compose.yml -f docker-compose.override.yml up -d
```

### Production Mode

```bash
# Remove development overrides
docker-compose up -d --build

# Or create production-specific compose file
cp docker-compose.yml docker-compose.prod.yml
# Edit docker-compose.prod.yml
```

### Separate Database Container

For better scalability, use a separate MySQL container:

```yaml
# In docker-compose.yml
services:
  mysql:
    image: mysql:5.7
    environment:
      MYSQL_ROOT_PASSWORD: your_password
      MYSQL_DATABASE: radius
    volumes:
      - ./docker/data/mysql:/var/lib/mysql

  wifi-hotspot:
    # ... existing config
    depends_on:
      - mysql
    environment:
      - MYSQL_HOST=mysql
```

## Testing

### Test Authentication

```bash
# Test RADIUS authentication
make shell
radtest usertest passwd localhost 0 radtesting123

# Expected output:
# Sent Access-Request Id ...
# Received Access-Accept Id ...
```

### Test Connectivity

```bash
# Test HTTP access
curl -I http://10.10.10.1

# Test HTTPS access
curl -k -I https://10.10.10.1

# Test WiFi connection
# Use a wireless client to connect to the hotspot
# You should be redirected to the login page
```

## Backup and Restore

### Backup Data

```bash
# Backup MySQL database
docker-compose exec wifi-hotspot mysqldump -u root -p raspi radius > backup.sql

# Backup configuration files
cp -r docker/data backup-data-$(date +%Y%m%d)
cp -r docker/config backup-config-$(date +%Y%m%d)
```

### Restore Data

```bash
# Restore MySQL database
cat backup.sql | docker-compose exec -T wifi-hotspot mysql -u root -p raspi radius

# Restore configuration files
cp -r backup-data-*/* docker/data/
cp -r backup-config-*/* docker/config/

# Restart container
make restart
```

## Cleanup

### Remove Containers and Images

```bash
# Stop and remove containers
make clean

# Remove images
docker rmi wifi-hotspot

# Remove volumes (WARNING: this deletes all data)
docker volume prune
```

### Reset Configuration

```bash
# Remove all configuration and data
rm -rf docker/data/*
rm -rf docker/config/*

# Reinitialize
make init-data
```

## References

- [CoovaChilli Documentation](https://coova.github.io/coova-chilli/)
- [FreeRADIUS Documentation](https://wiki.freeradius.org/)
- [hostapd Documentation](https://w1.fi/wpa_supplicant/devel/hostapd/)
- [Original Project README](../README.md)

## Support

For issues and questions:

1. Check the logs: `make logs`
2. Review the configuration files in `docker/config/`
3. Ensure your host system has the required network interfaces
4. Check that Docker has proper permissions to access network devices

## License

This Docker configuration is provided as-is under the same license as the original project.

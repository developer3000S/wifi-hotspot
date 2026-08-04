# Dockerfile for WiFi Hotspot with Captive Portal
# Based on Ubuntu 22.04 LTS (Jammy)
# FreeRADIUS 3.2.x built from source (NetworkRADIUS repo is amd64-only; host is arm64)
FROM ubuntu:22.04

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# Metadata
LABEL maintainer="wifi-hotspot-project"
LABEL description="Docker container for WiFi Hotspot with Captive Portal (CoovaChilli, FreeRADIUS 3.2.x, hostapd, Nginx, dnsmasq)"

# Install system dependencies
# Note: libpcrecpp0v5 not available in 22.04 (included in libpcre3-dev)
#       PHP 8.1 is default on Ubuntu 22.04
#       freeradius/freeradius-mysql from Ubuntu repos: sets up user, group, init.d, log dirs, config structure
#       We will then overlay with FreeRADIUS 3.2.x built from source to remove MYSQL_OPT_RECONNECT
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    wget \
    curl \
    git \
    vim \
    net-tools \
    iproute2 \
    iptables \
    ipset \
    procps \
    psmisc \
    dnsutils \
    telnet \
    less \
    build-essential \
    autoconf \
    automake \
    libtool \
    cmake \
    g++ \
    gcc \
    make \
    pkg-config \
    dpkg-dev \
    debhelper \
    devscripts \
    gengetopt \
    bash-completion \
    libssl-dev \
    libcurl4-gnutls-dev \
    libjson-c-dev \
    libltdl-dev \
    libpcre3-dev \
    libgd-dev \
    libxpm-dev \
    libgcrypt20-dev \
    nginx \
    php8.1-fpm \
    php8.1-mysql \
    php8.1-gd \
    php8.1-curl \
    php8.1-mbstring \
    php8.1-xml \
    php8.1-zip \
    mysql-server \
    mysql-client \
    freeradius \
    freeradius-mysql \
    libtalloc-dev \
    default-libmysqlclient-dev \
    libgdbm-dev \
    libcap-dev \
    dnsmasq \
    hostapd \
    ssl-cert \
    unzip && \
    rm -rf /var/lib/apt/lists/*

# Build FreeRADIUS 3.2.x from source
# This overlays the Ubuntu 3.0.x binaries with 3.2.x which has proper MySQL 8.0
# support and no MYSQL_OPT_RECONNECT deprecation.
# --with-raddbdir=/etc/freeradius/3.0 matches the Ubuntu package config path
RUN git clone --depth 1 --branch v3.2.x \
        https://github.com/FreeRADIUS/freeradius-server.git /tmp/freeradius-src && \
    cd /tmp/freeradius-src && \
    ./configure \
        --prefix=/usr \
        --sysconfdir=/etc \
        --localstatedir=/var \
        --with-raddbdir=/etc/freeradius/3.0 \
        --with-logdir=/var/log/freeradius \
        --with-mysql \
        --without-rlm_sql_postgresql \
        --without-rlm_sql_iodbc \
        --without-rlm_ldap \
        --without-rlm_eap_pwd && \
    make -j$(nproc) && \
    make install && \
    rm -rf /tmp/freeradius-src

# Clone and build CoovaChilli
RUN git clone --depth 1 https://github.com/coova/coova-chilli.git /tmp/coova-chilli && \
    cd /tmp/coova-chilli && \
    autoreconf -vif && \
    ./configure --prefix=/usr --sysconfdir=/etc/chilli --localstatedir=/var --with-openssl && \
    make && \
    make install && \
    # Register the init.d service script so `service chilli start` works
    if [ -f /etc/chilli/init.d/chilli ]; then \
        ln -sf /etc/chilli/init.d/chilli /etc/init.d/chilli && \
        update-rc.d chilli defaults 2>/dev/null || true; \
    fi && \
    rm -rf /tmp/coova-chilli

# Create necessary directories
RUN mkdir -p /etc/chilli \
    /var/run/chilli \
    /var/log/chilli \
    /var/www/hotspot.example.com \
    /etc/freeradius/3.0/mods-enabled \
    /etc/hostapd \
    /etc/dnsmasq.d

# Copy configuration files
COPY docker/config/ /etc/wifi-hotspot-config/

# Copy init script
COPY docker/init.sh /usr/local/bin/init-hotspot
RUN chmod +x /usr/local/bin/init-hotspot

# Enable services
RUN echo "START_CHILLI=1" > /etc/default/chilli

# Configure sysctl for IP forwarding
RUN echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf

# Set permissions
RUN chown -R www-data:www-data /var/www/hotspot.example.com

# Create MySQL initialization script
COPY docker/init-mysql.sh /docker-entrypoint-initdb.d/
RUN chmod +x /docker-entrypoint-initdb.d/init-mysql.sh

# Expose necessary ports
EXPOSE 80 443 3990 4990 1812 1813 3306 67/udp 53/udp

# Set entrypoint
ENTRYPOINT ["/usr/local/bin/init-hotspot"]
CMD ["start"]

# Dockerfile for WiFi Hotspot with Captive Portal
# Based on Ubuntu 20.04 LTS
FROM ubuntu:20.04

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# Metadata
LABEL maintainer="wifi-hotspot-project"
LABEL description="Docker container for WiFi Hotspot with Captive Portal (CoovaChilli, FreeRADIUS, hostapd, Nginx, dnsmasq)"

# Install system dependencies
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
    libpcrecpp0v5 \
    libgcrypt20-dev \
    nginx \
    php-fpm \
    php-mysql \
    php-gd \
    php-curl \
    php-mbstring \
    php-xml \
    php-zip \
    php-json \
    mysql-server \
    mysql-client \
    default-mysql-client \
    freeradius \
    freeradius-mysql \
    dnsmasq \
    hostapd && \
    rm -rf /var/lib/apt/lists/*

# Clone and build CoovaChilli
RUN git clone --depth 1 https://github.com/coova/coova-chilli.git /tmp/coova-chilli && \
    cd /tmp/coova-chilli && \
    autoreconf -vif && \
    ./configure --prefix=/usr --sysconfdir=/etc/chilli --localstatedir=/var --with-openssl && \
    make && \
    make install && \
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

# Create symlink for FreeRADIUS SQL module
RUN ln -sf /etc/freeradius/3.0/mods-available/sql /etc/freeradius/3.0/mods-enabled/sql

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

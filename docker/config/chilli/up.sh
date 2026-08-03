#!/bin/bash
# CoovaChilli up.sh script
# Called when chilli starts to configure firewall and routing

# Enable NAT for internet sharing
iptables -I POSTROUTING -t nat -o $HS_WANIF -j MASQUERADE

# Allow forwarding between interfaces
iptables -I FORWARD -i $HS_LANIF -j ACCEPT
iptables -I FORWARD -o $HS_LANIF -j ACCEPT

# Allow established connections
iptables -I FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

# Enable IP forwarding (also set in sysctl.conf)
echo 1 > /proc/sys/net/ipv4/ip_forward

# Log the configuration
logger "CoovaChilli: Firewall and NAT rules applied"

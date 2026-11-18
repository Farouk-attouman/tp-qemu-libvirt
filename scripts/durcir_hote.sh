#!/bin/bash

if sudo iptables -C INPUT -i virbr1 -j DROP 2>/dev/null; then
    echo "Regles deja en place"
    exit 0
fi

sudo iptables -A INPUT -i virbr1 -p udp --dport 67 -j ACCEPT
sudo iptables -A INPUT -i virbr1 -p udp --dport 53 -j ACCEPT
sudo iptables -A INPUT -i virbr1 -p tcp --dport 53 -j ACCEPT
sudo iptables -A INPUT -i virbr1 -j DROP

echo "Hote durci : lab hote limite au DHCP et au DNS"

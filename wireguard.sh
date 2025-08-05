#!/bin/bash

# Install WireGuard
sudo apt-get update
sudo apt-get install -y wireguard

# Enable IP Forwarding
echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# Generate server keys
wg genkey | sudo tee /etc/wireguard/privatekey | wg pubkey | sudo tee /etc/wireguard/publickey

# Get server private and public keys
SERVER_PRIVATE_KEY=$(sudo cat /etc/wireguard/privatekey)
SERVER_PUBLIC_KEY=$(sudo cat /etc/wireguard/publickey)
SERVER_IP=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

# Create server configuration
sudo tee /etc/wireguard/wg0.conf > /dev/null <<EOF
[Interface]
Address = 10.13.13.1/24
SaveConfig = true
ListenPort = 51820
PrivateKey = $SERVER_PRIVATE_KEY
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE
EOF

# Generate client configurations
for i in $(seq 1 ${client_count})
do
  CLIENT_PRIVATE_KEY=$(wg genkey)
  CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVATE_KEY" | wg pubkey)
  # Sequentially assign client IPs starting from 10.13.13.2
  CLIENT_IP="10.13.13.$((i+1))/32"

  # Add client peer to server config
  sudo wg set wg0 peer "$CLIENT_PUBLIC_KEY" allowed-ips "$CLIENT_IP"

  # Create client config file in the admin user's home directory
  tee /home/${admin_username}/wg0-client-$i.conf > /dev/null <<EOF
[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = $CLIENT_IP
DNS = 1.1.1.1

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
Endpoint = ${server_public_ip}:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
done

# Start WireGuard and save the final server config
sudo wg-quick up wg0
sudo wg-quick save wg0

# Enable WireGuard to start on boot
sudo systemctl enable wg-quick@wg0
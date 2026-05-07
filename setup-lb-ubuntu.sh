#!/bin/bash
# Refactored for CP-11, CP-12, CP-13 on enp1s0
# Target VIP: 192.168.122.100

# Node variables
CP1="cp-11"
CP2="cp-12"
CP3="cp-13"
INTERFACE="enp1s0"
VIP="192.168.122.100"

# 1. Pre-flight Check
if ! which kubectl > /dev/null; then
    echo "Kube-tools missing. Run setup-container.sh and setup-kubetools.sh first."
    exit 6
fi

# 2. Extract IPs from /etc/hosts
export CP1_IP=$(awk -v node="$CP1" '$2==node {print $1}' /etc/hosts | head -1)
export CP2_IP=$(awk -v node="$CP2" '$2==node {print $1}' /etc/hosts | head -1)
export CP3_IP=$(awk -v node="$CP3" '$2==node {print $1}' /etc/hosts | head -1)

# Verify all IPs resolved
for ip in "$CP1_IP" "$CP2_IP" "$CP3_IP"; do
    if [ -z "$ip" ]; then echo "Error: IP for $CP1, $CP2, or $CP3 not found in /etc/hosts"; exit 1; fi
done

# 3. Distribute SSH keys for automation
ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa <<< n
for node in $CP1 $CP2 $CP3; do ssh-copy-id "$node"; done[cite: 6]

# 4. Install Software Stack
for node in $CP1 $CP2 $CP3; do
    ssh "$node" "sudo apt update && sudo apt install -y haproxy keepalived"[cite: 1]
done

# 5. Configure keepalived Health Check
sudo chmod +x check_apiserver.sh
sudo cp check_apiserver.sh /etc/keepalived/
for node in $CP2 $CP3; do
    scp check_apiserver.sh "$node":/tmp/
    ssh "$node" "sudo cp /tmp/check_apiserver.sh /etc/keepalived/"
done

# 6. Generate Node-Specific keepalived Configs
# CP1 is Master; others are Slaves
cp keepalived.conf keepalived-$CP2.conf
cp keepalived.conf keepalived-$CP3.conf

sed -i 's/state MASTER/state SLAVE/' keepalived-$CP2.conf keepalived-$CP3.conf
sed -i 's/priority 255/priority 254/' keepalived-$CP2.conf
sed -i 's/priority 255/priority 253/' keepalived-$CP3.conf

sudo cp keepalived.conf /etc/keepalived/
scp keepalived-$CP2.conf "$CP2":/tmp/ && ssh "$CP2" "sudo cp /tmp/keepalived-$CP2.conf /etc/keepalived/keepalived.conf"
scp keepalived-$CP3.conf "$CP3":/tmp/ && ssh "$CP3" "sudo cp /tmp/keepalived-$CP3.conf /etc/keepalived/keepalived.conf"

# 7. Configure HAProxy with Dynamic IPs
sed -i "s/server control1.*/server $CP1 $CP1_IP:6443 check/" haproxy.cfg
sed -i "s/server control2.*/server $CP2 $CP2_IP:6443 check/" haproxy.cfg
sed -i "s/server control3.*/server $CP3 $CP3_IP:6443 check/" haproxy.cfg

sudo cp haproxy.cfg /etc/haproxy/
for node in $CP2 $CP3; do
    scp haproxy.cfg "$node":/tmp/
    ssh "$node" "sudo cp /tmp/haproxy.cfg /etc/haproxy/"
done

# 8. Start Services
for node in $CP1 $CP2 $CP3; do
    ssh "$node" "sudo systemctl enable --now keepalived haproxy"[cite: 1]
done

echo "LB Setup Complete. VIP: $VIP"
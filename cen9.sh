#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

random() {
    tr </dev/urandom -dc A-Za-z0-9 | head -c5
    echo
}

gen64() {
    local ip=""
    for i in {1..4}; do
        ip+="$(printf "%02x%02x%02x%02x" $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256))):"
    done
    echo "$1:${ip%:}"
}

install_3proxy() {
    echo "installing 3proxy"
    URL="https://github.com/3proxy/3proxy/archive/refs/tags/0.9.4.tar.gz"
    wget -q $URL || {
        echo "Failed to download 3proxy"
        exit 1
    }
    
    tar -xf 0.9.4.tar.gz || {
        echo "Failed to extract 3proxy"
        exit 1
    }
    
    cd 3proxy-0.9.4 || {
        echo "Failed to enter 3proxy directory"
        exit 1
    }

    # Build and install
    make -f Makefile.Linux PREFIX=/usr/local || {
        echo "Failed to build 3proxy"
        exit 1
    }
    make -f Makefile.Linux install PREFIX=/usr/local || {
        echo "Failed to install 3proxy"
        exit 1
    }
    
    # Create necessary directories
    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
    
    # Copy binary with verification
    if [ -f "/usr/local/bin/3proxy" ]; then
        cp /usr/local/bin/3proxy /usr/local/etc/3proxy/bin/
    else
        echo "3proxy binary not found after installation"
        exit 1
    fi
    
    cd $WORKDIR
    rm -f 0.9.4.tar.gz
    echo "3proxy installation completed"
}

gen_3proxy() {
    cat <<EOF
daemon
maxconn 2000
nserver 1.1.1.1
nserver 8.8.4.4
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
setgid 65535
setuid 65535
stacksize 6291456 
flush

# Authentication type strong
auth strong

users $(awk -F "/" 'BEGIN{ORS="";} {print $1 ":CL:" $2 " "}' ${WORKDATA})

$(awk -F "/" '{print "\n" \
"allow " $1 "\n" \
"proxy -6 -n -a -p" $4 " -i" $3 " -e"$5"\n" \
"flush\n"}' ${WORKDATA})
EOF
}

gen_proxy_file_for_user() {
    cat >proxy.txt <<EOF
$(awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2 }' ${WORKDATA})
EOF
    
    # Display first 10 proxies for verification
    echo "First 10 proxies (IP:PORT:LOGIN:PASS):"
    head -n 10 proxy.txt
}

gen_data() {
    seq $FIRST_PORT $LAST_PORT | while read port; do
        echo "$(random)/$(random)/$IP4/$port/$(gen64 $IP6)"
    done > $WORKDATA
}

gen_iptables() {
    cat <<EOF
    $(awk -F "/" '{print "firewall-cmd --permanent --add-port=" $4 "/tcp"}' ${WORKDATA}) 
EOF
}

gen_ifconfig() {
    cat <<EOF
$(awk -F "/" '{print "ip addr add " $5 "/64 dev '"$INTERFACE"'"}' ${WORKDATA})
EOF
}

# Install required packages
echo "Installing required packages..."
dnf -y install gcc make net-tools bsdtar zip curl firewalld || {
    echo "Failed to install required packages"
    exit 1
}

# Detect network interface (usually eth0 or ens3)
INTERFACE=$(ip -o -4 route show to default | awk '{print $5}')
echo "Detected network interface: $INTERFACE"

install_3proxy

echo "Creating working folder..."
WORKDIR="/home/bkns"
WORKDATA="${WORKDIR}/data.txt"
mkdir -p $WORKDIR && cd $_

IP4=$(curl -4 -s icanhazip.com)
if [ -z "$IP4" ]; then
    echo "Could not detect IPv4 address"
    exit 1
fi

IP6=$(curl -6 -s icanhazip.com | cut -f1-4 -d':')
if [ -z "$IP6" ]; then
    echo "Could not detect IPv6 address"
    exit 1
fi

echo "Internal ip = ${IP4}. External sub for ip6 = ${IP6}"

# Generate fewer proxies for testing
FIRST_PORT=42000
LAST_PORT=42100  # Reduced number of ports for initial testing

echo "Generating data and configuration files..."
gen_data
gen_iptables >$WORKDIR/boot_iptables.sh
gen_ifconfig >$WORKDIR/boot_ifconfig.sh
chmod +x boot_*.sh /etc/rc.local

gen_3proxy >/usr/local/etc/3proxy/3proxy.cfg

# Create systemd service with proper configuration
cat >/etc/systemd/system/3proxy.service <<EOF
[Unit]
Description=3proxy Proxy Server
After=network.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/bin/bash ${WORKDIR}/boot_iptables.sh
ExecStartPre=/bin/bash ${WORKDIR}/boot_ifconfig.sh
ExecStartPre=/usr/bin/ulimit -n 65535
ExecStart=/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg
Restart=on-failure
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

echo "Configuring firewall..."
systemctl enable --now firewalld
sleep 2  # Wait for firewalld to fully start
firewall-cmd --reload

echo "Starting 3proxy service..."
systemctl daemon-reload
systemctl enable 3proxy
sleep 2  # Wait before starting the service
systemctl start 3proxy || {
    echo "Failed to start 3proxy service. Checking status..."
    systemctl status 3proxy
    exit 1
}

echo "Generating proxy file..."
gen_proxy_file_for_user

# Clean up
rm -rf /root/3proxy-0.9.4

echo "Setup Complete!"
echo "Proxy file location: ${WORKDIR}/proxy.txt"
echo "Service status:"
systemctl status 3proxy --no-pager

# Display current IPv6 addresses
echo -e "\nConfigured IPv6 addresses:"
ip -6 addr show dev $INTERFACE | grep "inet6" || echo "No IPv6 addresses found"

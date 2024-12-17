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

    # Create installation directories
    mkdir -p /etc/3proxy/bin
    mkdir -p /etc/3proxy/logs
    mkdir -p /etc/3proxy/stat
    mkdir -p /var/log/3proxy

    # Compile with correct paths
    make -f Makefile.Linux || {
        echo "Failed to build 3proxy"
        exit 1
    }

    # Install binary and configs
    install -m 755 src/3proxy /etc/3proxy/bin/
    
    # Set proper permissions
    chmod 755 /etc/3proxy/bin/3proxy
    chmod -R 755 /etc/3proxy
    
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
    
    echo "Here are your first 10 proxies (IP:PORT:LOGIN:PASS):"
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

# Detect network interface
INTERFACE=$(ip -o -4 route show to default | awk '{print $5}')
echo "Detected network interface: $INTERFACE"

install_3proxy

echo "Creating working folder..."
WORKDIR="/home/bkns"
WORKDATA="${WORKDIR}/data.txt"
mkdir -p $WORKDIR && cd $_

IP4=$(curl -4 -s icanhazip.com)
IP6=$(curl -6 -s icanhazip.com | cut -f1-4 -d':')

echo "Internal ip = ${IP4}. External sub for ip6 = ${IP6}"

FIRST_PORT=42000
LAST_PORT=42100

gen_data
gen_iptables >$WORKDIR/boot_iptables.sh
gen_ifconfig >$WORKDIR/boot_ifconfig.sh
chmod +x boot_*.sh

gen_3proxy >/etc/3proxy/3proxy.cfg

# Create systemd service
cat >/etc/systemd/system/3proxy.service <<EOF
[Unit]
Description=3proxy Proxy Server
After=network.target
After=firewalld.service

[Service]
Type=simple
ExecStartPre=/bin/bash ${WORKDIR}/boot_iptables.sh
ExecStartPre=/bin/bash ${WORKDIR}/boot_ifconfig.sh
ExecStart=/etc/3proxy/bin/3proxy /etc/3proxy/3proxy.cfg
ExecStop=/bin/kill -TERM \$MAINPID
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "Configuring firewall..."
systemctl enable firewalld
systemctl start firewalld
sleep 2
firewall-cmd --reload

echo "Starting 3proxy service..."
systemctl daemon-reload
systemctl enable 3proxy
sleep 2
systemctl start 3proxy

gen_proxy_file_for_user

echo "Setup Complete!"
echo "Proxy file location: ${WORKDIR}/proxy.txt"
echo "Service status:"
systemctl status 3proxy --no-pager

echo -e "\nConfigured IPv6 addresses:"
ip -6 addr show dev $INTERFACE

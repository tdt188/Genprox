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

    # Create directories with proper permissions
    mkdir -p /usr/bin/3proxy
    mkdir -p /etc/3proxy
    
    # Compile
    make -f Makefile.Linux PREFIX=/usr/bin || {
        echo "Failed to build 3proxy"
        exit 1
    }

    # Install binary
    cp bin/3proxy /usr/bin/3proxy/ || {
        echo "Failed to copy 3proxy binary"
        exit 1
    }

    chmod 755 /usr/bin/3proxy/3proxy
    
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

# Log configuration
log /var/log/3proxy/3proxy.log D
logformat "- +_L%t.%. %N.%p %E %U %C:%c %R:%r %O %I %h %T"

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

echo "Installing required packages..."
dnf -y install gcc make net-tools bsdtar zip curl firewalld

# Create log directory
mkdir -p /var/log/3proxy
chmod 777 /var/log/3proxy

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

# Create systemd service with direct binary path
cat >/etc/systemd/system/3proxy.service <<EOF
[Unit]
Description=3proxy Proxy Server
After=network.target
After=firewalld.service

[Service]
Type=simple
ExecStartPre=/bin/bash ${WORKDIR}/boot_iptables.sh
ExecStartPre=/bin/bash ${WORKDIR}/boot_ifconfig.sh
ExecStart=/usr/bin/3proxy/3proxy /etc/3proxy/3proxy.cfg
Restart=always
RestartSec=3
StandardOutput=append:/var/log/3proxy/service.log
StandardError=append:/var/log/3proxy/error.log

[Install]
WantedBy=multi-user.target
EOF

echo "Configuring firewall..."
systemctl stop firewalld
systemctl start firewalld
firewall-cmd --reload

echo "Configuring IPv6..."
sysctl -w net.ipv6.conf.all.forwarding=1
sysctl -w net.ipv6.conf.default.forwarding=1

echo "Starting 3proxy service..."
systemctl daemon-reload
systemctl enable 3proxy
sleep 2
systemctl restart 3proxy || {
    echo "Service failed to start. Checking logs..."
    tail -n 50 /var/log/3proxy/3proxy.log
    tail -n 50 /var/log/3proxy/error.log
    exit 1
}

gen_proxy_file_for_user

echo -e "\nSetup Complete!"
echo "Proxy file location: ${WORKDIR}/proxy.txt"
echo "Log files:"
echo "- Service log: /var/log/3proxy/service.log"
echo "- Error log: /var/log/3proxy/error.log"
echo "- Main log: /var/log/3proxy/3proxy.log"
echo -e "\nService status:"
systemctl status 3proxy --no-pager

echo -e "\nConfigured IPv6 addresses:"
ip -6 addr show dev $INTERFACE

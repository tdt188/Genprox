#!/bin/bash
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

random() {
    tr </dev/urandom -dc A-Za-z0-9 | head -c5
    echo
}

array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
gen64() {
    ip64() {
        echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
    }
    echo "$1:$(ip64):$(ip64):$(ip64):$(ip64)"
}

install_3proxy() {
    echo "Installing 3proxy..."
    
    # Create directories
    if [ ! -d "/usr/local/etc/3proxy" ]; then
        mkdir -p /usr/local/etc/3proxy/{bin,logs,stat} || {
            echo "Failed to create 3proxy directories"
            exit 1
        }
    fi

    # Download and extract
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

    # Compile
    echo "Compiling 3proxy..."
    make -f Makefile.Linux || {
        echo "Failed to compile 3proxy"
        exit 1
    }
    
    # Verify binary exists
    if [ ! -f "src/3proxy" ]; then
        echo "3proxy binary not found after compilation"
        exit 1
    }

    # Install
    cp src/3proxy /usr/local/etc/3proxy/bin/ || {
        echo "Failed to copy 3proxy binary"
        exit 1
    }
    
    cd $WORKDIR
    rm -rf "/root/3proxy-0.9.4"
    rm -f "0.9.4.tar.gz"
    
    echo "3proxy installation completed successfully"
}

gen_3proxy() {
    cat <<EOF
daemon
maxconn 2000

nserver 1.1.1.1
nserver 1.0.0.1
nserver 2606:4700:4700::1111
nserver 2606:4700:4700::1001

nscache 65536
timeouts 1 5 30 60 180 1800 15 60

setgid 65535
setuid 65535
stacksize 6291456 

deny * * 127.0.0.1,192.168.1.1-192.168.255.255
deny * * 172.16.0.0-172.31.255.255
deny * * 10.0.0.0-10.255.255.255
deny * * ::1
allow * * * 80-88,8080-8088 HTTP
allow * * * 443,8443 HTTPS

log /usr/local/etc/3proxy/logs/3proxy.log D
logformat "- +_L%t.%. %N.%p %E %U %C:%c %R:%r %O %I %h %T"
rotate 30

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
}

gen_data() {
    seq $FIRST_PORT $LAST_PORT | while read port; do
        local USER=$(random)
        local PASS=$(random)
        echo "$USER/$PASS/$IP4/$port/$(gen64 $IP6)"
    done > $WORKDATA
}

gen_firewall() {
    cat <<EOF
    $(awk -F "/" '{print "firewall-cmd --permanent --add-port=" $4 "/tcp"}' ${WORKDATA})
EOF
}

gen_ip_addr() {
    cat <<EOF
$(awk -F "/" '{print "ip addr add " $5 "/64 dev eth0"}' ${WORKDATA})
EOF
}

gen_export_files() {
    echo "Generating export files..."
    
    # Export in IP:PORT format
    awk -F "/" '{print $3 ":" $4}' ${WORKDATA} > ${WORKDIR}/ip_port.txt
    
    # Export in IP:PORT:USER:PASS format
    awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2}' ${WORKDATA} > ${WORKDIR}/proxy_full.txt
    
    # Export in USER:PASS format
    awk -F "/" '{print $1 ":" $2}' ${WORKDATA} > ${WORKDIR}/credentials.txt
    
    # Export in USER:PASS:IP:PORT format
    awk -F "/" '{print $1 ":" $2 ":" $3 ":" $4}' ${WORKDATA} > ${WORKDIR}/proxy_user_first.txt
    
    echo "Export files generated successfully"
}

upload_proxy() {
    cd $WORKDIR || return 1
    local PASS=$(random)
    
    echo "Creating proxy archive..."
    zip --password $PASS proxy.zip proxy.txt ip_port.txt proxy_full.txt credentials.txt proxy_user_first.txt || {
        echo "Failed to create proxy archive"
        return 1
    }
    
    echo "Uploading proxy archive..."
    local RESPONSE=$(curl -F "file=@proxy.zip" https://file.io)
    echo "Upload response: $RESPONSE"

    local URL=$(echo $RESPONSE | jq -r .link)
    if [ "$URL" != "null" ]; then
        echo "Proxy is ready! Multiple formats available in the zip file"
        echo "Download zip archive from: ${URL}"
        echo "Password: ${PASS}"
    else
        echo "Failed to upload the proxy list."
        return 1
    fi
}

configure_selinux() {
    echo "Configuring SELinux..."
    
    # Install SELinux utilities if not present
    dnf -y install policycoreutils-python-utils || {
        echo "Failed to install SELinux utilities"
        return 1
    }

    # Set SELinux contexts
    semanage fcontext -a -t bin_t "/usr/local/etc/3proxy/bin(/.*)?"
    semanage fcontext -a -t etc_t "/usr/local/etc/3proxy/3proxy.cfg"
    semanage fcontext -a -t var_log_t "/usr/local/etc/3proxy/logs(/.*)?"
    
    # Apply contexts
    restorecon -Rv /usr/local/etc/3proxy/
    
    # Allow 3proxy to bind to network ports
    setsebool -P nis_enabled 1
    
    echo "SELinux configuration completed"
}

configure_system_limits() {
    echo "Configuring system limits..."
    cat >> /etc/security/limits.conf <<EOF
*               soft    nofile          65535
*               hard    nofile          65535
EOF
}

configure_ipv6() {
    echo "Configuring IPv6..."
    cat > /etc/sysctl.d/10-ipv6-privacy.conf <<EOF
net.ipv6.conf.all.use_tempaddr = 0
net.ipv6.conf.default.use_tempaddr = 0
EOF
    sysctl -p /etc/sysctl.d/10-ipv6-privacy.conf
}

# Main setup
echo "Starting proxy setup..."

# Check if running as root
if [ "$(id -u)" != "0" ]; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

echo "Installing required packages..."
dnf -y install gcc make net-tools libarchive curl zip jq perl gcc-c++ || {
    echo "Failed to install required packages"
    exit 1
}

# Create working directory
echo "Setting up working directory..."
WORKDIR="/home/bkns"
WORKDATA="${WORKDIR}/data.txt"
mkdir -p "$WORKDIR" || {
    echo "Failed to create working directory"
    exit 1
}
cd "$WORKDIR" || exit 1

# Get IP addresses
echo "Getting IP addresses..."
IP4=$(curl -4 -s icanhazip.com)
IP6=$(curl -6 -s icanhazip.com | cut -f1-4 -d':')

if [ -z "$IP4" ] || [ -z "$IP6" ]; then
    echo "Failed to get IP addresses"
    exit 1
fi

echo "Internal ip = ${IP4}. External sub for ip6 = ${IP6}"

FIRST_PORT=42000
LAST_PORT=43999

# Generate configuration files
echo "Generating configuration files..."
gen_data
gen_firewall >$WORKDIR/firewall_rules.sh
gen_ip_addr >$WORKDIR/ip_addr.sh
chmod +x firewall_rules.sh ip_addr.sh

# Install and configure 3proxy
install_3proxy
gen_3proxy >/usr/local/etc/3proxy/3proxy.cfg

# Create systemd service
echo "Creating systemd service..."
cat >/etc/systemd/system/3proxy.service <<EOF
[Unit]
Description=3proxy Proxy Server
After=network.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/bin/bash ${WORKDIR}/firewall_rules.sh
ExecStartPre=/bin/bash ${WORKDIR}/ip_addr.sh
ExecStartPre=/usr/bin/ulimit -n 65535
ExecStart=/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg
Restart=on-failure
RestartSec=5s

PrivateTmp=true
ProtectSystem=full
ProtectHome=true
NoNewPrivileges=true
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

# Configure system
echo "Configuring firewall..."
systemctl enable --now firewalld
firewall-cmd --reload

echo "Configuring system..."
configure_selinux
configure_system_limits
configure_ipv6

echo "Starting 3proxy service..."
systemctl enable --now 3proxy.service || {
    echo "Failed to start 3proxy service"
    exit 1
}

# Generate proxy files
echo "Generating proxy files..."
gen_proxy_file_for_user
gen_export_files

# Upload proxy files
upload_proxy

echo -e "\nSetup Complete!"
echo "Proxy files have been exported in multiple formats:"
echo "1. ip_port.txt - IP:PORT format"
echo "2. proxy_full.txt - IP:PORT:USER:PASS format"
echo "3. credentials.txt - USER:PASS format"
echo "4. proxy_user_first.txt - USER:PASS:IP:PORT format"
echo "All files are included in the uploaded zip archive"

# Check service status
echo -e "\nChecking 3proxy service status:"
systemctl status 3proxy.service

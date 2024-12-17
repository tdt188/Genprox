#!/bin/sh
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
    echo "installing 3proxy"
    URL="https://github.com/3proxy/3proxy/archive/refs/tags/0.9.4.tar.gz"
    wget $URL 
    tar -xvf 0.9.4.tar.gz
    cd 3proxy-0.9.4
    
    mkdir -p build
    cd build
    cmake ..
    make
    make install
    
    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
    cp /usr/local/bin/3proxy /usr/local/etc/3proxy/bin/
    
    cd $WORKDIR
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
    # Export in IP:PORT format
    awk -F "/" '{print $3 ":" $4}' ${WORKDATA} > ${WORKDIR}/ip_port.txt
    
    # Export in IP:PORT:USER:PASS format
    awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2}' ${WORKDATA} > ${WORKDIR}/proxy_full.txt
    
    # Export in USER:PASS format
    awk -F "/" '{print $1 ":" $2}' ${WORKDATA} > ${WORKDIR}/credentials.txt
    
    # Export in USER:PASS:IP:PORT format
    awk -F "/" '{print $1 ":" $2 ":" $3 ":" $4}' ${WORKDATA} > ${WORKDIR}/proxy_user_first.txt
}

upload_proxy() {
    cd $WORKDIR
    local PASS=$(random)
    zip --password $PASS proxy.zip proxy.txt ip_port.txt proxy_full.txt credentials.txt proxy_user_first.txt
    local RESPONSE=$(curl -F "file=@proxy.zip" https://file.io)
    echo "Upload response: $RESPONSE"

    local URL=$(echo $RESPONSE | jq -r .link)
    if [ "$URL" != "null" ]; then
        echo "Proxy is ready! Multiple formats available in the zip file"
        echo "Download zip archive from: ${URL}"
        echo "Password: ${PASS}"
    else
        echo "Failed to upload the proxy list."
    fi
}

configure_selinux() {
    dnf -y install policycoreutils-python-utils
    semanage fcontext -a -t bin_t "/usr/local/etc/3proxy/bin(/.*)?"
    semanage fcontext -a -t etc_t "/usr/local/etc/3proxy/3proxy.cfg"
    semanage fcontext -a -t var_log_t "/usr/local/etc/3proxy/logs(/.*)?"
    restorecon -Rv /usr/local/etc/3proxy/
    setsebool -P nis_enabled 1
}

configure_system_limits() {
    cat >> /etc/security/limits.conf <<EOF
*               soft    nofile          65535
*               hard    nofile          65535
EOF
}

configure_ipv6() {
    cat > /etc/sysctl.d/10-ipv6-privacy.conf <<EOF
net.ipv6.conf.all.use_tempaddr = 0
net.ipv6.conf.default.use_tempaddr = 0
EOF
    sysctl -p /etc/sysctl.d/10-ipv6-privacy.conf
}

echo "Installing required packages..."
dnf -y install gcc make net-tools libarchive curl zip jq cmake openssl-devel perl gcc-c++ >/dev/null

install_3proxy

echo "working folder = /home/bkns"
WORKDIR="/home/bkns"
WORKDATA="${WORKDIR}/data.txt"
mkdir -p $WORKDIR && cd $_

IP4=$(curl -4 -s icanhazip.com)
IP6=$(curl -6 -s icanhazip.com | cut -f1-4 -d':')

echo "Internal ip = ${IP4}. External sub for ip6 = ${IP6}"

FIRST_PORT=42000
LAST_PORT=43999

gen_data >$WORKDIR/data.txt
gen_firewall >$WORKDIR/firewall_rules.sh
gen_ip_addr >$WORKDIR/ip_addr.sh
chmod +x firewall_rules.sh ip_addr.sh

gen_3proxy >/usr/local/etc/3proxy/3proxy.cfg

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

systemctl enable --now firewalld
firewall-cmd --reload

configure_selinux
configure_system_limits
configure_ipv6

systemctl enable --now 3proxy.service

gen_proxy_file_for_user
gen_export_files
rm -rf /root/3proxy-0.9.4
upload_proxy

echo "Setup Complete!"
echo "Proxy files have been exported in multiple formats:"
echo "1. ip_port.txt - IP:PORT format"
echo "2. proxy_full.txt - IP:PORT:USER:PASS format"
echo "3. credentials.txt - USER:PASS format"
echo "4. proxy_user_first.txt - USER:PASS:IP:PORT format"
echo "All files are included in the uploaded zip archive"

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
    wget -q $URL 
    tar -xf 0.9.4.tar.gz
    cd 3proxy-0.9.4
    make -f Makefile.Linux
    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
    cp src/3proxy /usr/local/etc/3proxy/bin/
    cd $WORKDIR
    rm -f 0.9.4.tar.gz
}

gen_3proxy() {
    cat <<EOF
daemon
maxconn 2000
nserver 1.1.1.1
nserver 1.0.0.1
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
}

gen_data() {
    seq $FIRST_PORT $LAST_PORT | while read port; do
        echo "$(random)/$(random)/$IP4/$port/$(gen64 $IP6)"
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

upload_proxy() {
    cd $WORKDIR
    local PASS=$(random)
    zip --password $PASS proxy.zip proxy.txt
    local RESPONSE=$(curl -F "file=@proxy.zip" https://file.io)
    echo "Upload response: $RESPONSE"

    local URL=$(echo $RESPONSE | jq -r .link)
    if [ "$URL" != "null" ]; then
        echo "Proxy is ready! Format IP:PORT:LOGIN:PASS"
        echo "Download zip archive from: ${URL}"
        echo "Password: ${PASS}"
    else
        echo "Failed to upload the proxy list."
    fi
}

echo "installing apps"
dnf -y install gcc make net-tools curl zip jq

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
gen_firewall >$WORKDIR/boot_iptables.sh
gen_ip_addr >$WORKDIR/boot_ifconfig.sh
chmod +x boot_*.sh

gen_3proxy >/usr/local/etc/3proxy/3proxy.cfg

cat >/etc/systemd/system/3proxy.service <<EOF
[Unit]
Description=3proxy Proxy Server
After=network.target

[Service]
Type=simple
ExecStartPre=/bin/bash ${WORKDIR}/boot_iptables.sh
ExecStartPre=/bin/bash ${WORKDIR}/boot_ifconfig.sh
ExecStartPre=/usr/bin/ulimit -n 65535
ExecStart=/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl enable --now firewalld
firewall-cmd --reload

systemctl enable --now 3proxy.service

gen_proxy_file_for_user
rm -rf /root/3proxy-0.9.4
upload_proxy

echo "Setup Complete!"

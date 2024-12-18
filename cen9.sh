#!/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

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
    URL="https://github.com/z3APA3A/3proxy/archive/3proxy-0.8.6.tar.gz"
    dnf install -y wget make gcc net-tools zip jq bsdtar curl firewalld
    systemctl enable --now firewalld
    wget $URL 
    tar -xvf 3proxy-*
    cd 3proxy-3proxy-0.8.6
    make -f Makefile.Linux
    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
    cp src/3proxy /usr/local/etc/3proxy/bin/
    cd $WORKDIR
}

gen_3proxy() {
    cat <<EOF
daemon
maxconn 2000
nserver 1.1.1.1
nserver 8.8.4.4
nserver 2001:4860:4860::8888
nserver 2001:4860:4860::8844
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
        local USER=$(random)
        local PASS=$(random)
        echo "$USER/$PASS/$IP4/$port/$(gen64 $IP6)"
    done > $WORKDATA
}

gen_firewalld() {
    echo "#!/bin/sh" > $WORKDIR/boot_firewalld.sh
    awk -F "/" '{print "firewall-cmd --permanent --add-port="$4"/tcp"}' ${WORKDATA} >> $WORKDIR/boot_firewalld.sh
    echo "firewall-cmd --reload" >> $WORKDIR/boot_firewalld.sh
    chmod +x $WORKDIR/boot_firewalld.sh
}

gen_ip6_config() {
    echo "#!/bin/sh" > $WORKDIR/boot_ifconfig.sh
    awk -F "/" '{print "ip -6 addr add " $5 "/64 dev eth0"}' ${WORKDATA} >> $WORKDIR/boot_ifconfig.sh
    chmod +x $WORKDIR/boot_ifconfig.sh
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

#################################
# Main Execution Starts Here
#################################

echo "installing apps"
WORKDIR="/home/bkns"
WORKDATA="${WORKDIR}/data.txt"
mkdir -p $WORKDIR && cd $WORKDIR

IP4=$(curl -4 -s icanhazip.com)
IP6=$(curl -6 -s icanhazip.com | cut -f1-4 -d':')

echo "Internal ip = ${IP4}. External sub for ip6 = ${IP6}"

FIRST_PORT=42000
LAST_PORT=43999

install_3proxy
gen_data > $WORKDATA
gen_firewalld
gen_ip6_config

gen_3proxy > /usr/local/etc/3proxy/3proxy.cfg

gen_proxy_file_for_user
rm -rf /root/3proxy-3proxy-0.8.6

# Create a systemd unit to run setup (ports & IPv6) at boot
cat >/etc/systemd/system/3proxy-setup.service <<EOF
[Unit]
Description=3Proxy Setup Service
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash $WORKDIR/boot_firewalld.sh
ExecStart=/bin/bash $WORKDIR/boot_ifconfig.sh
ExecStart=/usr/bin/ulimit -n 10048
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable 3proxy-setup.service
systemctl start 3proxy-setup.service

# Create a systemd unit to run 3proxy after setup
cat >/etc/systemd/system/3proxy.service <<EOF
[Unit]
Description=3proxy Proxy Server
After=3proxy-setup.service
Wants=3proxy-setup.service

[Service]
Type=simple
ExecStart=/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable 3proxy.service
systemctl start 3proxy.service

upload_proxy
echo "Starting Proxy"

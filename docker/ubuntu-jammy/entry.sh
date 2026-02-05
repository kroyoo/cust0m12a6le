#!/usr/bin/env bash

start_xrdp_services() {
    # Preventing xrdp startup failure
    rm -rf /var/run/xrdp-sesman.pid
    rm -rf /var/run/xrdp.pid
    rm -rf /var/run/xrdp/xrdp-sesman.pid
    rm -rf /var/run/xrdp/xrdp.pid

    # Use exec ... to forward SIGNAL to child processes
    xrdp-sesman && exec xrdp -n
}

stop_xrdp_services() {
    xrdp --kill
    xrdp-sesman --kill
    exit 0
}

echo 'start at: '`date` > /tmp/entry-start.log
echo 'start wireproxy' >> /tmp/entry-start.log

nohup /usr/local/bin/wireproxy -c  /etc/wireguard/wgcf-profile.conf 2>&1 &

echo -e "starting xrdp services...\n"
echo 'start xrdp ...' >> /tmp/entry-start.log

trap "stop_xrdp_services" SIGKILL SIGTERM SIGHUP SIGINT EXIT
start_xrdp_services

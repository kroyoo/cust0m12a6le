#!/usr/bin/env bash

pre_check()
{
  apt-get -y update
  apt-get -y autoremove
  apt-get -yf install
  apt-get -y upgrade

  pkgList="debian-keyring debian-archive-keyring build-essential gcc g++ make cmake autoconf libjpeg62-turbo-dev libjpeg-dev libpng-dev libgd-dev libxml2 libxml2-dev zlib1g zlib1g-dev libc6 libc6-dev libc-client2007e-dev libglib2.0-0 libglib2.0-dev bzip2 libzip-dev libbz2-1.0 libncurses5 libncurses5-dev libaio1 libaio-dev numactl libreadline-dev curl libcurl3-gnutls libcurl4-openssl-dev e2fsprogs libkrb5-3 libkrb5-dev libltdl-dev openssl net-tools libssl-dev libtool libevent-dev bison re2c libsasl2-dev libxslt1-dev libicu-dev locales patch vim zip unzip tmux htop bc dc expect libexpat1-dev libonig-dev libtirpc-dev git lsof lrzsz rsyslog cron logrotate chrony libsqlite3-dev psmisc wget sysv-rc apt-transport-https ca-certificates software-properties-common gnupg luajit"

  for Package in ${pkgList}; do
    apt-get --no-install-recommends -y install ${Package}
  done

}

download()
{
  git clone https://github.com/leev/ngx_http_geoip2_module
  
  git clone https://github.com/yaoweibin/ngx_http_substitutions_filter_module
  
  wget -O pcre-8.45.tar.gz https://psychz.dl.sourceforge.net/project/pcre/pcre/8.45/pcre-8.45.tar.gz?viasf=1
  
  wget -O libmaxminddb-latest.tar.gz $(wget -qO - https://api.github.com/repos/maxmind/libmaxminddb/releases/latest | grep "browser_download_url" | cut -d '"' -f 4)

  wget -O jemalloc-latest.tar.bz2 $(wget -qO - https://api.github.com/repos/jemalloc/jemalloc/releases/latest | grep "browser_download_url" | cut -d '"' -f 4)

  wget https://github.com/openssl/openssl/releases/download/OpenSSL_1_1_1w/openssl-1.1.1w.tar.gz
  
  wget https://openresty.org/download/openresty-1.25.3.2.tar.gz

}

pre_install()
{}

rename_ngx()
{}

install()
{
  ./configure  --prefix=/usr/local/openresty --with-cc-opt=-O2 --user=www --group=www --with-http_stub_status_module --with-http_sub_module --with-http_v2_module --with-http_ssl_module --with-http_gzip_static_module --with-http_gunzip_module --with-http_realip_module --with-http_flv_module --with-http_mp4_module --with-openssl=../openssl-1.1.1w --with-pcre=../pcre-8.45 --with-pcre-jit --with-ld-opt='-ljemalloc -Wl,-u,pcre_version' --add-module=../ngx_http_geoip2_module --add-module=../ngx_http_substitutions_filter_module --with-stream_ssl_module --with-stream_ssl_preread_module --with-openssl-opt=-g --with-pcre-opt=-g --with-stream
make && make install

  cat > /lib/systemd/system/nginx.service << EOF
[Unit]
Description=nginx - high performance web server
Documentation=http://nginx.org/en/docs/
After=network.target

[Service]
Type=forking
PIDFile=/var/run/nginx.pid
ExecStartPost=/bin/sleep 0.1
ExecStartPre=/usr/local/openresty/nginx/sbin/nginx -t -c /usr/local/openresty/nginx/conf/nginx.conf
ExecStart=/usr/local/openresty/nginx/sbin/nginx -c /usr/local/openresty/nginx/conf/nginx.conf
ExecReload=/bin/kill -s HUP $MAINPID
ExecStop=/bin/kill -s QUIT $MAINPID
TimeoutStartSec=120
LimitNOFILE=1000000
LimitNPROC=1000000
LimitCORE=1000000

[Install]
WantedBy=multi-user.target
EOF

  useradd -r -s /bin/false www
  systemctl enable nginx
  systemctl start nginx

}

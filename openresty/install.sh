#!/usr/bin/env bash


openresty_version=1.27.1.2
openssl_version=3.4.1
pcre_version=10.44
jemalloc_version=5.3.0
libmaxminddb_version=1.12.2
nginx_version=1.27.1

pre_check()
{
  source /etc/os-release
  case $ID in
  debian|ubuntu)
    apt-get -y update
    apt-get -y autoremove
    apt-get -yf install
    apt-get -y upgrade

    pkgList="debian-keyring debian-archive-keyring build-essential gcc g++ make cmake autoconf libjpeg62-turbo-dev libjpeg-dev libpng-dev libgd-dev libxml2 libxml2-dev zlib1g zlib1g-dev libc6 libc6-dev libc-client2007e-dev libglib2.0-0 libglib2.0-dev bzip2 libzip-dev libbz2-1.0 libncurses5 libncurses5-dev libaio1 libaio-dev numactl libreadline-dev curl libcurl3-gnutls libcurl4-openssl-dev e2fsprogs libkrb5-3 libkrb5-dev libltdl-dev openssl net-tools libssl-dev libtool libevent-dev bison re2c libsasl2-dev libxslt1-dev libicu-dev locales patch vim zip unzip tmux htop bc dc expect libexpat1-dev libonig-dev libtirpc-dev git lsof lrzsz rsyslog cron logrotate chrony libsqlite3-dev psmisc wget sysv-rc apt-transport-https ca-certificates software-properties-common gnupg "

    for Package in ${pkgList}; do
      apt-get --no-install-recommends -y install ${Package}
    done
  ;;
  *)
    exit 1
  ;;
  esac
  clear
}

download()
{
  git clone https://github.com/leev/ngx_http_geoip2_module

  git clone https://github.com/yaoweibin/ngx_http_substitutions_filter_module

  #wget -O pcre-${pcre_version}.tar.gz  $(wget -qO - https://api.github.com/repos/PCRE2Project/pcre2/releases/lastst | grep "browser_download_url" | cut -d '"' -f 4)
  wget https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${pcre_version}/pcre2-${pcre_version}.tar.gz


  #wget -O libmaxminddb-latest.tar.gz $(wget -qO - https://api.github.com/repos/maxmind/libmaxminddb/releases/latest | grep "browser_download_url" | cut -d '"' -f 4)
  wget https://github.com/maxmind/libmaxminddb/releases/download/${libmaxminddb_version}/libmaxminddb-${libmaxminddb_version}.tar.gz

  #wget -O jemalloc-latest.tar.bz2 $(wget -qO - https://api.github.com/repos/jemalloc/jemalloc/releases/latest | grep "browser_download_url" | cut -d '"' -f 4)
  wget https://github.com/jemalloc/jemalloc/releases/download/${jemalloc_version}/jemalloc-${jemalloc_version}.tar.bz2

  # https://github.com/openssl/openssl/releases/download/openssl-3.4.1/openssl-3.4.1.tar.gz
  wget https://github.com/openssl/openssl/releases/download/openssl-${openssl_version}/openssl-${openssl_version}.tar.gz

  wget https://openresty.org/download/openresty-${openresty_version}.tar.gz

}

pre_install()
{

  tar xvf pcre2-${pcre_version}.tar.gz
  tar xvf openresty-${openresty_version}.tar.gz
  tar xvf openssl-${openssl_version}.tar.gz

  echo "pre_install"
  tar xjvf jemalloc-${jemalloc_version}.tar.bz2
  cd jemalloc-${jemalloc_version}
  ./configure
  make && make install
  ln -s /usr/local/lib/libjemalloc.so.2 /usr/lib/libjemalloc.so.1
  [ -z "`grep /usr/local/lib /etc/ld.so.conf.d/*.conf`" ] && echo '/usr/local/lib' > /etc/ld.so.conf.d/local.conf
  ldconfig
  cd ..

  tar xvf libmaxminddb-${libmaxminddb_version}.tar.gz
  cd libmaxminddb-${libmaxminddb_version}
  ./configure
  make && make install
  ldconfig
  cd ..

}



rename_ngx()
{
  cd openresty-${openresty_version}
  sed -i 's/"openresty\/.*"/"Fungit"/' bundle/nginx-${nginx_version}/src/core/nginx.h
  sed -i 's/#define NGINX_VAR          "NGINX"/#define NGINX_VAR          "Fungit"/' bundle/nginx-${nginx_version}/src/core/nginx.h
  sed -i 's/#define NGINX_VER_BUILD    NGINX_VER " (" NGX_BUILD ")"/#define NGINX_VER_BUILD    NGINX_VER/' bundle/nginx-${nginx_version}/src/core/nginx.h
  sed -i 's/"Server: openresty"/"Server: Fungit"/' bundle/nginx-${nginx_version}/src/http/ngx_http_header_filter_module.c
  sed -i 's/"<hr><center>openresty<\/center>"/"<hr><center>Fungit<\/center>"/'  bundle/nginx-${nginx_version}/src/http/ngx_http_special_response.c
  sed -i 's/"server: nginx/"server: Fungit/' bundle/nginx-${nginx_version}/src/http/v2/ngx_http_v2_filter_module.c
  sed -i 's/"openresty"/"Fungit"/' bundle/nginx-${nginx_version}/src/http/v3/ngx_http_v3_filter_module.c
  cd ..
}


install()
{
  cd openresty-${openresty_version}

  ./configure  --prefix=/usr/local/openresty --with-cc-opt=-O2 --user=www --group=www --with-http_stub_status_module --with-http_sub_module --with-http_v2_module --with-http_ssl_module --with-http_gzip_static_module --with-http_gunzip_module --with-http_realip_module --with-http_flv_module --with-http_mp4_module --with-openssl=../openssl-${openssl_version} --with-pcre=../pcre2-${pcre_version} --with-pcre-jit --with-ld-opt='-ljemalloc' --add-module=../ngx_http_geoip2_module --add-module=../ngx_http_substitutions_filter_module --with-stream_ssl_module --with-stream_ssl_preread_module --with-openssl-opt=-g --with-pcre-opt=-g --with-stream

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

pre_check
download
pre_install
rename_ngx
install

#!/usr/bin/env bash

# OpenResty 编译安装脚本
# 仅适用于 Debian/Ubuntu 系统

# 软件版本配置
openresty_version=1.27.1.2
openssl_version=3.4.1
pcre_version=10.44
jemalloc_version=5.3.0
libmaxminddb_version=1.12.2
nginx_version=1.27.1

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# 时间戳变量
START_TIME=0
OPENRESTY_START_TIME=0
OPENRESTY_END_TIME=0
END_TIME=0

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 错误处理函数
handle_error() {
    log_error "脚本执行失败，错误发生在第 $1 行"
    exit 1
}

# 格式化时间函数
format_time() {
    local T=$1
    local D=$((T/60/60/24))
    local H=$((T/60/60%24))
    local M=$((T/60%60))
    local S=$((T%60))
    
    [[ $D > 0 ]] && printf '%d天 ' $D
    [[ $H > 0 ]] && printf '%d小时 ' $H
    [[ $M > 0 ]] && printf '%d分 ' $M
    printf '%d秒' $S
}

# 注册错误处理
trap 'handle_error $LINENO' ERR

# 创建工作目录
WORKDIR=$(mktemp -d -t openresty-build-XXXXXXXXXX)
cd "$WORKDIR" || exit 1
log_info "创建工作目录: $WORKDIR"

# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 检查是否为root用户
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "请使用root用户运行此脚本"
        exit 1
    fi
}

# 清理函数
cleanup() {
    log_info "开始清理工作目录..."
    cd /
    if [ -d "$WORKDIR" ]; then
        rm -rf "$WORKDIR"
        log_info "工作目录已清理"
    fi
    
    # 计算总运行时间
    END_TIME=$(date +%s)
    TOTAL_TIME=$((END_TIME - START_TIME))
    OPENRESTY_TIME=$((OPENRESTY_END_TIME - OPENRESTY_START_TIME))
    
    echo "====================================================="
    echo -e "${GREEN}脚本执行统计:${NC}"
    echo "OpenResty 编译时间: $(format_time $OPENRESTY_TIME)"
    echo "脚本总运行时间: $(format_time $TOTAL_TIME)"
    echo "====================================================="
}

# 注册清理函数
trap cleanup EXIT

# 创建 Nginx 用户
create_nginx_user() {
    log_info "创建 Nginx 用户和组..."
    if ! id -u www >/dev/null 2>&1; then
        useradd -r -s /bin/false www
    fi
}

# 将nginx添加到PATH
add_nginx_to_path() {
    log_info "将 Nginx 添加到系统 PATH..."
    
    # 创建软链接
    if [ ! -e /usr/bin/nginx ]; then
        ln -s /usr/local/openresty/nginx/sbin/nginx /usr/bin/nginx
        log_info "已创建 Nginx 软链接: /usr/bin/nginx"
    else
        log_warn "Nginx 软链接已存在，跳过创建"
    fi
    
    # 验证nginx是否可用
    if command_exists nginx; then
        log_info "Nginx 已成功添加到 PATH"
    else
        log_error "添加 Nginx 到 PATH 失败"
        exit 1
    fi
}

# 前置检查
pre_check() {
    log_info "开始环境检查..."
    check_root
    
    # 检测操作系统
    if [ -f /etc/os-release ]; then
        source /etc/os-release
        case $ID in
        debian|ubuntu)
            OS_TYPE="debian"
            log_info "检测到 $PRETTY_NAME 系统"
            ;;
        *)
            log_error "不支持的操作系统，本脚本仅支持 Debian/Ubuntu 系统"
            exit 1
            ;;
        esac
    else
        log_error "无法检测操作系统类型"
        exit 1
    fi
    
    # 更新软件包列表
    log_info "更新软件包列表..."
    apt-get -y update
    
    # 自动移除不需要的包
    log_info "自动移除不需要的包..."
    apt-get -y autoremove
    
    # 修复依赖问题
    log_info "修复依赖问题..."
    apt-get -yf install
    
    # 升级现有软件包
    log_info "升级现有软件包..."
    apt-get -y upgrade
    
    # 安装编译依赖
    log_info "安装编译依赖..."
    pkgList="debian-keyring debian-archive-keyring build-essential gcc g++ make cmake autoconf libjpeg62-turbo-dev libjpeg-dev libpng-dev libgd-dev libxml2 libxml2-dev zlib1g zlib1g-dev libc6 libc6-dev libc-client2007e-dev libglib2.0-0 libglib2.0-dev bzip2 libzip-dev libbz2-1.0 libncurses5 libncurses5-dev libaio1 libaio-dev numactl libreadline-dev curl libcurl3-gnutls libcurl4-openssl-dev e2fsprogs libkrb5-3 libkrb5-dev libltdl-dev openssl net-tools libssl-dev libtool libevent-dev bison re2c libsasl2-dev libxslt1-dev libicu-dev locales patch vim zip unzip tmux htop bc dc expect libexpat1-dev libonig-dev libtirpc-dev git lsof lrzsz rsyslog cron logrotate chrony libsqlite3-dev psmisc wget sysv-rc apt-transport-https ca-certificates software-properties-common gnupg"

    for Package in ${pkgList}; do
        log_info "安装 $Package..."
        apt-get --no-install-recommends -y install ${Package}
    done
    
    log_info "环境检查完成"
    clear
}

# 下载源码
download() {
    log_info "开始下载源码..."
    
    # 创建源码目录
    mkdir -p src
    cd src || exit 1
    
    # 下载第三方模块
    log_info "下载 ngx_http_geoip2_module..."
    git clone https://github.com/leev/ngx_http_geoip2_module
    
    log_info "下载 ngx_http_substitutions_filter_module..."
    git clone https://github.com/yaoweibin/ngx_http_substitutions_filter_module
    
    # 下载依赖库
    log_info "下载 PCRE2 $pcre_version..."
    wget -q -O pcre2-${pcre_version}.tar.gz https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${pcre_version}/pcre2-${pcre_version}.tar.gz
    
    log_info "下载 libmaxminddb $libmaxminddb_version..."
    wget -q -O libmaxminddb-${libmaxminddb_version}.tar.gz https://github.com/maxmind/libmaxminddb/releases/download/${libmaxminddb_version}/libmaxminddb-${libmaxminddb_version}.tar.gz
    
    log_info "下载 jemalloc $jemalloc_version..."
    wget -q -O jemalloc-${jemalloc_version}.tar.bz2 https://github.com/jemalloc/jemalloc/releases/download/${jemalloc_version}/jemalloc-${jemalloc_version}.tar.bz2
    
    log_info "下载 OpenSSL $openssl_version..."
    wget -q -O openssl-${openssl_version}.tar.gz https://github.com/openssl/openssl/releases/download/openssl-${openssl_version}/openssl-${openssl_version}.tar.gz
    
    log_info "下载 OpenResty $openresty_version..."
    wget -q -O openresty-${openresty_version}.tar.gz https://openresty.org/download/openresty-${openresty_version}.tar.gz
    
    log_info "源码下载完成"
    cd ..
}

# 预安装依赖库
pre_install() {
    log_info "开始安装依赖库..."
    cd src || exit 1
    
    # 解压源码包
    log_info "解压 PCRE2..."
    tar xzf pcre2-${pcre_version}.tar.gz
    
    log_info "解压 OpenResty..."
    tar xzf openresty-${openresty_version}.tar.gz
    
    log_info "解压 OpenSSL..."
    tar xzf openssl-${openssl_version}.tar.gz
    
    # 安装 jemalloc
    log_info "安装 jemalloc..."
    tar xjf jemalloc-${jemalloc_version}.tar.bz2
    cd jemalloc-${jemalloc_version} || exit 1
    ./configure
    make -j "$(nproc)"
    make install
    ln -s /usr/local/lib/libjemalloc.so.2 /usr/lib/libjemalloc.so.1
    
    # 添加动态库路径
    if [ -z "$(grep /usr/local/lib /etc/ld.so.conf.d/*.conf)" ]; then
        echo '/usr/local/lib' > /etc/ld.so.conf.d/local.conf
    fi
    ldconfig
    cd ..
    
    # 安装 libmaxminddb
    log_info "安装 libmaxminddb..."
    tar xzf libmaxminddb-${libmaxminddb_version}.tar.gz
    cd libmaxminddb-${libmaxminddb_version} || exit 1
    ./configure
    make -j "$(nproc)"
    make install
    ldconfig
    cd ..
    
    log_info "依赖库安装完成"
    cd ..
}

# 重命名 Nginx 标识
rename_ngx() {
    log_info "开始修改 Nginx 标识..."
    cd src/openresty-${openresty_version} || exit 1
    
    # 修改 Nginx 版本信息
    sed -i 's/"openresty\/.*"/"Fungit"/' bundle/nginx-${nginx_version}/src/core/nginx.h
    sed -i 's/#define NGINX_VAR          "NGINX"/#define NGINX_VAR          "Fungit"/' bundle/nginx-${nginx_version}/src/core/nginx.h
    sed -i 's/#define NGINX_VER_BUILD    NGINX_VER " (" NGX_BUILD ")"/#define NGINX_VER_BUILD    NGINX_VER/' bundle/nginx-${nginx_version}/src/core/nginx.h
    sed -i 's/"Server: openresty"/"Server: Fungit"/' bundle/nginx-${nginx_version}/src/http/ngx_http_header_filter_module.c
    sed -i 's/"<hr><center>openresty<\/center>"/"<hr><center>Fungit<\/center>"/'  bundle/nginx-${nginx_version}/src/http/ngx_http_special_response.c
    sed -i 's/"server: nginx/"server: Fungit/' bundle/nginx-${nginx_version}/src/http/v2/ngx_http_v2_filter_module.c
    sed -i 's/"openresty"/"Fungit"/' bundle/nginx-${nginx_version}/src/http/v3/ngx_http_v3_filter_module.c
    
    log_info "Nginx 标识修改完成"
    cd ../..
}

# 配置Nginx
configure_nginx() {
    log_info "开始配置 Nginx..."
    
    # 创建日志目录
    LOG_DIR="/data/wwwlogs"
    mkdir -p "$LOG_DIR"
    chown www:www "$LOG_DIR"
    chmod 755 "$LOG_DIR"
    
    # 创建 PID 文件目录
    PID_DIR="/var/run/nginx"
    mkdir -p "$PID_DIR"
    chown www:www "$PID_DIR"
    chmod 755 "$PID_DIR"
    
    # 修改 nginx.conf 配置文件
    NGINX_CONF="/usr/local/openresty/nginx/conf/nginx.conf"
    
    # 备份原始配置
    cp "$NGINX_CONF" "${NGINX_CONF}.bak"
    
    # 在 main 上下文中添加 pid 指令
    if ! grep -q "pid /var/run/nginx/nginx.pid;" "$NGINX_CONF"; then
        # 在第一行添加 pid 指令
        sed -i '1s/^/pid \/var\/run\/nginx\/nginx.pid;\n/' "$NGINX_CONF"
    fi
    
    # 配置 worker_processes 为 CPU 核心数
    sed -i "s/worker_processes  1/worker_processes  $(nproc)/" "$NGINX_CONF"
    
    # 配置错误日志
    sed -i "s|error_log  logs/error.log|error_log  ${LOG_DIR}/error.log|" "$NGINX_CONF"
    
    # 配置访问日志
    sed -i "s|access_log  logs/access.log|access_log  ${LOG_DIR}/access.log|" "$NGINX_CONF"
    
    # 设置 user 为 www
    sed -i "s|#user  nobody|user  www www|" "$NGINX_CONF"
    
    log_info "Nginx 配置完成"
}

# 设置Nginx服务
setup_nginx_service() {
    log_info "开始设置 Nginx 服务..."
    
    # 创建 systemd 服务文件
    log_info "创建 systemd 服务文件..."
    cat > /lib/systemd/system/nginx.service << EOF
[Unit]
Description=Fungit - 高性能 Web 服务器
Documentation=http://nginx.org/en/docs/
After=network.target

[Service]
Type=forking
PIDFile=/var/run/nginx/nginx.pid
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
    
    # 重载 systemd 并启动 Nginx
    log_info "启动 Nginx 服务..."
    systemctl daemon-reload
    systemctl enable nginx
    
    # 检查配置文件是否正确
    log_info "检查 Nginx 配置文件..."
    if /usr/local/openresty/nginx/sbin/nginx -t -c /usr/local/openresty/nginx/conf/nginx.conf; then
        systemctl start nginx
        
        # 检查服务状态
        if systemctl is-active --quiet nginx; then
            log_info "Nginx 服务已成功启动"
        else
            log_error "Nginx 服务启动失败"
            systemctl status nginx --no-pager
        fi
    else
        log_error "Nginx 配置文件有错误，无法启动服务"
        exit 1
    fi
    
    log_info "Nginx 服务设置完成"
}

# 安装 OpenResty
install() {
    log_info "开始安装 OpenResty..."
    
    # 记录开始时间
    OPENRESTY_START_TIME=$(date +%s)
    
    cd src/openresty-${openresty_version} || exit 1
    
    # 配置编译选项
    log_info "配置编译选项..."
    ./configure \
        --prefix=/usr/local/openresty \
        --with-cc-opt=-O2 \
        --user=www \
        --group=www \
        --with-http_stub_status_module \
        --with-http_sub_module \
        --with-http_v2_module \
        --with-http_ssl_module \
        --with-http_gzip_static_module \
        --with-http_gunzip_module \
        --with-http_realip_module \
        --with-http_flv_module \
        --with-http_mp4_module \
        --with-openssl=../openssl-${openssl_version} \
        --with-pcre=../pcre2-${pcre_version} \
        --with-pcre-jit \
        --with-ld-opt='-ljemalloc' \
        --add-module=../ngx_http_geoip2_module \
        --add-module=../ngx_http_substitutions_filter_module \
        --with-stream_ssl_module \
        --with-stream_ssl_preread_module \
        --with-openssl-opt=-g \
        --with-pcre-opt=-g \
        --with-stream
    
    # 编译和安装
    log_info "开始编译 (这可能需要一段时间)..."
    make -j "$(nproc)"
    log_info "开始安装..."
    make install
    clear
    
    # 记录结束时间
    OPENRESTY_END_TIME=$(date +%s)
    OPENRESTY_TIME=$((OPENRESTY_END_TIME - OPENRESTY_START_TIME))
    
    log_info "OpenResty 安装完成，耗时: $(format_time $OPENRESTY_TIME)"
    cd ../..
}

# 显示安装信息
show_info() {
    echo "====================================================="
    echo -e "${GREEN}OpenResty 安装成功!${NC}"
    echo "版本信息:"
    echo "  - OpenResty: $openresty_version"
    echo "  - Nginx: $nginx_version"
    echo "  - OpenSSL: $openssl_version"
    echo "  - PCRE2: $pcre_version"
    echo "  - jemalloc: $jemalloc_version"
    echo "  - libmaxminddb: $libmaxminddb_version"
    echo ""
    echo "安装位置: /usr/local/openresty"
    echo "配置文件: /usr/local/openresty/nginx/conf/nginx.conf"
    echo "日志目录: /data/wwwlogs"
    echo "PID 文件: /var/run/nginx/nginx.pid"
    echo "服务管理:"
    echo "  - 启动: systemctl start nginx"
    echo "  - 停止: systemctl stop nginx"
    echo "  - 重启: systemctl restart nginx"
    echo "  - 状态: systemctl status nginx"
    echo ""
    echo "Nginx 已添加到系统 PATH，可以直接使用 'nginx' 命令"
    echo "====================================================="
}

# 主函数
main() {
    # 记录脚本开始时间
    START_TIME=$(date +%s)
    
    log_info "开始 OpenResty 安装脚本..."
    pre_check
    create_nginx_user  # 在需要用户的操作前先创建用户
    download
    pre_install
    rename_ngx
    install
    configure_nginx
    setup_nginx_service
    add_nginx_to_path  # 添加nginx到PATH
    show_info
    log_info "脚本执行完成!"
}

# 执行主函数
main

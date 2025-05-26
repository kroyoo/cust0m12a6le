#!/usr/bin/env bash

# OpenResty 编译安装脚本
# 适用于 Debian/Ubuntu 和 Red Hat 系列系统

# 软件版本配置
openresty_version=1.27.1.2
openssl_version=3.4.1
pcre_version=10.44
jemalloc_version=5.3.0
libmaxminddb_version=1.12.2
nginx_version=1.27.1 # OpenResty 1.27.1.2 捆绑的 Nginx 版本


default_brand_name="Fungit" # 脚本预设的替换后品牌名称
target_brand_name=""       # 最终用于替换的品牌名称
is_rename=0

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
    if [ $OPENRESTY_START_TIME -ne 0 ] && [ $OPENRESTY_END_TIME -ne 0 ]; then
        OPENRESTY_TIME=$((OPENRESTY_END_TIME - OPENRESTY_START_TIME))
        echo "OpenResty 编译时间: $(format_time $OPENRESTY_TIME)"
    fi

    echo "====================================================="
    echo -e "${GREEN}脚本执行统计:${NC}"
    if [ $OPENRESTY_START_TIME -ne 0 ] && [ $OPENRESTY_END_TIME -ne 0 ]; then
      echo "OpenResty 编译时间: $(format_time $OPENRESTY_TIME)"
    fi
    echo "脚本总运行时间: $(format_time $TOTAL_TIME)"
    echo "====================================================="
}

# 注册清理函数
trap cleanup EXIT

# 创建 Nginx 用户
create_nginx_user() {
    log_info "创建 Nginx 用户和组..."
    if ! id -u www >/dev/null 2>&1; then
        useradd -r -s /sbin/nologin www # 使用 /sbin/nologin 更常见
    else
        log_info "用户 www 已存在。"
    fi
    if ! getent group www >/dev/null 2>&1; then
        groupadd -r www
    else
        log_info "用户组 www 已存在。"
    fi
}

# 将nginx添加到PATH
add_nginx_to_path() {
    log_info "将 Nginx 添加到系统 PATH..."

    # 创建软链接
    if [ ! -L /usr/bin/nginx ] && [ ! -f /usr/bin/nginx ]; then # 检查是否不是软链接也不是文件
        ln -s /usr/local/openresty/nginx/sbin/nginx /usr/bin/nginx
        log_info "已创建 Nginx 软链接: /usr/bin/nginx"
    elif [ -L /usr/bin/nginx ]; then
        log_warn "Nginx 软链接 /usr/bin/nginx 已存在，跳过创建"
    else
        log_warn "/usr/bin/nginx 已存在但不是预期的软链接，请检查。"
    fi

    # 验证nginx是否可用
    if command_exists nginx; then
        log_info "Nginx 已成功添加到 PATH"
    else
        log_error "添加 Nginx 到 PATH 失败"
        # exit 1 # 考虑是否在此处强制退出
    fi
}

# 前置检查
pre_check() {
    log_info "开始环境检查..."
    check_root

    # 检测操作系统
    if [ -f /etc/os-release ]; then
        source /etc/os-release
        # 优先使用 ID_LIKE 进行更广泛的兼容性判断 (例如 RHEL, CentOS, Fedora, Rocky, AlmaLinux)
        # 如果 ID_LIKE 不存在或不匹配，则回退到 ID
        if [[ "${ID_LIKE}" == *"debian"* || "${ID_LIKE}" == *"ubuntu"* || "${ID}" == "debian" || "${ID}" == "ubuntu" ]]; then
            OS_TYPE="debian"
            log_info "检测到 $PRETTY_NAME 系统 (Debian/Ubuntu like)"
        elif [[ "${ID_LIKE}" == *"rhel"* || "${ID_LIKE}" == *"fedora"* || "${ID}" == "centos" || "${ID}" == "rhel" || "${ID}" == "fedora" || "${ID}" == "rocky" || "${ID}" == "almalinux" ]]; then
            OS_TYPE="redhat"
            log_info "检测到 $PRETTY_NAME 系统 (Red Hat like)"
        else
            log_error "不支持的操作系统: $PRETTY_NAME. 本脚本仅支持 Debian/Ubuntu 和 Red Hat 系列系统."
            exit 1
        fi
    else
        log_error "无法检测操作系统类型 (未找到 /etc/os-release)"
        exit 1
    fi

    if [ "$OS_TYPE" == "debian" ]; then
        log_info "更新软件包列表 (Debian/Ubuntu)..."
        apt-get -y update


        log_info "尝试修复依赖问题 (Debian/Ubuntu)..."
        apt-get -yf install # 尝试修复损坏的依赖

        log_info "升级现有软件包 (Debian/Ubuntu)..."
        # 使用非交互模式避免升级过程中的提示
        DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade

        log_info "安装编译依赖 (Debian/Ubuntu)..."
        # 原始 pkgList 的精简和调整版本
        pkgList="build-essential gcc g++ make cmake autoconf libjpeg-turbo-dev libpng-dev libgd-dev libxml2-dev zlib1g-dev libglib2.0-dev libzip-dev libbz2-dev libncurses5-dev libncursesw5-dev libaio-dev numactl libreadline-dev curl libcurl4-openssl-dev libssl-dev libtool libevent-dev bison re2c libsasl2-dev libxslt1-dev libicu-dev patch vim zip unzip tmux htop bc dc expect libexpat1-dev libonig-dev libtirpc-dev git lsof lrzsz rsyslog cron logrotate chrony libsqlite3-dev psmisc wget ca-certificates gnupg perl"
        # 确保 perl 已安装，OpenSSL编译等过程需要

        for Package in $pkgList; do
            log_info "安装 (Debian/Ubuntu) $Package..."
            DEBIAN_FRONTEND=noninteractive apt-get --no-install-recommends -y install "$Package"
        done

    elif [ "$OS_TYPE" == "redhat" ]; then
        PKG_MANAGER=""
        if command_exists dnf; then
            PKG_MANAGER="dnf"
            log_info "使用 dnf 包管理器。"
        elif command_exists yum; then
            PKG_MANAGER="yum"
            log_info "使用 yum 包管理器。"
        else
            log_error "未找到 yum 或 dnf 包管理器。"
            exit 1
        fi

        log_info "升级现有软件包 (Red Hat like)..."
        $PKG_MANAGER -y upgrade

        log_info "安装 EPEL repository (Red Hat like)..."
        # EPEL源提供了许多额外的常用软件包
        $PKG_MANAGER -y install epel-release

        log_info "安装 'Development Tools' 开发工具组 (Red Hat like)..."
        $PKG_MANAGER -y groupinstall "Development Tools"
        log_info "启用 CRB (CodeReady Builder) / PowerTools 仓库 (Red Hat like)..."
        # 对于 RHEL 9 及其衍生版 (Alma, Rocky, CentOS Stream 9+)
        if dnf repolist all | grep -q -E 'crb|codeready-builder'; then
            dnf config-manager --set-enabled $(sudo dnf repolist all | grep -E 'crb|codeready-builder' | awk '{print $1}' | cut -d'/' -f1 | head -n1)
        elif  dnf repolist all | grep -q 'powertools'; then
            dnf config-manager --set-enabled powertools
        else
            log_warn "未能自动识别并启用 CRB/PowerTools 仓库。某些开发包可能无法找到。"
        fi
        # 刷新元数据可能有助于立即识别新启用的仓库中的包
        dnf makecache --timer
        log_info "安装编译依赖 (Red Hat like)..."
        # Red Hat 系列的软件包列表
        rhPkgList="gcc gcc-c++ make cmake autoconf libtool bison re2c perl libjpeg-turbo-devel libpng-devel gd-devel libxml2-devel zlib-devel glibc-devel glib2-devel libzip-devel bzip2-devel ncurses-devel libaio-devel numactl-devel readline-devel libcurl-devel openssl-devel krb5-devel libtool-ltdl-devel libevent-devel cyrus-sasl-devel libxslt-devel libicu-devel expat-devel oniguruma-devel libtirpc-devel sqlite-devel patch vim-enhanced zip unzip tmux htop bc expect git lsof lrzsz rsyslog cronie logrotate chrony psmisc wget ca-certificates gnupg2 glibc-common e2fsprogs net-tools"

        for Package in $rhPkgList; do
            log_info "安装 (Red Hat like) $Package..."
            $PKG_MANAGER -y install "$Package"
        done


        log_info "清理 $PKG_MANAGER 缓存 (Red Hat like)..."
        $PKG_MANAGER clean all
    fi

    log_info "环境检查完成"
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
    # 检查是否存在 /usr/lib (在某些系统上可能是 /usr/lib64)
    # 更稳健的做法是让 ldconfig 处理，或者确保 /usr/local/lib 在 ld.so.conf.d/ 中
    if [ -d "/usr/lib64" ] && [ ! -e "/usr/lib64/libjemalloc.so.1" ]; then
        ln -s /usr/local/lib/libjemalloc.so.2 /usr/lib64/libjemalloc.so.1
    elif [ ! -e "/usr/lib/libjemalloc.so.1" ]; then
        ln -s /usr/local/lib/libjemalloc.so.2 /usr/lib/libjemalloc.so.1
    fi


    # 添加动态库路径
    if ! grep -q "/usr/local/lib" /etc/ld.so.conf.d/*.conf /etc/ld.so.conf 2>/dev/null ; then
        echo '/usr/local/lib' > /etc/ld.so.conf.d/usr-local-lib.conf
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

check_rename(){
    log_info "服务器标识自定义步骤："
    read -r -p "是否要修改 Nginx/OpenResty 的默认服务器标识 (例如, 将 'nginx' 或 'openresty' 修改为其他名称)? (y/N): " confirm_rename
    local confirm_rename_lower
    confirm_rename_lower=$(echo "$confirm_rename" | tr '[:upper:]' '[:lower:]')

    if [[ "$confirm_rename_lower" == "y" || "$confirm_rename_lower" == "yes" ]]; then
        is_rename=1
        read -r -p "请输入新的服务器标识 (直接回车将使用默认值 '${default_brand_name}'): " user_brand_name
        if [ -z "$user_brand_name" ]; then # 如果用户未输入，则使用默认品牌名称
            target_brand_name="$default_brand_name"
        else
            target_brand_name="$user_brand_name"
        fi
        log_info "服务器标识将被修改为: '${target_brand_name}'"
    else
        log_info "跳过修改服务器标识。将保留原始的 Nginx/OpenResty 标识。"
    fi
}


# 重命名 Nginx 标识
rename_ngx() {
    if [[ "$is_rename" == "0" ]]; then
        return
    fi

    log_info "开始修改 Nginx 标识..."
    cd src/openresty-${openresty_version} || exit 1


    # 修改 Nginx 版本信息
    sed -i "s|\"openresty\/.*\"|\"${target_brand_name}\"|" "bundle/nginx-${nginx_version}/src/core/nginx.h"
    sed -i "s|#define NGINX_VAR          \"NGINX\"|#define NGINX_VAR          \"${target_brand_name}\"|" "bundle/nginx-${nginx_version}/src/core/nginx.h"
    sed -i "s|#define NGINX_VER_BUILD    NGINX_VER \" (\" NGX_BUILD \")\"|#define NGINX_VER_BUILD    NGINX_VER|" "bundle/nginx-${nginx_version}/src/core/nginx.h"
    sed -i "s|\"Server: openresty\"|\"Server: ${target_brand_name}\"|" "bundle/nginx-${nginx_version}/src/http/ngx_http_header_filter_module.c"
    sed -i "s|\"<hr><center>openresty<\/center>\"|\"<hr><center>${target_brand_name}<\/center>\"|"  "bundle/nginx-${nginx_version}/src/http/ngx_http_special_response.c"
    sed -i "s|server: nginx|server: ${target_brand_name}|" "bundle/nginx-${nginx_version}/src/http/v2/ngx_http_v2_filter_module.c"
    local http3_filter_module_path="bundle/nginx-${nginx_version}/src/http/v3/ngx_http_v3_filter_module.c"
    if [ -f "$http3_filter_module_path" ]; then
        sed -i "s|\"openresty\"|\"${target_brand_name}\"|" "$http3_filter_module_path"
    else
        log_warn "HTTP/3 filter module ($http3_filter_module_path) not found, skipping rename for it."
    fi



    log_info "Nginx 标识修改完成"
    cd ../..
}

# 配置Nginx
configure_nginx() {
    log_info "开始配置 Nginx..."

    # 创建日志目录
    LOG_DIR="/data/wwwlogs"
    mkdir -p "$LOG_DIR"
    chown www:www "$LOG_DIR" # 确保 www 用户和组已创建
    chmod 755 "$LOG_DIR"

    # 创建 PID 文件目录
    PID_DIR="/var/run/nginx"
    mkdir -p "$PID_DIR"
    chown www:www "$PID_DIR"
    chmod 755 "$PID_DIR"

    # 修改 nginx.conf 配置文件
    NGINX_CONF_DIR="/usr/local/openresty/nginx/conf"
    NGINX_CONF="${NGINX_CONF_DIR}/nginx.conf"

    if [ ! -f "$NGINX_CONF" ]; then
        log_error "Nginx 配置文件 $NGINX_CONF 未找到。可能安装未成功。"
        exit 1
    fi

    # 备份原始配置
    cp "$NGINX_CONF" "${NGINX_CONF}.bak.$(date +%Y%m%d%H%M%S)"
# 配置 PID 文件路径
    local target_pid_directive="pid ${PID_DIR}/nginx.pid;"
    log_info "目标 PID 配置: ${target_pid_directive}"

    # 检查 nginx.conf 中是否已存在任何 pid 指令 (以 'pid ' 开头，忽略注释)
    if grep -q -E "^\s*pid\s+.*;" "$NGINX_CONF"; then
        # 如果已存在 pid 指令，检查它是否已经是我们想要的配置
        if grep -q -E "^\s*${target_pid_directive}\s*$" "$NGINX_CONF"; then
            log_info "PID 指令已正确配置为: ${target_pid_directive}"
        else
            log_info "检测到已存在的 PID 指令，将尝试修改它..."
            # 使用 sed 修改已存在的 pid 指令为目标配置
            # 这个 sed 命令会替换第一个非注释的以 "pid " 开头的行
            # 注意：如果配置文件中有多个 pid 指令（非注释），这只会修改第一个匹配到的
            sudo sed -i -E "0,/\s*pid\s+.*;/s#^\s*pid\s+.*;#${target_pid_directive}#" "$NGINX_CONF"
            log_info "已将现有 PID 指令修改为: ${target_pid_directive}"
        fi
    else
        # 如果不存在任何 pid 指令，则在第一行非空非注释行前添加
        log_info "未检测到 PID 指令，将添加新的 PID 指令..."
        # 使用 awk 在 main context (通常是'events {'之前或文件顶部) 添加
        # 这是一个更安全的做法，尝试添加到 user 指令之后（如果存在）或 events {} 块之前
        if grep -q -E "^\s*user\s+.*;" "$NGINX_CONF"; then
            sudo sed -i -E "/^\s*user\s+.*;/a ${target_pid_directive}" "$NGINX_CONF"
        elif grep -q -E "^\s*events\s*\{" "$NGINX_CONF"; then # 尝试添加到 events 块之前
            sudo sed -i -E "/^\s*events\s*\{/i ${target_pid_directive}" "$NGINX_CONF"
        else # 作为后备，添加到文件顶部（去除旧的简单插入逻辑）
            sudo sed -i "1s|^|${target_pid_directive}\\n|" "$NGINX_CONF"
        fi
        log_info "已添加 PID 指令: ${target_pid_directive}"
    fi

    # 配置 worker_processes 为 CPU 核心数
    sed -i "s/worker_processes  1/worker_processes  $(nproc)/" "$NGINX_CONF"

    # 配置错误日志
    sed -i "s|error_log  logs/error.log|error_log  ${LOG_DIR}/error.log|" "$NGINX_CONF"

    sed -i "s|access_log  logs/access.log|access_log  ${LOG_DIR}/access.log|" "$NGINX_CONF"

    # 设置 user 为 www (确保是在 main 上下文)
    if grep -q "^user " "$NGINX_CONF"; then
      sed -i "s|^user .*|user  www www;|" "$NGINX_CONF"
    elif grep -q "^#user " "$NGINX_CONF"; then # 如果是被注释掉的
      sed -i "s|^#user .*|user  www www;|" "$NGINX_CONF"
    else # 如果完全没有 user 指令，添加到 pid 之后
      sed -i "/pid ${PID_DIR}\/nginx.pid;/a user  www www;" "$NGINX_CONF"
    fi


    log_info "Nginx 配置完成"
}

# 设置Nginx服务
setup_nginx_service() {
    log_info "开始设置 Nginx 服务..."

    # 创建 systemd 服务文件
    log_info "创建 systemd 服务文件..."
    SYSTEMD_SERVICE_DIR="/etc/systemd/system"
    if [ ! -d "$SYSTEMD_SERVICE_DIR" ] && [ -d "/usr/lib/systemd/system" ]; then
        SYSTEMD_SERVICE_DIR="/usr/lib/systemd/system"
    elif [ ! -d "$SYSTEMD_SERVICE_DIR" ] && [ -d "/lib/systemd/system" ]; then
        SYSTEMD_SERVICE_DIR="/lib/systemd/system" # 作为最后的备选
    fi
    
    mkdir -p "$SYSTEMD_SERVICE_DIR" # 确保目录存在

    cat > "${SYSTEMD_SERVICE_DIR}/nginx.service" << EOF
[Unit]
Description=Fungit - High performance web server built on OpenResty
Documentation=https://openresty.org/en/
After=network.target network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=/var/run/nginx/nginx.pid
ExecStartPre=/usr/local/openresty/nginx/sbin/nginx -t -q 'daemon on; master_process on;' -c /usr/local/openresty/nginx/conf/nginx.conf
ExecStart=/usr/local/openresty/nginx/sbin/nginx -g 'daemon on; master_process on;' -c /usr/local/openresty/nginx/conf/nginx.conf
ExecStartPost=/bin/sleep 0.1
ExecReload=/usr/local/openresty/nginx/sbin/nginx -s reload
ExecStop=/bin/kill -s QUIT \$MAINPID
TimeoutStopSec=5
KillMode=mixed
PrivateTmp=true
LimitNOFILE=1000000
LimitNPROC=1000000
LimitCORE=infinity

[Install]
WantedBy=multi-user.target
EOF

    # 重载 systemd 并启动 Nginx
    log_info "重载 systemd 并启用/启动 Nginx 服务..."
    systemctl daemon-reload
    systemctl enable nginx

    # 检查配置文件是否正确
    log_info "检查 Nginx 配置文件..."
    if /usr/local/openresty/nginx/sbin/nginx -t -q -c /usr/local/openresty/nginx/conf/nginx.conf; then
        log_info "Nginx 配置文件测试通过。"
        if systemctl is-active --quiet nginx; then
            log_info "Nginx 服务已在运行，尝试重启..."
            systemctl restart nginx
        else
            log_info "启动 Nginx 服务..."
            systemctl start nginx
        fi

        # 检查服务状态
        if systemctl is-active --quiet nginx; then
            log_info "Nginx 服务已成功启动/重启"
        else
            log_error "Nginx 服务启动/重启失败"
            systemctl status nginx --no-pager || true # 显示状态，即使失败
            journalctl -u nginx --no-pager -n 50 || true # 显示最新的50条日志
        fi
    else
        log_error "Nginx 配置文件有错误，无法启动服务。请手动检查。"
        /usr/local/openresty/nginx/sbin/nginx -t -c /usr/local/openresty/nginx/conf/nginx.conf || true
        exit 1
    fi

    log_info "Nginx 服务设置完成"
}

# 安装 OpenResty
install_openresty() { 
    log_info "开始安装 OpenResty..."

    # 记录开始时间
    OPENRESTY_START_TIME=$(date +%s)

    cd src/openresty-${openresty_version} || exit 1

    # 配置编译选项
    log_info "配置编译选项..."
    ./configure \
        --prefix=/usr/local/openresty \
        --with-cc-opt="-O2" \
        --with-ld-opt="-Wl,-rpath,/usr/local/lib -ljemalloc" \
        --user=www \
        --group=www \
        --with-compat \
        --with-file-aio \
        --with-threads \
        --with-http_ssl_module \
        --with-http_v2_module \
        --with-http_v3_module \
        --with-http_realip_module \
        --with-http_addition_module \
        --with-http_xslt_module=dynamic \
        --with-http_image_filter_module=dynamic \
        --with-http_sub_module \
        --with-http_dav_module \
        --with-http_flv_module \
        --with-http_mp4_module \
        --with-http_gunzip_module \
        --with-http_gzip_static_module \
        --with-http_auth_request_module \
        --with-http_random_index_module \
        --with-http_secure_link_module \
        --with-http_degradation_module \
        --with-http_slice_module \
        --with-http_stub_status_module \
        --with-stream \
        --with-stream_ssl_module \
        --with-stream_realip_module \
        --with-stream_ssl_preread_module \
        --with-pcre=../pcre2-${pcre_version} \
        --with-pcre-jit \
        --with-openssl=../openssl-${openssl_version} \
        --with-openssl-opt="enable-ec_nistp_64_gcc_128 no-nextprotoneg" \
        --add-module=../ngx_http_geoip2_module \
        --add-module=../ngx_http_substitutions_filter_module

    # 编译和安装
    log_info "开始编译 (这可能需要一段时间)..."
    make -j "$(nproc)"
    log_info "开始安装..."
    make install
    # clear # 编译安装后清理屏幕

    # 记录结束时间
    OPENRESTY_END_TIME=$(date +%s)
    # OPENRESTY_TIME 计算移到 cleanup 函数或 show_info

    log_info "OpenResty 安装完成!" # 耗时信息移到 cleanup
    cd ../..
}

# 显示安装信息
show_info() {
    # 计算 OpenResty 编译时间，以防脚本在编译后但在 cleanup 前退出
    if [ $OPENRESTY_START_TIME -ne 0 ] && [ $OPENRESTY_END_TIME -ne 0 ]; then
        local current_openresty_time=$((OPENRESTY_END_TIME - OPENRESTY_START_TIME))
        log_info "OpenResty 编译耗时: $(format_time "$current_openresty_time")"
    fi

    echo "====================================================="
    echo -e "${GREEN}OpenResty 安装成功!${NC}"
    echo "版本信息:"
    echo "  - OpenResty: $openresty_version"
    echo "  - Nginx (core): $nginx_version" # OpenResty 捆绑的 Nginx 内核版本
    echo "  - OpenSSL (used for build): $openssl_version"
    echo "  - PCRE2 (used for build): $pcre_version"
    echo "  - jemalloc: $jemalloc_version"
    echo "  - libmaxminddb: $libmaxminddb_version"
    echo ""
    echo "安装位置: /usr/local/openresty"
    echo "Nginx 可执行文件: /usr/local/openresty/nginx/sbin/nginx"
    echo "Nginx 配置文件: /usr/local/openresty/nginx/conf/nginx.conf"
    echo "日志目录: /data/wwwlogs"
    echo "PID 文件: /var/run/nginx/nginx.pid"
    echo ""
    echo "服务管理 (使用 systemd):"
    echo "  - 启动: systemctl start nginx"
    echo "  - 停止: systemctl stop nginx"
    echo "  - 重启: systemctl restart nginx"
    echo "  - 状态: systemctl status nginx"
    echo "  - 开机启动: systemctl enable nginx"
    echo "  - 禁止开机启动: systemctl disable nginx"
    echo ""
    if command_exists nginx; then
        echo "Nginx 已通过 /usr/bin/nginx 添加到系统 PATH。"
        echo "Nginx 版本: $(nginx -V 2>&1 | grep "nginx version")"
    else
        echo "Nginx 未能成功链接到 /usr/bin/nginx。"
    fi
    echo "====================================================="
}

# 主函数
main() {
    # 记录脚本开始时间
    START_TIME=$(date +%s)

    log_info "开始 OpenResty 安装脚本..."
    check_rename
    pre_check
    create_nginx_user  # 在需要用户的操作前先创建用户
    download
    pre_install
    rename_ngx
    install_openresty 
    if [ -f "/usr/local/openresty/nginx/sbin/nginx" ]; then
        configure_nginx
        setup_nginx_service
        add_nginx_to_path  # 添加nginx到PATH
    else
        log_error "OpenResty 安装似乎未成功，Nginx 可执行文件未找到。跳过配置和服务设置。"
        exit 1
    fi
    show_info
    log_info "脚本执行完成!"
}

# 执行主函数
main

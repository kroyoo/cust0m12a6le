#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# Nginx source installer (vanilla Nginx + GeoIP2 + substitutions + Lua WAF).
# - Targets latest stable components by default (auto-discovery with fallback).
# - Integrates local or online waf/ directory into nginx.conf.
# - Default mode is "stage": build/install candidate tree only, no live replacement.
# - "promote" mode performs backup + cutover with rollback-on-error safeguards.
# - Keeps runtime path simple: PID at /run/nginx.pid (no /var/run/nginx dir).
# -----------------------------------------------------------------------------

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
START_TS="$(date +%s)"

# ----- Fallback versions (used when auto-discovery is unavailable) ----------
DEFAULT_NGINX_VERSION="1.28.2"
DEFAULT_OPENSSL_VERSION="3.6.1"
DEFAULT_PCRE2_VERSION="10.47"
DEFAULT_JEMALLOC_VERSION="5.3.0"
DEFAULT_LIBMAXMINDDB_VERSION="1.12.2"

# ----- Config (env override supported) ---------------------------------------
AUTO_LATEST="${AUTO_LATEST:-1}"               # 1/0
AUTO_CLEANUP="${AUTO_CLEANUP:-1}"             # 1/0
ASSUME_YES="${ASSUME_YES:-0}"                 # 1/0
ENABLE_JEMALLOC="${ENABLE_JEMALLOC:-1}"       # 1/0

NGINX_VERSION="${NGINX_VERSION:-$DEFAULT_NGINX_VERSION}"
OPENSSL_VERSION="${OPENSSL_VERSION:-$DEFAULT_OPENSSL_VERSION}"
PCRE2_VERSION="${PCRE2_VERSION:-$DEFAULT_PCRE2_VERSION}"
JEMALLOC_VERSION="${JEMALLOC_VERSION:-$DEFAULT_JEMALLOC_VERSION}"
LIBMAXMINDDB_VERSION="${LIBMAXMINDDB_VERSION:-$DEFAULT_LIBMAXMINDDB_VERSION}"

NGINX_PREFIX="${NGINX_PREFIX:-/usr/local/nginx}"
NGINX_USER="${NGINX_USER:-www}"
NGINX_GROUP="${NGINX_GROUP:-www}"
LOG_DIR="${LOG_DIR:-/data/wwwlogs}"
PID_FILE="${PID_FILE:-/run/nginx.pid}"
LUAJIT_PREFIX="${LUAJIT_PREFIX:-/usr/local/luajit}"
LUA_SHARE_DIR="${LUA_SHARE_DIR:-/usr/local/share/lua/5.1}"
LUA_CPATH_DIR="${LUA_CPATH_DIR:-/usr/local/lib/lua/5.1}"
WAF_SOURCE_MODE="${WAF_SOURCE_MODE:-local}"   # local | online
WAF_SOURCE_DIR="${WAF_SOURCE_DIR:-}"
WAF_REPO_URL="${WAF_REPO_URL:-https://github.com/kroyoo/cust0m12a6le.git}"
WAF_REPO_REF="${WAF_REPO_REF:-}"
WAF_REPO_SUBDIR="${WAF_REPO_SUBDIR:-waf}"
OPENRESTY_PREFIX="${OPENRESTY_PREFIX:-}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/nginx-source-installer}"
SERVICE_NAME="${SERVICE_NAME:-nginx}"
INSTALL_MODE="${INSTALL_MODE:-stage}"         # stage | promote
ACTIVATE_SERVICE="${ACTIVATE_SERVICE:-0}"     # 1/0, only used in promote mode
LINK_NGINX_BIN="${LINK_NGINX_BIN:-0}"         # 1/0, only used in promote mode
DRY_RUN="${DRY_RUN:-0}"                       # 1/0, print plan and exit

# ask | set | keep
BRAND_MODE="${BRAND_MODE:-ask}"
BRAND_NAME="${BRAND_NAME:-Fungit}"
TARGET_BRAND=""

JOBS="${JOBS:-$(nproc)}"
WORKDIR="${WORKDIR:-}"
WORKDIR_CREATED=0
SRC_DIR=""
OS_FAMILY=""
PKG_MANAGER=""
INSTALL_STAGE_ROOT=""
CANDIDATE_PREFIX=""
PROMOTE_IN_PROGRESS=0
PROMOTE_TS=""
LIVE_PREFIX_BACKUP=""
SERVICE_UNIT_FILE=""
SERVICE_UNIT_BACKUP=""
HAD_SERVICE_UNIT=0
HAD_LIVE_PREFIX=0
LIVE_PREFIX_MOVED=0
NEW_PREFIX_DEPLOYED=0
SERVICE_UNIT_CHANGED=0
OPENRESTY_PREFIX_DETECTED=""
WAF_EFFECTIVE_SOURCE_DIR=""
WAF_REPO_CLONE_DIR=""

# Optional pinned refs for modules (empty means latest default branch)
LUAJIT_REF="${LUAJIT_REF:-}"
NDK_REF="${NDK_REF:-}"
LUA_NGINX_REF="${LUA_NGINX_REF:-}"
STREAM_LUA_REF="${STREAM_LUA_REF:-}"
GEOIP2_REF="${GEOIP2_REF:-}"
SUBS_REF="${SUBS_REF:-}"
RESTY_CORE_REF="${RESTY_CORE_REF:-}"
RESTY_LRUCACHE_REF="${RESTY_LRUCACHE_REF:-}"
RESTY_HTTP_REF="${RESTY_HTTP_REF:-}"
LUA_CJSON_REF="${LUA_CJSON_REF:-}"

# Module repositories
LUAJIT_REPO="${LUAJIT_REPO:-https://github.com/openresty/luajit2.git}"
NDK_REPO_PRIMARY="${NDK_REPO_PRIMARY:-https://github.com/vision5/ngx_devel_kit.git}"
NDK_REPO_FALLBACK="${NDK_REPO_FALLBACK:-https://github.com/openresty/ngx_devel_kit.git}"
LUA_NGINX_REPO="${LUA_NGINX_REPO:-https://github.com/openresty/lua-nginx-module.git}"
STREAM_LUA_REPO="${STREAM_LUA_REPO:-https://github.com/openresty/stream-lua-nginx-module.git}"
GEOIP2_REPO="${GEOIP2_REPO:-https://github.com/leev/ngx_http_geoip2_module.git}"
SUBS_REPO="${SUBS_REPO:-https://github.com/yaoweibin/ngx_http_substitutions_filter_module.git}"
RESTY_CORE_REPO="${RESTY_CORE_REPO:-https://github.com/openresty/lua-resty-core.git}"
RESTY_LRUCACHE_REPO="${RESTY_LRUCACHE_REPO:-https://github.com/openresty/lua-resty-lrucache.git}"
RESTY_HTTP_REPO="${RESTY_HTTP_REPO:-https://github.com/ledgetech/lua-resty-http.git}"
LUA_CJSON_REPO="${LUA_CJSON_REPO:-https://github.com/openresty/lua-cjson.git}"

# Colors (TTY only)
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'
    C_INFO=$'\033[0;32m'
    C_WARN=$'\033[0;33m'
    C_ERR=$'\033[0;31m'
else
    C_RESET=""
    C_INFO=""
    C_WARN=""
    C_ERR=""
fi

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log_info() { printf '%s %s[INFO]%s %s\n' "$(ts)" "${C_INFO}" "${C_RESET}" "$*"; }
log_warn() { printf '%s %s[WARN]%s %s\n' "$(ts)" "${C_WARN}" "${C_RESET}" "$*"; }
log_error() { printf '%s %s[ERROR]%s %s\n' "$(ts)" "${C_ERR}" "${C_RESET}" "$*" >&2; }
die() { log_error "$*"; exit 1; }

phase() {
    printf '\n%s %s[PHASE]%s %s\n' "$(ts)" "${C_INFO}" "${C_RESET}" "$*"
}

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [options]

Options:
  -y, --yes                      Non-interactive mode (skip prompts)
  --mode stage|promote           stage=build+candidate test only (default), promote=switch to live
  --promote                      Shortcut for --mode promote
  --dry-run                      Print execution plan and detected paths, then exit
  --activate                     Start/reload ${SERVICE_NAME} after successful promote
  --link-bin                     Link /usr/bin/nginx to ${NGINX_PREFIX}/sbin/nginx in promote mode
  --backup-root PATH             Backup path for live prefix/systemd backups (default: ${BACKUP_ROOT})
  --service-name NAME            systemd service name to manage (default: ${SERVICE_NAME})
  --prefix PATH                  Nginx install prefix (default: ${NGINX_PREFIX})
  --brand NAME                   Set custom Server brand string
  --no-brand                     Keep upstream nginx branding
  --auto-latest 0|1              Discover latest stable versions at runtime (default: ${AUTO_LATEST})
  --no-jemalloc                  Disable jemalloc linking/build
  --waf-source local|online      WAF source mode (default: ${WAF_SOURCE_MODE})
  --online-waf                   Shortcut for --waf-source online
  --waf-source-dir PATH          Local waf directory (default: auto-detect ../waf then ./waf)
  --waf-repo URL                 Online WAF git repo (default: ${WAF_REPO_URL})
  --waf-ref REF                  Online WAF git branch/tag/commit (default: repo default branch)
  --waf-subdir PATH              WAF directory inside repo (default: ${WAF_REPO_SUBDIR})
  --workdir PATH                 Reuse a specific working directory
  --nginx-version VER            Force Nginx version
  --openssl-version VER          Force OpenSSL version
  --pcre2-version VER            Force PCRE2 version
  --jemalloc-version VER         Force jemalloc version
  --libmaxminddb-version VER     Force libmaxminddb version
  -h, --help                     Show this help

Environment overrides:
  AUTO_LATEST, AUTO_CLEANUP, ASSUME_YES, ENABLE_JEMALLOC, JOBS
  INSTALL_MODE, ACTIVATE_SERVICE, LINK_NGINX_BIN, DRY_RUN, BACKUP_ROOT, SERVICE_NAME
  NGINX_PREFIX, NGINX_USER, NGINX_GROUP, LOG_DIR, PID_FILE, LUAJIT_PREFIX, LUA_SHARE_DIR, LUA_CPATH_DIR, OPENRESTY_PREFIX
  WAF_SOURCE_MODE, WAF_SOURCE_DIR, WAF_REPO_URL, WAF_REPO_REF, WAF_REPO_SUBDIR
  BRAND_MODE (ask|set|keep), BRAND_NAME
  NGINX_VERSION, OPENSSL_VERSION, PCRE2_VERSION, JEMALLOC_VERSION, LIBMAXMINDDB_VERSION
  LUAJIT_REF, NDK_REF, LUA_NGINX_REF, STREAM_LUA_REF, GEOIP2_REF, SUBS_REF, RESTY_CORE_REF, RESTY_LRUCACHE_REF, RESTY_HTTP_REF, LUA_CJSON_REF
  RESTY_CORE_REPO, RESTY_LRUCACHE_REPO, RESTY_HTTP_REPO, LUA_CJSON_REPO

Notes:
  OPENRESTY_PREFIX is optional manual override. If unset, script auto-detects from
  openresty/nginx binaries and systemd unit files.
EOF
}

normalize_bool() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|on|ON) printf '1\n' ;;
        0|false|FALSE|no|NO|off|OFF) printf '0\n' ;;
        *) die "Invalid boolean value: $1 (expected 0/1/true/false)" ;;
    esac
}

normalize_mode() {
    case "${1:-}" in
        stage|promote) printf '%s\n' "$1" ;;
        *) die "Invalid install mode: $1 (expected stage|promote)" ;;
    esac
}

normalize_waf_source_mode() {
    case "${1:-}" in
        local|online) printf '%s\n' "$1" ;;
        *) die "Invalid WAF source mode: $1 (expected local|online)" ;;
    esac
}

normalize_waf_subdir() {
    local subdir="${1:-}"
    subdir="${subdir#./}"
    subdir="${subdir#/}"
    subdir="${subdir%/}"
    [[ -n "${subdir}" ]] || die "Invalid WAF subdir: empty path"
    case "${subdir}" in
        *".."*) die "Invalid WAF subdir (path traversal not allowed): ${subdir}" ;;
    esac
    printf '%s\n' "${subdir}"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--yes)
                ASSUME_YES=1
                ;;
            --mode)
                [[ $# -ge 2 ]] || die "--mode requires stage|promote"
                INSTALL_MODE="$2"
                shift
                ;;
            --promote)
                INSTALL_MODE="promote"
                ;;
            --dry-run)
                DRY_RUN=1
                ;;
            --activate)
                ACTIVATE_SERVICE=1
                ;;
            --link-bin)
                LINK_NGINX_BIN=1
                ;;
            --backup-root)
                [[ $# -ge 2 ]] || die "--backup-root requires a value"
                BACKUP_ROOT="$2"
                shift
                ;;
            --service-name)
                [[ $# -ge 2 ]] || die "--service-name requires a value"
                SERVICE_NAME="$2"
                shift
                ;;
            --prefix)
                [[ $# -ge 2 ]] || die "--prefix requires a value"
                NGINX_PREFIX="$2"
                shift
                ;;
            --brand)
                [[ $# -ge 2 ]] || die "--brand requires a value"
                BRAND_MODE="set"
                BRAND_NAME="$2"
                shift
                ;;
            --no-brand)
                BRAND_MODE="keep"
                ;;
            --auto-latest)
                [[ $# -ge 2 ]] || die "--auto-latest requires 0 or 1"
                AUTO_LATEST="$2"
                shift
                ;;
            --no-jemalloc)
                ENABLE_JEMALLOC=0
                ;;
            --waf-source)
                [[ $# -ge 2 ]] || die "--waf-source requires local|online"
                WAF_SOURCE_MODE="$2"
                shift
                ;;
            --online-waf)
                WAF_SOURCE_MODE="online"
                ;;
            --waf-source-dir)
                [[ $# -ge 2 ]] || die "--waf-source-dir requires a value"
                WAF_SOURCE_DIR="$2"
                shift
                ;;
            --waf-repo)
                [[ $# -ge 2 ]] || die "--waf-repo requires a value"
                WAF_REPO_URL="$2"
                shift
                ;;
            --waf-ref)
                [[ $# -ge 2 ]] || die "--waf-ref requires a value"
                WAF_REPO_REF="$2"
                shift
                ;;
            --waf-subdir)
                [[ $# -ge 2 ]] || die "--waf-subdir requires a value"
                WAF_REPO_SUBDIR="$2"
                shift
                ;;
            --workdir)
                [[ $# -ge 2 ]] || die "--workdir requires a value"
                WORKDIR="$2"
                shift
                ;;
            --nginx-version)
                [[ $# -ge 2 ]] || die "--nginx-version requires a value"
                NGINX_VERSION="$2"
                AUTO_LATEST=0
                shift
                ;;
            --openssl-version)
                [[ $# -ge 2 ]] || die "--openssl-version requires a value"
                OPENSSL_VERSION="$2"
                AUTO_LATEST=0
                shift
                ;;
            --pcre2-version)
                [[ $# -ge 2 ]] || die "--pcre2-version requires a value"
                PCRE2_VERSION="$2"
                AUTO_LATEST=0
                shift
                ;;
            --jemalloc-version)
                [[ $# -ge 2 ]] || die "--jemalloc-version requires a value"
                JEMALLOC_VERSION="$2"
                AUTO_LATEST=0
                shift
                ;;
            --libmaxminddb-version)
                [[ $# -ge 2 ]] || die "--libmaxminddb-version requires a value"
                LIBMAXMINDDB_VERSION="$2"
                AUTO_LATEST=0
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "Unknown option: $1"
                ;;
        esac
        shift
    done
    INSTALL_MODE="$(normalize_mode "${INSTALL_MODE}")"
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

on_error() {
    local lineno="$1"
    local cmd="$2"
    log_error "Failed at line ${lineno}: ${cmd}"
    if [[ -n "${SERVICE_NAME:-}" ]]; then
        log_error "Context: SERVICE_NAME=${SERVICE_NAME} INSTALL_MODE=${INSTALL_MODE:-unknown} NGINX_PREFIX=${NGINX_PREFIX:-unknown}"
        if command_exists systemctl; then
            local svc_state
            svc_state="$(systemctl is-active "${SERVICE_NAME}" 2>/dev/null || true)"
            log_error "systemd: ${SERVICE_NAME}.service state=${svc_state:-unknown}"
        fi
    fi
}

rollback_if_needed() {
    [[ "${PROMOTE_IN_PROGRESS}" == "1" ]] || return 0

    log_warn "Promotion failed. Attempting rollback..."

    if [[ "${SERVICE_UNIT_CHANGED}" == "1" ]]; then
        if [[ "${HAD_SERVICE_UNIT}" == "1" && -n "${SERVICE_UNIT_BACKUP}" && -f "${SERVICE_UNIT_BACKUP}" ]]; then
            cp -a "${SERVICE_UNIT_BACKUP}" "${SERVICE_UNIT_FILE}" || true
            log_warn "Restored systemd unit from backup: ${SERVICE_UNIT_BACKUP}"
        elif [[ "${HAD_SERVICE_UNIT}" == "0" && -n "${SERVICE_UNIT_FILE}" && -f "${SERVICE_UNIT_FILE}" ]]; then
            rm -f "${SERVICE_UNIT_FILE}" || true
            log_warn "Removed newly created systemd unit: ${SERVICE_UNIT_FILE}"
        fi
    fi

    if [[ "${NEW_PREFIX_DEPLOYED}" == "1" && -n "${NGINX_PREFIX}" && -d "${NGINX_PREFIX}" ]]; then
        rm -rf "${NGINX_PREFIX}" || true
    fi

    if [[ "${LIVE_PREFIX_MOVED}" == "1" && "${HAD_LIVE_PREFIX}" == "1" && -n "${LIVE_PREFIX_BACKUP}" && -d "${LIVE_PREFIX_BACKUP}" ]]; then
        mv "${LIVE_PREFIX_BACKUP}" "${NGINX_PREFIX}" || true
        log_warn "Restored previous live prefix from backup: ${LIVE_PREFIX_BACKUP}"
    fi

    if command_exists systemctl; then
        systemctl daemon-reload || true
    fi

    PROMOTE_IN_PROGRESS=0
}

cleanup() {
    local rc=$?
    set +e
    local cleanup_mode="${AUTO_CLEANUP}"
    if [[ "${DRY_RUN}" == "1" ]]; then
        cleanup_mode="0"
    fi
    if [[ "${INSTALL_MODE}" == "stage" && "${cleanup_mode}" == "1" ]]; then
        cleanup_mode="0"
        log_warn "Stage mode detected: keep workdir for manual verification (set AUTO_CLEANUP=1 and --promote for auto cleanup)."
    fi
    if [[ "${rc}" -ne 0 ]]; then
        rollback_if_needed
    fi
    if [[ "${cleanup_mode}" == "1" && "${WORKDIR_CREATED}" == "1" && -n "${WORKDIR}" && -d "${WORKDIR}" ]]; then
        rm -rf "${WORKDIR}"
        log_info "Cleaned workdir: ${WORKDIR}"
    elif [[ -n "${WORKDIR}" && -d "${WORKDIR}" ]]; then
        log_warn "Keeping workdir: ${WORKDIR}"
    fi

    local elapsed=$(( "$(date +%s)" - START_TS ))
    log_info "Total elapsed: ${elapsed}s"
    exit "${rc}"
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

ensure_root() {
    [[ "$(id -u)" -eq 0 ]] || die "Run as root."
}

extract_prefix_from_v_output() {
    local out="$1"
    printf '%s\n' "${out}" | sed -n 's/.*--prefix=\([^ ]*\).*/\1/p' | head -n1
}

extract_conf_path_from_v_output() {
    local out="$1"
    printf '%s\n' "${out}" | sed -n 's/.*--conf-path=\([^ ]*\).*/\1/p' | head -n1
}

derive_openresty_root_from_path() {
    local p="$1"
    [[ -n "${p}" ]] || return 1
    p="$(readlink -f "${p}" 2>/dev/null || printf '%s' "${p}")"
    p="${p%/}"

    if [[ "${p}" == */openresty ]]; then
        printf '%s\n' "${p}"
        return 0
    fi

    if [[ "${p}" == *"/openresty/"* ]]; then
        printf '%s\n' "${p%%/openresty/*}/openresty"
        return 0
    fi

    if [[ "$(basename "${p}")" == "nginx" && "$(basename "$(dirname "${p}")")" == "openresty" ]]; then
        printf '%s\n' "$(dirname "${p}")"
        return 0
    fi

    return 1
}

detect_openresty_prefix() {
    local p out prefix unit
    local -a candidates=()

    add_candidate() {
        local v="$1"
        local e
        [[ -n "${v}" ]] || return 0
        v="${v%/}"
        for e in "${candidates[@]:-}"; do
            if [[ "${e}" == "${v}" ]]; then
                return 0
            fi
        done
        candidates+=("${v}")
    }

    if [[ -n "${OPENRESTY_PREFIX}" ]]; then
        add_candidate "${OPENRESTY_PREFIX}"
    fi

    if command_exists openresty; then
        p="$(command -v openresty 2>/dev/null || true)"
        p="$(derive_openresty_root_from_path "${p}" 2>/dev/null || true)"
        add_candidate "${p}"

        out="$(openresty -V 2>&1 || true)"
        prefix="$(extract_prefix_from_v_output "${out}")"
        p="$(derive_openresty_root_from_path "${prefix}" 2>/dev/null || true)"
        add_candidate "${p}"
        prefix="$(extract_conf_path_from_v_output "${out}")"
        p="$(derive_openresty_root_from_path "${prefix}" 2>/dev/null || true)"
        add_candidate "${p}"
    fi

    if command_exists nginx; then
        out="$(nginx -V 2>&1 || true)"
        prefix="$(extract_prefix_from_v_output "${out}")"
        p="$(derive_openresty_root_from_path "${prefix}" 2>/dev/null || true)"
        add_candidate "${p}"
        prefix="$(extract_conf_path_from_v_output "${out}")"
        p="$(derive_openresty_root_from_path "${prefix}" 2>/dev/null || true)"
        add_candidate "${p}"
    fi

    if command_exists systemctl; then
        for unit in openresty.service nginx.service; do
            local fragment=""
            fragment="$(systemctl show -p FragmentPath --value "${unit}" 2>/dev/null || true)"
            if [[ -n "${fragment}" && -f "${fragment}" ]]; then
                while IFS= read -r p; do
                    p="$(derive_openresty_root_from_path "${p}" 2>/dev/null || true)"
                    add_candidate "${p}"
                done < <(grep -Eo '/[^[:space:]]*openresty[^[:space:]]*' "${fragment}" || true)
            fi
        done
    fi

    if [[ -z "${OPENRESTY_PREFIX}" && -d "/usr/local/openresty" ]]; then
        add_candidate "/usr/local/openresty"
    fi

    OPENRESTY_PREFIX_DETECTED=""
    for p in "${candidates[@]:-}"; do
        if [[ -d "${p}" ]]; then
            OPENRESTY_PREFIX_DETECTED="${p}"
            break
        fi
    done
    if [[ -z "${OPENRESTY_PREFIX_DETECTED}" && ${#candidates[@]} -gt 0 ]]; then
        OPENRESTY_PREFIX_DETECTED="${candidates[0]}"
    fi
}

safety_guard() {
    detect_openresty_prefix

    if [[ -n "${OPENRESTY_PREFIX_DETECTED}" ]]; then
        case "${NGINX_PREFIX}" in
            "${OPENRESTY_PREFIX_DETECTED}"|${OPENRESTY_PREFIX_DETECTED}/*)
                die "NGINX_PREFIX (${NGINX_PREFIX}) overlaps detected OpenResty prefix (${OPENRESTY_PREFIX_DETECTED}); refuse to modify openresty tree."
                ;;
        esac
        if [[ -d "${OPENRESTY_PREFIX_DETECTED}" ]]; then
            log_info "Detected existing OpenResty at ${OPENRESTY_PREFIX_DETECTED}. This script will not delete or modify that directory."
        fi
    else
        log_warn "OpenResty path not detected from binaries/systemd. Continuing with caution."
    fi
}

detect_os() {
    [[ -f /etc/os-release ]] || die "/etc/os-release not found."
    # shellcheck disable=SC1091
    source /etc/os-release

    if [[ "${ID_LIKE:-}" == *"debian"* || "${ID:-}" == "debian" || "${ID:-}" == "ubuntu" ]]; then
        OS_FAMILY="debian"
    elif [[ "${ID_LIKE:-}" == *"rhel"* || "${ID_LIKE:-}" == *"fedora"* || \
            "${ID:-}" == "rhel" || "${ID:-}" == "centos" || "${ID:-}" == "rocky" || \
            "${ID:-}" == "almalinux" || "${ID:-}" == "fedora" ]]; then
        OS_FAMILY="redhat"
    else
        die "Unsupported OS: ${PRETTY_NAME:-unknown}"
    fi
    log_info "Detected OS: ${PRETTY_NAME:-unknown} (${OS_FAMILY})"
}

fetch_url() {
    local url="$1"
    if command_exists curl; then
        curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 "${url}"
    elif command_exists wget; then
        wget -qO- "${url}"
    else
        die "Neither curl nor wget found."
    fi
}

download_file() {
    local url="$1"
    local out="$2"
    if command_exists curl; then
        curl -fL --retry 5 --retry-delay 2 --connect-timeout 15 -o "${out}" "${url}"
    else
        wget -O "${out}" "${url}"
    fi
}

install_deps_debian() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get -y update
    apt-get -y install --no-install-recommends \
        ca-certificates curl wget git tar gzip bzip2 xz-utils unzip \
        build-essential gcc g++ make cmake autoconf automake libtool pkg-config \
        patch sed gawk perl file \
        zlib1g-dev libssl-dev libpcre2-dev libreadline-dev libncurses-dev \
        libmaxminddb-dev
}

install_deps_redhat() {
    if command_exists dnf; then
        PKG_MANAGER="dnf"
    elif command_exists yum; then
        PKG_MANAGER="yum"
    else
        die "Neither dnf nor yum found."
    fi

    if [[ "${PKG_MANAGER}" == "dnf" ]]; then
        dnf -y install epel-release || true
        dnf -y install dnf-plugins-core || true
        dnf -y config-manager --set-enabled crb || true
        dnf -y config-manager --set-enabled powertools || true
    fi

    "${PKG_MANAGER}" -y install \
        ca-certificates curl wget git tar gzip bzip2 xz unzip \
        gcc gcc-c++ make cmake autoconf automake libtool pkgconfig \
        patch sed gawk perl file \
        zlib-devel openssl-devel pcre2-devel readline-devel ncurses-devel \
        libmaxminddb-devel
}

install_build_deps() {
    phase "Install build dependencies"
    case "${OS_FAMILY}" in
        debian) install_deps_debian ;;
        redhat) install_deps_redhat ;;
        *) die "Unsupported OS family: ${OS_FAMILY}" ;;
    esac
}

discover_nginx_stable() {
    local listing versions v minor
    listing="$(fetch_url "https://nginx.org/download/")" || return 1
    versions="$(printf '%s' "${listing}" \
        | grep -Eo 'nginx-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz' \
        | sed -E 's/^nginx-([0-9.]+)\.tar\.gz$/\1/' \
        | sort -Vu)"
    [[ -n "${versions}" ]] || return 1

    while IFS= read -r v; do
        minor="$(printf '%s' "${v}" | cut -d. -f2)"
        if [[ "${minor}" =~ ^[0-9]+$ ]] && (( minor % 2 == 0 )); then
            printf '%s\n' "${v}"
            return 0
        fi
    done < <(printf '%s\n' "${versions}" | sort -Vr)

    return 1
}

discover_semver_from_github_latest_release() {
    local repo="$1"
    local strip_prefix="$2"
    local payload tag version

    payload="$(fetch_url "https://api.github.com/repos/${repo}/releases/latest")" || return 1
    tag="$(printf '%s' "${payload}" \
        | grep -Eo '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' \
        | head -n1 \
        | sed -E 's/^"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)"$/\1/')"
    [[ -n "${tag}" ]] || return 1

    if [[ -n "${strip_prefix}" ]]; then
        tag="${tag#${strip_prefix}}"
    fi

    version="$(printf '%s' "${tag}" | grep -Eo '[0-9]+(\.[0-9]+){1,3}' | head -n1 || true)"
    [[ -n "${version}" ]] || return 1
    printf '%s\n' "${version}"
}

resolve_versions() {
    phase "Resolve version matrix"

    AUTO_LATEST="$(normalize_bool "${AUTO_LATEST}")"
    ENABLE_JEMALLOC="$(normalize_bool "${ENABLE_JEMALLOC}")"
    ASSUME_YES="$(normalize_bool "${ASSUME_YES}")"
    AUTO_CLEANUP="$(normalize_bool "${AUTO_CLEANUP}")"
    ACTIVATE_SERVICE="$(normalize_bool "${ACTIVATE_SERVICE}")"
    LINK_NGINX_BIN="$(normalize_bool "${LINK_NGINX_BIN}")"
    DRY_RUN="$(normalize_bool "${DRY_RUN}")"
    INSTALL_MODE="$(normalize_mode "${INSTALL_MODE}")"

    if [[ "${AUTO_LATEST}" == "1" ]]; then
        local v
        if v="$(discover_nginx_stable)"; then NGINX_VERSION="${v}"; else log_warn "Failed to discover nginx stable; using ${NGINX_VERSION}"; fi
        if v="$(discover_semver_from_github_latest_release "openssl/openssl" "openssl-")"; then OPENSSL_VERSION="${v}"; else log_warn "Failed to discover OpenSSL; using ${OPENSSL_VERSION}"; fi
        if v="$(discover_semver_from_github_latest_release "PCRE2Project/pcre2" "pcre2-")"; then PCRE2_VERSION="${v}"; else log_warn "Failed to discover PCRE2; using ${PCRE2_VERSION}"; fi
        if v="$(discover_semver_from_github_latest_release "jemalloc/jemalloc" "")"; then JEMALLOC_VERSION="${v}"; else log_warn "Failed to discover jemalloc; using ${JEMALLOC_VERSION}"; fi
        if v="$(discover_semver_from_github_latest_release "maxmind/libmaxminddb" "")"; then LIBMAXMINDDB_VERSION="${v}"; else log_warn "Failed to discover libmaxminddb; using ${LIBMAXMINDDB_VERSION}"; fi
    fi

    log_info "Nginx version:        ${NGINX_VERSION}"
    log_info "OpenSSL version:      ${OPENSSL_VERSION}"
    log_info "PCRE2 version:        ${PCRE2_VERSION}"
    log_info "jemalloc version:     ${JEMALLOC_VERSION}"
    log_info "libmaxminddb version: ${LIBMAXMINDDB_VERSION}"
    log_info "Install mode:         ${INSTALL_MODE}"
    log_info "Dry run:              ${DRY_RUN}"
}

resolve_brand() {
    if [[ "${DRY_RUN}" == "1" && "${BRAND_MODE}" == "ask" ]]; then
        TARGET_BRAND=""
        log_info "Dry-run mode: skip interactive brand prompt (use --brand/--no-brand to test branding behavior)."
        return 0
    fi

    case "${BRAND_MODE}" in
        set)
            TARGET_BRAND="${BRAND_NAME}"
            ;;
        keep)
            TARGET_BRAND=""
            ;;
        ask)
            if [[ "${ASSUME_YES}" == "1" || ! -t 0 ]]; then
                TARGET_BRAND=""
            else
                read -r -p "Replace server brand string? (y/N): " ans
                ans="$(printf '%s' "${ans}" | tr '[:upper:]' '[:lower:]')"
                if [[ "${ans}" == "y" || "${ans}" == "yes" ]]; then
                    read -r -p "New brand (default: ${BRAND_NAME}): " custom
                    TARGET_BRAND="${custom:-${BRAND_NAME}}"
                else
                    TARGET_BRAND=""
                fi
            fi
            ;;
        *)
            die "Invalid BRAND_MODE: ${BRAND_MODE} (ask|set|keep)"
            ;;
    esac

    if [[ -n "${TARGET_BRAND}" ]]; then
        log_info "Brand masking enabled: ${TARGET_BRAND}"
    else
        log_info "Brand masking disabled."
    fi
}

resolve_waf_source() {
    phase "Resolve WAF source"

    WAF_SOURCE_MODE="$(normalize_waf_source_mode "${WAF_SOURCE_MODE}")"
    WAF_REPO_SUBDIR="$(normalize_waf_subdir "${WAF_REPO_SUBDIR}")"

    if [[ "${WAF_SOURCE_MODE}" == "local" ]]; then
        if [[ -z "${WAF_SOURCE_DIR}" ]]; then
            if [[ -d "${SCRIPT_DIR}/../waf" ]]; then
                WAF_SOURCE_DIR="${SCRIPT_DIR}/../waf"
            else
                WAF_SOURCE_DIR="${SCRIPT_DIR}/waf"
            fi
        fi

        if [[ -d "${WAF_SOURCE_DIR}" ]]; then
            WAF_EFFECTIVE_SOURCE_DIR="$(readlink -f "${WAF_SOURCE_DIR}" 2>/dev/null || printf '%s' "${WAF_SOURCE_DIR}")"
            log_info "WAF source mode:      local"
            log_info "WAF local source:     ${WAF_EFFECTIVE_SOURCE_DIR}"
        else
            WAF_EFFECTIVE_SOURCE_DIR=""
            log_warn "WAF source mode is local but directory is missing: ${WAF_SOURCE_DIR} (WAF integration will be skipped)."
        fi
        return 0
    fi

    WAF_EFFECTIVE_SOURCE_DIR=""
    log_info "WAF source mode:      online"
    log_info "WAF repo:             ${WAF_REPO_URL}"
    log_info "WAF repo ref:         ${WAF_REPO_REF:-<default branch>}"
    log_info "WAF repo subdir:      ${WAF_REPO_SUBDIR}"
}

prepare_workspace() {
    phase "Prepare workspace"
    if [[ -z "${WORKDIR}" ]]; then
        WORKDIR="$(mktemp -d -t nginx-build-XXXXXXXXXX)"
        WORKDIR_CREATED=1
    else
        mkdir -p "${WORKDIR}"
    fi
    SRC_DIR="${WORKDIR}/src"
    INSTALL_STAGE_ROOT="${WORKDIR}/install-root"
    mkdir -p "${SRC_DIR}"
    mkdir -p "${INSTALL_STAGE_ROOT}"
    log_info "Workdir: ${WORKDIR}"
}

prepare_waf_source() {
    if [[ "${WAF_SOURCE_MODE}" != "online" ]]; then
        return 0
    fi

    phase "Fetch online WAF source"
    WAF_REPO_CLONE_DIR="${SRC_DIR}/waf-source-repo"
    clone_repo_once "${WAF_REPO_URL}" "${WAF_REPO_CLONE_DIR}" "${WAF_REPO_REF}" || \
        die "Failed to fetch online WAF repo: ${WAF_REPO_URL}"

    WAF_EFFECTIVE_SOURCE_DIR="${WAF_REPO_CLONE_DIR}/${WAF_REPO_SUBDIR}"
    [[ -d "${WAF_EFFECTIVE_SOURCE_DIR}" ]] || \
        die "WAF subdir not found: ${WAF_REPO_SUBDIR} (repo=${WAF_REPO_URL}, ref=${WAF_REPO_REF:-default})"

    log_info "Online WAF source ready: ${WAF_EFFECTIVE_SOURCE_DIR}"
}

create_nginx_user_group() {
    phase "Ensure nginx runtime user/group"
    if ! getent group "${NGINX_GROUP}" >/dev/null 2>&1; then
        groupadd --system "${NGINX_GROUP}"
    fi
    if ! id -u "${NGINX_USER}" >/dev/null 2>&1; then
        useradd --system --no-create-home --gid "${NGINX_GROUP}" --shell /sbin/nologin "${NGINX_USER}" \
            || useradd --system --no-create-home --gid "${NGINX_GROUP}" --shell /usr/sbin/nologin "${NGINX_USER}"
    fi
}

extract_archive() {
    local archive="$1"
    case "${archive}" in
        *.tar.gz|*.tgz) tar -xzf "${archive}" ;;
        *.tar.bz2) tar -xjf "${archive}" ;;
        *.tar.xz) tar -xJf "${archive}" ;;
        *) die "Unsupported archive type: ${archive}" ;;
    esac
}

download_sources() {
    phase "Download source tarballs"
    cd "${SRC_DIR}"

    local nginx_tgz="nginx-${NGINX_VERSION}.tar.gz"
    local openssl_tgz="openssl-${OPENSSL_VERSION}.tar.gz"
    local pcre2_tgz="pcre2-${PCRE2_VERSION}.tar.gz"
    local jemalloc_tbz2="jemalloc-${JEMALLOC_VERSION}.tar.bz2"
    local mmdb_tgz="libmaxminddb-${LIBMAXMINDDB_VERSION}.tar.gz"

    download_file "https://nginx.org/download/${nginx_tgz}" "${nginx_tgz}"
    download_file "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/${openssl_tgz}" "${openssl_tgz}"
    download_file "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE2_VERSION}/${pcre2_tgz}" "${pcre2_tgz}"
    download_file "https://github.com/jemalloc/jemalloc/releases/download/${JEMALLOC_VERSION}/${jemalloc_tbz2}" "${jemalloc_tbz2}"
    download_file "https://github.com/maxmind/libmaxminddb/releases/download/${LIBMAXMINDDB_VERSION}/${mmdb_tgz}" "${mmdb_tgz}"

    extract_archive "${nginx_tgz}"
    extract_archive "${openssl_tgz}"
    extract_archive "${pcre2_tgz}"
    extract_archive "${jemalloc_tbz2}"
    extract_archive "${mmdb_tgz}"
}

clone_repo_once() {
    local repo="$1"
    local dst="$2"
    local ref="$3"
    local attempt

    for attempt in 1 2 3; do
        rm -rf "${dst}"
        if [[ -n "${ref}" ]]; then
            if git clone --depth 1 --branch "${ref}" "${repo}" "${dst}" >/dev/null 2>&1; then
                return 0
            fi
        fi

        if git clone --depth 1 "${repo}" "${dst}" >/dev/null 2>&1; then
            if [[ -n "${ref}" ]]; then
                if (
                    cd "${dst}" &&
                    (git fetch --depth 1 origin "${ref}" >/dev/null 2>&1 || git fetch --tags --depth 1 >/dev/null 2>&1 || true) &&
                    git checkout "${ref}" >/dev/null 2>&1
                ); then
                    return 0
                fi
                rm -rf "${dst}"
            else
                return 0
            fi
        fi
        sleep $(( attempt * 2 ))
    done
    return 1
}

clone_module() {
    local dst="$1"
    local ref="$2"
    shift 2
    local repo

    for repo in "$@"; do
        if clone_repo_once "${repo}" "${dst}" "${ref}"; then
            log_info "Fetched $(basename "${dst}") from ${repo}"
            return 0
        fi
        log_warn "Clone failed from ${repo}, trying next source..."
    done
    die "Failed to fetch module into ${dst}"
}

download_modules() {
    phase "Download module sources"
    cd "${SRC_DIR}"

    clone_module "${SRC_DIR}/luajit2" "${LUAJIT_REF}" "${LUAJIT_REPO}"
    clone_module "${SRC_DIR}/ngx_devel_kit" "${NDK_REF}" "${NDK_REPO_PRIMARY}" "${NDK_REPO_FALLBACK}"
    clone_module "${SRC_DIR}/lua-nginx-module" "${LUA_NGINX_REF}" "${LUA_NGINX_REPO}"
    clone_module "${SRC_DIR}/stream-lua-nginx-module" "${STREAM_LUA_REF}" "${STREAM_LUA_REPO}"
    clone_module "${SRC_DIR}/ngx_http_geoip2_module" "${GEOIP2_REF}" "${GEOIP2_REPO}"
    clone_module "${SRC_DIR}/ngx_http_substitutions_filter_module" "${SUBS_REF}" "${SUBS_REPO}"
    clone_module "${SRC_DIR}/lua-resty-core" "${RESTY_CORE_REF}" "${RESTY_CORE_REPO}"
    clone_module "${SRC_DIR}/lua-resty-lrucache" "${RESTY_LRUCACHE_REF}" "${RESTY_LRUCACHE_REPO}"
    clone_module "${SRC_DIR}/lua-resty-http" "${RESTY_HTTP_REF}" "${RESTY_HTTP_REPO}"
    clone_module "${SRC_DIR}/lua-cjson" "${LUA_CJSON_REF}" "${LUA_CJSON_REPO}"
}

build_jemalloc() {
    [[ "${ENABLE_JEMALLOC}" == "1" ]] || { log_info "jemalloc disabled."; return 0; }
    phase "Build jemalloc"
    (
        cd "${SRC_DIR}/jemalloc-${JEMALLOC_VERSION}"
        ./configure
        make -j "${JOBS}"
        make install
    )
}

build_libmaxminddb() {
    phase "Build libmaxminddb"
    (
        cd "${SRC_DIR}/libmaxminddb-${LIBMAXMINDDB_VERSION}"
        ./configure
        make -j "${JOBS}"
        make install
    )
}

build_luajit() {
    phase "Build LuaJIT"
    (
        cd "${SRC_DIR}/luajit2"
        make -j "${JOBS}"
        make install PREFIX="${LUAJIT_PREFIX}"
    )
}

build_lua_cjson() {
    phase "Build lua-cjson"

    mkdir -p "${LUA_SHARE_DIR}"
    mkdir -p "${LUA_CPATH_DIR}"

    (
        cd "${SRC_DIR}/lua-cjson"
        make clean >/dev/null 2>&1 || true
        make -j "${JOBS}" LUA_INCLUDE_DIR="${LUAJIT_PREFIX}/include/luajit-2.1"
        make install \
            LUA_INCLUDE_DIR="${LUAJIT_PREFIX}/include/luajit-2.1" \
            LUA_MODULE_DIR="${LUA_SHARE_DIR}" \
            LUA_CMODULE_DIR="${LUA_CPATH_DIR}"
    )

    [[ -f "${LUA_CPATH_DIR}/cjson.so" ]] || die "lua-cjson install failed: ${LUA_CPATH_DIR}/cjson.so missing"
    if [[ ! -f "${LUA_SHARE_DIR}/cjson/safe.lua" ]]; then
        mkdir -p "${LUA_SHARE_DIR}/cjson"
        cat > "${LUA_SHARE_DIR}/cjson/safe.lua" <<'EOF'
local cjson = require "cjson"

local safe = {}
for k, v in pairs(cjson) do
    safe[k] = v
end

safe.encode = function(...)
    local ok, res = pcall(cjson.encode, ...)
    if ok then
        return res
    end
    return nil, res
end

safe.decode = function(...)
    local ok, res = pcall(cjson.decode, ...)
    if ok then
        return res
    end
    return nil, res
end

return safe
EOF
        log_warn "lua-cjson safe.lua was missing and has been generated at ${LUA_SHARE_DIR}/cjson/safe.lua."
    fi
}

install_lua_resty_runtime() {
    phase "Install lua-resty runtime libraries"

    mkdir -p "${LUA_SHARE_DIR}"
    mkdir -p "${LUA_SHARE_DIR}/resty"
    mkdir -p "${LUA_CPATH_DIR}"

    if [[ -d "${SRC_DIR}/lua-resty-core/lib" ]]; then
        cp -a "${SRC_DIR}/lua-resty-core/lib/." "${LUA_SHARE_DIR}/"
    fi
    if [[ -d "${SRC_DIR}/lua-resty-lrucache/lib" ]]; then
        cp -a "${SRC_DIR}/lua-resty-lrucache/lib/." "${LUA_SHARE_DIR}/"
    fi
    if [[ -d "${SRC_DIR}/lua-resty-http/lib" ]]; then
        cp -a "${SRC_DIR}/lua-resty-http/lib/." "${LUA_SHARE_DIR}/"
    fi

    [[ -f "${LUA_SHARE_DIR}/resty/core.lua" ]] || die "lua-resty-core install failed: ${LUA_SHARE_DIR}/resty/core.lua missing"
    [[ -f "${LUA_SHARE_DIR}/resty/http.lua" ]] || log_warn "lua-resty-http not found at ${LUA_SHARE_DIR}/resty/http.lua (turnstile verify may be unavailable)"

    log_info "Lua share dir ready: ${LUA_SHARE_DIR}"
}

install_candidate_lua_runtime() {
    local target_prefix="$1"
    phase "Install Lua runtime into candidate prefix"

    local candidate_lua_dir="${target_prefix}/conf/lua"
    mkdir -p "${candidate_lua_dir}"
    mkdir -p "${candidate_lua_dir}/cjson"

    if [[ -d "${SRC_DIR}/lua-resty-core/lib" ]]; then
        cp -a "${SRC_DIR}/lua-resty-core/lib/." "${candidate_lua_dir}/"
    fi
    if [[ -d "${SRC_DIR}/lua-resty-lrucache/lib" ]]; then
        cp -a "${SRC_DIR}/lua-resty-lrucache/lib/." "${candidate_lua_dir}/"
    fi
    if [[ -d "${SRC_DIR}/lua-resty-http/lib" ]]; then
        cp -a "${SRC_DIR}/lua-resty-http/lib/." "${candidate_lua_dir}/"
    fi

    if [[ -f "${LUA_CPATH_DIR}/cjson.so" ]]; then
        cp -a "${LUA_CPATH_DIR}/cjson.so" "${candidate_lua_dir}/cjson.so"
    fi
    if [[ -f "${LUA_SHARE_DIR}/cjson/safe.lua" ]]; then
        cp -a "${LUA_SHARE_DIR}/cjson/safe.lua" "${candidate_lua_dir}/cjson/safe.lua"
    fi

    [[ -f "${candidate_lua_dir}/resty/core.lua" ]] || die "Candidate lua runtime incomplete: ${candidate_lua_dir}/resty/core.lua missing"
    [[ -f "${candidate_lua_dir}/cjson.so" ]] || die "Candidate lua runtime incomplete: ${candidate_lua_dir}/cjson.so missing"
    [[ -f "${candidate_lua_dir}/cjson/safe.lua" ]] || die "Candidate lua runtime incomplete: ${candidate_lua_dir}/cjson/safe.lua missing"
}

refresh_ldconfig() {
    phase "Refresh dynamic linker cache"
    cat >/etc/ld.so.conf.d/nginx-source-build.conf <<EOF
/usr/local/lib
${LUAJIT_PREFIX}/lib
EOF
    ldconfig
}

escape_sed() {
    printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'
}

apply_brand_mask() {
    [[ -n "${TARGET_BRAND}" ]] || return 0
    phase "Apply brand mask in nginx source"

    local src_root="${SRC_DIR}/nginx-${NGINX_VERSION}"
    local v2_file="${src_root}/src/http/v2/ngx_http_v2_filter_module.c"
    local v3_file="${src_root}/src/http/v3/ngx_http_v3_filter_module.c"
    local safe_brand
    safe_brand="$(escape_sed "${TARGET_BRAND}")"

    sed -i -E "s|#define NGINX_VER[[:space:]]+\"nginx/\" NGINX_VERSION|#define NGINX_VER          \"${safe_brand}\"|g" "${src_root}/src/core/nginx.h"
    sed -i -E "s|#define NGINX_VER_BUILD[[:space:]]+NGINX_VER \" \\(\" NGX_BUILD \"\\)\"|#define NGINX_VER_BUILD    NGINX_VER|g" "${src_root}/src/core/nginx.h"
    sed -i -E "s|#define NGINX_VAR[[:space:]]+\"NGINX\"|#define NGINX_VAR          \"${safe_brand}\"|g" "${src_root}/src/core/nginx.h"

    sed -i "s|Server: nginx|Server: ${safe_brand}|g" "${src_root}/src/http/ngx_http_header_filter_module.c"
    sed -i "s|<hr><center>nginx</center>|<hr><center>${safe_brand}</center>|g" "${src_root}/src/http/ngx_http_special_response.c"

    if [[ -f "${v2_file}" ]]; then
        # HTTP/2: server_tokens off uses pre-encoded "nginx" bytes in older code paths.
        # Rewrite to reuse nginx_ver (derived from NGINX_VER) so custom brand is applied.
        perl -0777 -i -pe 's/len \+= 1 \+ sizeof\(nginx\);/len += 1 + nginx_ver_len;/g' "${v2_file}"
        perl -0777 -i -pe 's/pos = ngx_cpymem\(pos, nginx, sizeof\(nginx\)\);/if (nginx_ver[0] == 0) {\n                p = ngx_http_v2_write_value(nginx_ver, (u_char *) NGINX_VER,\n                                            sizeof(NGINX_VER) - 1, tmp);\n                nginx_ver_len = p - nginx_ver;\n            }\n\n            pos = ngx_cpymem(pos, nginx_ver, nginx_ver_len);/g' "${v2_file}"
        sed -i "s|server: nginx|server: ${safe_brand}|g" "${v2_file}"
        if ! grep -Fq 'pos = ngx_cpymem(pos, nginx, sizeof(nginx));' "${v2_file}"; then
            perl -0777 -i -pe 's/^[ \t]*static const u_char nginx\[5\][ \t]*=[ \t]*\{[^\n]*\};\n//m' "${v2_file}"
        fi

        if grep -Fq 'len += 1 + sizeof(nginx);' "${v2_file}" || grep -Fq 'pos = ngx_cpymem(pos, nginx, sizeof(nginx));' "${v2_file}"; then
            log_warn "HTTP/2 brand patch did not fully apply. Please review: ${v2_file}"
        elif grep -Fq 'static const u_char nginx[5]' "${v2_file}" && ! grep -Fq 'pos = ngx_cpymem(pos, nginx, sizeof(nginx));' "${v2_file}"; then
            log_warn "HTTP/2 brand patch left unused nginx const. Please review: ${v2_file}"
        fi
    fi

    if [[ -f "${v3_file}" ]]; then
        # HTTP/3: server_tokens off path uses literal "nginx" in size/value branches.
        sed -i 's|sizeof("nginx") - 1|sizeof(NGINX_VER) - 1|g' "${v3_file}"
        sed -i 's|(u_char *) "nginx"|(u_char *) NGINX_VER|g' "${v3_file}"

        if grep -Fq 'sizeof("nginx") - 1' "${v3_file}" || grep -Fq '(u_char *) "nginx"' "${v3_file}"; then
            log_warn "HTTP/3 brand patch did not fully apply. Please review: ${v3_file}"
        fi
    fi
}

build_and_install_nginx() {
    phase "Configure, build and install nginx (candidate)"

    local src_root="${SRC_DIR}/nginx-${NGINX_VERSION}"
    local cc_opt ld_opt
    cc_opt="-O2 -fstack-protector-strong -Wformat -Werror=format-security -I${LUAJIT_PREFIX}/include/luajit-2.1"
    ld_opt="-Wl,-rpath,${LUAJIT_PREFIX}/lib -L${LUAJIT_PREFIX}/lib -Wl,-rpath,/usr/local/lib -L/usr/local/lib"
    if [[ "${ENABLE_JEMALLOC}" == "1" ]]; then
        ld_opt="${ld_opt} -ljemalloc"
    fi

    export LUAJIT_LIB="${LUAJIT_PREFIX}/lib"
    export LUAJIT_INC="${LUAJIT_PREFIX}/include/luajit-2.1"

    (
        cd "${src_root}"
        local args=(
            "--prefix=${NGINX_PREFIX}"
            "--user=${NGINX_USER}"
            "--group=${NGINX_GROUP}"
            "--with-compat"
            "--with-file-aio"
            "--with-threads"
            "--with-http_ssl_module"
            "--with-http_v2_module"
            "--with-http_realip_module"
            "--with-http_sub_module"
            "--with-http_gzip_static_module"
            "--with-http_gunzip_module"
            "--with-http_stub_status_module"
            "--with-http_auth_request_module"
            "--with-http_slice_module"
            "--with-stream"
            "--with-stream_ssl_module"
            "--with-stream_ssl_preread_module"
            "--with-stream_realip_module"
            "--with-pcre=../pcre2-${PCRE2_VERSION}"
            "--with-pcre-jit"
            "--with-openssl=../openssl-${OPENSSL_VERSION}"
            "--with-cc-opt=${cc_opt}"
            "--with-ld-opt=${ld_opt}"
            "--add-module=../ngx_devel_kit"
            "--add-module=../lua-nginx-module"
            "--add-module=../stream-lua-nginx-module"
            "--add-module=../ngx_http_geoip2_module"
            "--add-module=../ngx_http_substitutions_filter_module"
        )

        ./configure "${args[@]}"
        make -j "${JOBS}"
        rm -rf "${INSTALL_STAGE_ROOT}"
        mkdir -p "${INSTALL_STAGE_ROOT}"
        make install DESTDIR="${INSTALL_STAGE_ROOT}"
    )

    CANDIDATE_PREFIX="${INSTALL_STAGE_ROOT}${NGINX_PREFIX}"
    [[ -x "${CANDIDATE_PREFIX}/sbin/nginx" ]] || die "Candidate nginx binary not found: ${CANDIDATE_PREFIX}/sbin/nginx"
    [[ -f "${CANDIDATE_PREFIX}/conf/nginx.conf" ]] || die "Candidate nginx.conf not found: ${CANDIDATE_PREFIX}/conf/nginx.conf"
    log_info "Candidate prefix: ${CANDIDATE_PREFIX}"
}

replace_first_directive() {
    local file="$1"
    local key="$2"
    local newline="$3"
    local tmp

    tmp="$(mktemp)"
    if awk -v key="${key}" -v newline="${newline}" '
        BEGIN { done=0 }
        {
            if (!done && $0 ~ "^[[:space:]]*#?[[:space:]]*" key "[[:space:]]+[^;]*;[[:space:]]*$") {
                print newline
                done=1
                next
            }
            print
        }
        END {
            if (!done) exit 42
        }
    ' "${file}" > "${tmp}"; then
        mv "${tmp}" "${file}"
        return 0
    fi

    local rc=$?
    rm -f "${tmp}"
    if [[ "${rc}" -eq 42 ]]; then
        return 1
    fi
    return "${rc}"
}

ensure_line_in_http_block() {
    local file="$1"
    local line="$2"
    local tmp

    if grep -Fq "${line}" "${file}"; then
        return 0
    fi

    tmp="$(mktemp)"
    awk -v line="${line}" '
        BEGIN { inserted=0 }
        {
            print
            if (!inserted && $0 ~ /^[[:space:]]*http[[:space:]]*\{[[:space:]]*$/) {
                print "    " line
                inserted=1
            }
        }
        END {
            if (!inserted) {
                print ""
                print "http {"
                print "    " line
                print "}"
            }
        }
    ' "${file}" > "${tmp}"
    mv "${tmp}" "${file}"
}

has_active_log_format() {
    local file="$1"
    local name="$2"
    grep -Eq "^[[:space:]]*log_format[[:space:]]+${name}([[:space:]]|$)" "${file}"
}

configure_nginx_conf() {
    local target_prefix="$1"
    phase "Configure nginx.conf"

    local conf_file="${target_prefix}/conf/nginx.conf"
    local main_format_line
    local json_format_line
    local lua_package_path_line
    local lua_package_cpath_line
    [[ -f "${conf_file}" ]] || die "nginx.conf not found: ${conf_file}"

    main_format_line="log_format main '\$remote_addr - \$remote_user [\$time_local] \"\$request\" \$status \$body_bytes_sent \"\$http_referer\" \"\$http_user_agent\" \"\$http_x_forwarded_for\"';"
    json_format_line="log_format json escape=json '{\"time\":\"\$time_iso8601\",\"remote_addr\":\"\$remote_addr\",\"x_forwarded_for\":\"\$http_x_forwarded_for\",\"request_id\":\"\$request_id\",\"remote_user\":\"\$remote_user\",\"request\":\"\$request\",\"status\":\$status,\"body_bytes_sent\":\$body_bytes_sent,\"request_time\":\$request_time,\"upstream_addr\":\"\$upstream_addr\",\"upstream_status\":\"\$upstream_status\",\"upstream_response_time\":\"\$upstream_response_time\",\"referer\":\"\$http_referer\",\"user_agent\":\"\$http_user_agent\",\"host\":\"\$host\",\"server_name\":\"\$server_name\",\"uri\":\"\$uri\",\"args\":\"\$args\"}';"
    lua_package_path_line="lua_package_path \"\$prefix/conf/lua/?.lua;\$prefix/conf/lua/?/init.lua;\$prefix/conf/waf/?.lua;\$prefix/conf/waf/?/init.lua;${LUA_SHARE_DIR}/?.lua;${LUA_SHARE_DIR}/?/init.lua;;\";"
    lua_package_cpath_line="lua_package_cpath \"\$prefix/conf/lua/?.so;\$prefix/conf/lua/?/?.so;${LUAJIT_PREFIX}/lib/lua/5.1/?.so;${LUAJIT_PREFIX}/lib/lua/5.1/?/?.so;${LUA_CPATH_DIR}/?.so;${LUA_CPATH_DIR}/?/?.so;;\";"

    mkdir -p "${LOG_DIR}"
    chown -R "${NGINX_USER}:${NGINX_GROUP}" "${LOG_DIR}"
    chmod 755 "${LOG_DIR}"

    cp -a "${conf_file}" "${conf_file}.bak.$(date +%Y%m%d%H%M%S)"

    replace_first_directive "${conf_file}" "user" "user ${NGINX_USER} ${NGINX_GROUP};" || \
        printf '%s\n' "user ${NGINX_USER} ${NGINX_GROUP};" >> "${conf_file}"

    replace_first_directive "${conf_file}" "worker_processes" "worker_processes auto;" || \
        printf '%s\n' "worker_processes auto;" >> "${conf_file}"

    replace_first_directive "${conf_file}" "pid" "pid ${PID_FILE};" || \
        printf '%s\n' "pid ${PID_FILE};" >> "${conf_file}"

    replace_first_directive "${conf_file}" "error_log" "error_log ${LOG_DIR}/error.log warn;" || \
        printf '%s\n' "error_log ${LOG_DIR}/error.log warn;" >> "${conf_file}"

    if ! replace_first_directive "${conf_file}" "access_log" "    access_log ${LOG_DIR}/access.log json;"; then
        ensure_line_in_http_block "${conf_file}" "access_log ${LOG_DIR}/access.log json;"
    fi

    if ! has_active_log_format "${conf_file}" "main"; then
        ensure_line_in_http_block "${conf_file}" "${main_format_line}"
    fi

    if ! has_active_log_format "${conf_file}" "json"; then
        ensure_line_in_http_block "${conf_file}" "${json_format_line}"
    fi

    if ! replace_first_directive "${conf_file}" "lua_package_path" "    ${lua_package_path_line}"; then
        ensure_line_in_http_block "${conf_file}" "${lua_package_path_line}"
    fi

    if ! replace_first_directive "${conf_file}" "lua_package_cpath" "    ${lua_package_cpath_line}"; then
        ensure_line_in_http_block "${conf_file}" "${lua_package_cpath_line}"
    fi
}

integrate_waf() {
    local target_prefix="$1"
    phase "Integrate waf/ rules"

    local conf_file="${target_prefix}/conf/nginx.conf"
    local waf_target="${target_prefix}/conf/waf"
    local waf_source="${WAF_EFFECTIVE_SOURCE_DIR}"
    local waf_lua_path_line

    if [[ -z "${waf_source}" || ! -d "${waf_source}" ]]; then
        log_warn "waf source not found: ${waf_source:-<empty>} (skip)"
        return 0
    fi

    rm -rf "${waf_target}"
    cp -a "${waf_source}" "${waf_target}"

    if [[ -f "${waf_target}/waf.conf" ]]; then
        waf_lua_path_line="lua_package_path \"\$prefix/conf/lua/?.lua;\$prefix/conf/lua/?/init.lua;\$prefix/conf/waf/?.lua;\$prefix/conf/waf/?/init.lua;${LUA_SHARE_DIR}/?.lua;${LUA_SHARE_DIR}/?/init.lua;;\";"
        sed -i "s|/usr/local/openresty/nginx/conf|${NGINX_PREFIX}/conf|g" "${waf_target}/waf.conf"
        sed -i "s|/usr/local/nginx/conf|${NGINX_PREFIX}/conf|g" "${waf_target}/waf.conf"
        if ! replace_first_directive "${waf_target}/waf.conf" "lua_package_path" "${waf_lua_path_line}"; then
            if ! grep -Fq "${waf_lua_path_line}" "${waf_target}/waf.conf"; then
                sed -i "1i ${waf_lua_path_line}" "${waf_target}/waf.conf"
            fi
        fi
    fi
    if [[ -f "${waf_target}/config.lua" ]]; then
        sed -i "s|/usr/local/openresty/nginx/conf|${NGINX_PREFIX}/conf|g" "${waf_target}/config.lua"
        sed -i "s|/usr/local/nginx/conf|${NGINX_PREFIX}/conf|g" "${waf_target}/config.lua"
    fi

    sed -i -E 's|^[[:space:]]*include[[:space:]]+conf/waf/waf\.conf;[[:space:]]*$|    include waf/waf.conf;|g' "${conf_file}"
    ensure_line_in_http_block "${conf_file}" "include waf/waf.conf;"
}

validate_nginx_conf() {
    local target_prefix="$1"
    local nginx_bin="${target_prefix}/sbin/nginx"
    local nginx_conf_rel="conf/nginx.conf"
    local nginx_conf_abs="${target_prefix}/${nginx_conf_rel}"
    local lua_path lua_cpath
    [[ -x "${nginx_bin}" ]] || die "nginx binary missing: ${nginx_bin}"
    [[ -f "${nginx_conf_abs}" ]] || die "nginx conf missing: ${nginx_conf_abs}"
    lua_path="${LUA_SHARE_DIR}/?.lua;${LUA_SHARE_DIR}/?/init.lua;${target_prefix}/conf/lua/?.lua;${target_prefix}/conf/lua/?/init.lua;${target_prefix}/conf/waf/?.lua;${target_prefix}/conf/waf/?/init.lua;;"
    lua_cpath="${LUA_CPATH_DIR}/?.so;${LUA_CPATH_DIR}/?/?.so;${target_prefix}/conf/lua/?.so;${target_prefix}/conf/lua/?/?.so;${LUAJIT_PREFIX}/lib/lua/5.1/?.so;${LUAJIT_PREFIX}/lib/lua/5.1/?/?.so;;"
    LUA_PATH="${lua_path}" LUA_CPATH="${lua_cpath}" \
        "${nginx_bin}" -t -q -p "${target_prefix}/" -c "${nginx_conf_rel}"
}

validate_candidate() {
    phase "Validate candidate build"
    validate_nginx_conf "${CANDIDATE_PREFIX}"
    log_info "Candidate validation passed: ${CANDIDATE_PREFIX}"
}

write_systemd_unit() {
    local target_prefix="$1"
    phase "Install systemd service"

    if ! command_exists systemctl; then
        log_warn "systemctl not found; skip systemd unit install."
        return 0
    fi

    local nginx_bin="${target_prefix}/sbin/nginx"
    local nginx_conf_rel="conf/nginx.conf"
    local nginx_prefix_arg="${target_prefix}/"
    local lua_path lua_cpath
    local desc
    desc="${TARGET_BRAND:-Nginx} source build"
    lua_path="${LUA_SHARE_DIR}/?.lua;${LUA_SHARE_DIR}/?/init.lua;${target_prefix}/conf/lua/?.lua;${target_prefix}/conf/lua/?/init.lua;${target_prefix}/conf/waf/?.lua;${target_prefix}/conf/waf/?/init.lua;;"
    lua_cpath="${LUA_CPATH_DIR}/?.so;${LUA_CPATH_DIR}/?/?.so;${target_prefix}/conf/lua/?.so;${target_prefix}/conf/lua/?/?.so;${LUAJIT_PREFIX}/lib/lua/5.1/?.so;${LUAJIT_PREFIX}/lib/lua/5.1/?/?.so;;"

    cat > "${SERVICE_UNIT_FILE}" <<EOF
[Unit]
Description=${desc}
After=network.target network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=${PID_FILE}
Environment="LUA_PATH=${lua_path}"
Environment="LUA_CPATH=${lua_cpath}"
ExecStartPre=${nginx_bin} -t -q -p ${nginx_prefix_arg} -c ${nginx_conf_rel}
ExecStart=${nginx_bin} -p ${nginx_prefix_arg} -g 'daemon on; master_process on;' -c ${nginx_conf_rel}
ExecReload=${nginx_bin} -p ${nginx_prefix_arg} -c ${nginx_conf_rel} -s reload
ExecStop=/bin/kill -s QUIT \$MAINPID
TimeoutStopSec=5
KillMode=mixed
PrivateTmp=true
NoNewPrivileges=true
LimitNOFILE=1048576
LimitNPROC=1048576
LimitCORE=infinity

[Install]
WantedBy=multi-user.target
EOF

    if command_exists systemd-analyze; then
        systemd-analyze verify "${SERVICE_UNIT_FILE}" >/dev/null
    fi

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1 || true
}

link_nginx_binary() {
    phase "Link nginx into PATH"
    ln -sf "${NGINX_PREFIX}/sbin/nginx" /usr/bin/nginx
}

start_or_reload_nginx() {
    local target_prefix="$1"
    phase "Validate and start nginx"
    local nginx_bin="${target_prefix}/sbin/nginx"
    local nginx_conf_rel="conf/nginx.conf"
    local lua_path lua_cpath
    log_info "Service target: ${SERVICE_NAME}.service"

    lua_path="${LUA_SHARE_DIR}/?.lua;${LUA_SHARE_DIR}/?/init.lua;${target_prefix}/conf/lua/?.lua;${target_prefix}/conf/lua/?/init.lua;${target_prefix}/conf/waf/?.lua;${target_prefix}/conf/waf/?/init.lua;;"
    lua_cpath="${LUA_CPATH_DIR}/?.so;${LUA_CPATH_DIR}/?/?.so;${target_prefix}/conf/lua/?.so;${target_prefix}/conf/lua/?/?.so;${LUAJIT_PREFIX}/lib/lua/5.1/?.so;${LUAJIT_PREFIX}/lib/lua/5.1/?/?.so;;"

    LUA_PATH="${lua_path}" LUA_CPATH="${lua_cpath}" \
        "${nginx_bin}" -t -q -p "${target_prefix}/" -c "${nginx_conf_rel}"

    if command_exists systemctl; then
        if systemctl is-active --quiet "${SERVICE_NAME}"; then
            systemctl restart "${SERVICE_NAME}"
        else
            systemctl start "${SERVICE_NAME}"
        fi
    else
        if pgrep -x nginx >/dev/null 2>&1; then
            LUA_PATH="${lua_path}" LUA_CPATH="${lua_cpath}" \
                "${nginx_bin}" -p "${target_prefix}/" -c "${nginx_conf_rel}" -s reload
        else
            LUA_PATH="${lua_path}" LUA_CPATH="${lua_cpath}" \
                "${nginx_bin}" -p "${target_prefix}/" -c "${nginx_conf_rel}"
        fi
    fi
}

promote_candidate() {
    phase "Promote candidate to live prefix"
    mkdir -p "${BACKUP_ROOT}"
    PROMOTE_TS="$(date +%Y%m%d%H%M%S)"
    SERVICE_UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
    SERVICE_UNIT_BACKUP="${BACKUP_ROOT}/${SERVICE_NAME}.service.${PROMOTE_TS}.bak"
    LIVE_PREFIX_BACKUP="${BACKUP_ROOT}/nginx-prefix.${PROMOTE_TS}.bak"
    HAD_SERVICE_UNIT=0
    HAD_LIVE_PREFIX=0
    LIVE_PREFIX_MOVED=0
    NEW_PREFIX_DEPLOYED=0
    SERVICE_UNIT_CHANGED=0

    if [[ -f "${SERVICE_UNIT_FILE}" ]]; then
        HAD_SERVICE_UNIT=1
        cp -a "${SERVICE_UNIT_FILE}" "${SERVICE_UNIT_BACKUP}"
        log_info "Backed up systemd unit: ${SERVICE_UNIT_BACKUP}"
    fi

    PROMOTE_IN_PROGRESS=1

    if [[ -d "${NGINX_PREFIX}" ]]; then
        HAD_LIVE_PREFIX=1
        mv "${NGINX_PREFIX}" "${LIVE_PREFIX_BACKUP}"
        LIVE_PREFIX_MOVED=1
        log_info "Backed up live prefix: ${LIVE_PREFIX_BACKUP}"
    fi

    cp -a "${CANDIDATE_PREFIX}" "${NGINX_PREFIX}"
    NEW_PREFIX_DEPLOYED=1
    validate_nginx_conf "${NGINX_PREFIX}"
    if command_exists systemctl; then
        write_systemd_unit "${NGINX_PREFIX}"
        SERVICE_UNIT_CHANGED=1
    else
        log_warn "systemctl not found; skip service unit update."
    fi

    if [[ "${LINK_NGINX_BIN}" == "1" ]]; then
        link_nginx_binary
    else
        log_info "Skip /usr/bin/nginx relink (set --link-bin to enable)."
    fi

    if [[ "${ACTIVATE_SERVICE}" == "1" ]]; then
        start_or_reload_nginx "${NGINX_PREFIX}"
    else
        log_warn "Promotion completed without service activation. Use --activate to auto start/reload."
    fi

    PROMOTE_IN_PROGRESS=0
    log_info "Promotion finished. Backups retained in ${BACKUP_ROOT}"
}

print_summary() {
    phase "Summary"
    local summary_prefix="${CANDIDATE_PREFIX}"
    if [[ "${INSTALL_MODE}" == "promote" ]]; then
        summary_prefix="${NGINX_PREFIX}"
    fi
    echo "Install mode       : ${INSTALL_MODE}"
    echo "Target prefix      : ${NGINX_PREFIX}"
    echo "Candidate prefix   : ${CANDIDATE_PREFIX}"
    echo "Config file        : ${summary_prefix}/conf/nginx.conf"
    echo "PID file           : ${PID_FILE}"
    echo "Log dir            : ${LOG_DIR}"
    echo "WAF source mode    : ${WAF_SOURCE_MODE}"
    echo "WAF source path    : ${WAF_EFFECTIVE_SOURCE_DIR:-<none>}"
    if [[ "${WAF_SOURCE_MODE}" == "online" ]]; then
        echo "WAF repo           : ${WAF_REPO_URL}"
        echo "WAF repo ref       : ${WAF_REPO_REF:-<default branch>}"
        echo "WAF repo subdir    : ${WAF_REPO_SUBDIR}"
    fi
    echo "WAF dir            : ${summary_prefix}/conf/waf"
    echo "Service name       : ${SERVICE_NAME}"
    echo "Backup root        : ${BACKUP_ROOT}"
    echo "OpenResty prefix   : ${OPENRESTY_PREFIX_DETECTED:-<not detected>}"
    echo ""
    echo "Modules            :"
    echo "  - ngx_devel_kit"
    echo "  - lua-nginx-module"
    echo "  - stream-lua-nginx-module"
    echo "  - ngx_http_geoip2_module"
    echo "  - ngx_http_substitutions_filter_module"
    echo ""
    local cand_bin="${CANDIDATE_PREFIX}/sbin/nginx"
    if [[ -x "${cand_bin}" ]]; then
        "${cand_bin}" -V 2>&1 | sed 's/^/  /'
    fi
    if [[ "${INSTALL_MODE}" == "stage" ]]; then
        echo ""
        echo "Next step:"
        echo "  Re-run with --promote (and optionally --activate) after candidate verification."
    fi
}

print_dry_run_plan() {
    phase "Dry-run execution plan"
    echo "Mode              : ${INSTALL_MODE}"
    echo "Dry run           : ${DRY_RUN}"
    echo "Target prefix     : ${NGINX_PREFIX}"
    echo "Service name      : ${SERVICE_NAME}"
    echo "Backup root       : ${BACKUP_ROOT}"
    echo "OpenResty prefix  : ${OPENRESTY_PREFIX_DETECTED:-<not detected>}"
    echo "WAF source mode   : ${WAF_SOURCE_MODE}"
    if [[ "${WAF_SOURCE_MODE}" == "local" ]]; then
        echo "WAF source dir    : ${WAF_EFFECTIVE_SOURCE_DIR:-${WAF_SOURCE_DIR}}"
    else
        echo "WAF repo          : ${WAF_REPO_URL}"
        echo "WAF repo ref      : ${WAF_REPO_REF:-<default branch>}"
        echo "WAF repo subdir   : ${WAF_REPO_SUBDIR}"
    fi
    echo "Auto latest       : ${AUTO_LATEST}"
    echo "Activate service  : ${ACTIVATE_SERVICE}"
    echo "Link /usr/bin/nginx: ${LINK_NGINX_BIN}"
    echo ""
    echo "Planned steps:"
    echo "  1) Detect OS and install build dependencies"
    echo "  2) Resolve dependency versions (Nginx/OpenSSL/PCRE2/jemalloc/libmaxminddb)"
    echo "  3) Download sources and modules"
    if [[ "${WAF_SOURCE_MODE}" == "online" ]]; then
        echo "  4) Fetch online WAF repo (${WAF_REPO_URL}) and locate ${WAF_REPO_SUBDIR}/"
        echo "  5) Build candidate nginx under workdir (DESTDIR install)"
        echo "  6) Patch candidate nginx.conf and integrate waf/"
        echo "  7) Validate candidate with nginx -t"
    else
        echo "  4) Build candidate nginx under workdir (DESTDIR install)"
        echo "  5) Patch candidate nginx.conf and integrate waf/"
        echo "  6) Validate candidate with nginx -t"
    fi
    if [[ "${INSTALL_MODE}" == "promote" ]]; then
        if [[ "${WAF_SOURCE_MODE}" == "online" ]]; then
            echo "  8) Backup current live prefix + systemd unit"
            echo "  9) Promote candidate to ${NGINX_PREFIX}"
            echo "  10) Validate promoted config and optionally activate service"
            echo "  11) Roll back automatically on promotion failure"
        else
            echo "  7) Backup current live prefix + systemd unit"
            echo "  8) Promote candidate to ${NGINX_PREFIX}"
            echo "  9) Validate promoted config and optionally activate service"
            echo "  10) Roll back automatically on promotion failure"
        fi
    else
        if [[ "${WAF_SOURCE_MODE}" == "online" ]]; then
            echo "  8) Stop at staged candidate (live service untouched)"
        else
            echo "  7) Stop at staged candidate (live service untouched)"
        fi
    fi
}

main() {
    parse_args "$@"
    safety_guard
    detect_os
    resolve_versions
    resolve_waf_source
    resolve_brand
    if [[ "${DRY_RUN}" == "1" ]]; then
        print_dry_run_plan
        return 0
    fi
    ensure_root
    install_build_deps
    prepare_workspace
    create_nginx_user_group
    download_sources
    download_modules
    prepare_waf_source
    build_jemalloc
    build_libmaxminddb
    build_luajit
    build_lua_cjson
    install_lua_resty_runtime
    refresh_ldconfig
    apply_brand_mask
    build_and_install_nginx
    install_candidate_lua_runtime "${CANDIDATE_PREFIX}"
    configure_nginx_conf "${CANDIDATE_PREFIX}"
    integrate_waf "${CANDIDATE_PREFIX}"
    validate_candidate
    if [[ "${INSTALL_MODE}" == "promote" ]]; then
        promote_candidate
    else
        log_info "Stage mode finished. Live prefix/service untouched."
    fi
    print_summary
}

main "$@"

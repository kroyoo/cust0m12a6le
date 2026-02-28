#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# Nginx source installer (vanilla Nginx + GeoIP2 + substitutions + Lua WAF).
# - Targets latest stable components by default (auto-discovery with fallback).
# - Integrates local or online waf/ directory into nginx.conf.
# - Uses single release-layout workflow: build -> publish release -> switch current symlink.
# - Runtime config is persistent under RUNTIME_PREFIX (separate from release binaries).
# - Keeps runtime path simple: PID at /run/nginx.pid
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
WAF_POLICY="${WAF_POLICY:-optional}"          # required | optional | disabled
SYNC_WAF="${SYNC_WAF:-0}"                     # 1/0, sync runtime conf/waf during install flow
PROXY_URL="${PROXY_URL:-}"                    # e.g. http://127.0.0.1:7890
GITHUB_MIRROR_GATEWAY="${GITHUB_MIRROR_GATEWAY:-}"   # e.g. https://ghproxy.com
GIT_MIRROR_GATEWAY="${GIT_MIRROR_GATEWAY:-}"         # clone_repo_once gateway (supports %URL%)
DOWNLOAD_MIRROR_GATEWAY="${DOWNLOAD_MIRROR_GATEWAY:-}" # download_file gateway (supports %URL%)
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/nginx-source-installer}"
SERVICE_NAME="${SERVICE_NAME:-nginx}"
ACTIVATE_SERVICE="${ACTIVATE_SERVICE:-0}"     # 1/0, default off for manual verification before restart
LINK_NGINX_BIN="${LINK_NGINX_BIN:-0}"         # 1/0, optionally link /usr/bin/nginx
DRY_RUN="${DRY_RUN:-0}"                       # 1/0, print plan and exit
UPDATE_WAF_ONLY="${UPDATE_WAF_ONLY:-0}"       # 1/0, update runtime WAF only (skip compile/build)
REWRITE_UNIT="${REWRITE_UNIT:-1}"             # 1/0, rewrite systemd unit to current/runtime layout
RELEASES_DIR="${RELEASES_DIR:-}"              # default resolved after args
CURRENT_LINK="${CURRENT_LINK:-}"              # default resolved after args
RUNTIME_PREFIX="${RUNTIME_PREFIX:-}"          # default resolved after args
RELEASE_KEEP="${RELEASE_KEEP:-5}"             # keep newest N releases
QUIET_CLEANUP="${QUIET_CLEANUP:-0}"           # suppress cleanup summary (used by --help)

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
UPGRADE_IN_PROGRESS=0
SERVICE_UNIT_FILE=""
SERVICE_UNIT_BACKUP=""
HAD_SERVICE_UNIT=0
SERVICE_UNIT_CHANGED=0
CURRENT_LINK_PREV_TARGET=""
CURRENT_LINK_SWITCHED=0
RELEASE_CANDIDATE_DIR=""
WAF_EFFECTIVE_SOURCE_DIR=""
WAF_REPO_CLONE_DIR=""
CURRENT_PHASE_NAME=""
CURRENT_PHASE_START_TS=0

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
log_kv() {
    local key="$1"
    shift
    log_info "$(printf '%-18s %s' "${key}:" "$*")"
}

finish_active_phase() {
    local now_ts elapsed_seconds
    [[ -n "${CURRENT_PHASE_NAME}" ]] || return 0

    now_ts="$(date +%s)"
    if [[ "${CURRENT_PHASE_START_TS}" =~ ^[0-9]+$ ]] && (( CURRENT_PHASE_START_TS > 0 )); then
        elapsed_seconds=$((now_ts - CURRENT_PHASE_START_TS))
        log_info "Phase completed: ${CURRENT_PHASE_NAME} (${elapsed_seconds}s)"
    else
        log_info "Phase completed: ${CURRENT_PHASE_NAME}"
    fi

    CURRENT_PHASE_NAME=""
    CURRENT_PHASE_START_TS=0
}

phase() {
    finish_active_phase
    CURRENT_PHASE_NAME="$*"
    CURRENT_PHASE_START_TS="$(date +%s)"
    printf '\n%s %s[PHASE]%s %s\n' "$(ts)" "${C_INFO}" "${C_RESET}" "$*"
}

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [options]

Options:
  -y, --yes                      Non-interactive mode (skip prompts)
  --dry-run                      Print execution plan and detected paths, then exit
  --update-waf-only              Update runtime WAF only (skip build/compile flow)
  --activate                     Start/reload ${SERVICE_NAME} after successful install (default: off)
  --link-bin                     Link /usr/bin/nginx to active nginx binary path
  --rewrite-unit                 Rewrite systemd unit to current/runtime layout (default: ${REWRITE_UNIT})
  --no-rewrite-unit              Do not rewrite systemd unit
  --backup-root PATH             Backup path for live prefix/systemd backups (default: ${BACKUP_ROOT})
  --service-name NAME            systemd service name to manage (default: ${SERVICE_NAME})
  --prefix PATH                  Nginx install prefix (default: ${NGINX_PREFIX})
  --runtime-prefix PATH          Runtime prefix for persistent config/state (default: auto)
  --releases-dir PATH            Release directory (default: <prefix>/releases)
  --current-link PATH            Current release symlink path (default: <prefix>/current)
  --release-keep N               Keep newest N releases (default: ${RELEASE_KEEP})
  --brand NAME                   Set custom Server brand string
  --no-brand                     Keep upstream nginx branding
  --auto-latest 0|1              Discover latest stable versions at runtime (default: ${AUTO_LATEST})
  --no-jemalloc                  Disable jemalloc linking/build
  --waf-source local|online      WAF source mode (default: ${WAF_SOURCE_MODE})
  --waf-policy required|optional|disabled
                                 required: WAF source missing/fetch error stops execution
                                 optional: WAF issues are skipped with warning
                                 disabled: do not resolve/integrate/sync WAF
  --sync-waf                     Sync runtime conf/waf from prepared source
  --no-sync-waf                  Do not sync runtime conf/waf
  --online-waf                   Shortcut for --waf-source online
  --waf-source-dir PATH          Local waf directory (default: auto-detect ../waf then ./waf)
  --waf-repo URL                 Online WAF git repo (default: ${WAF_REPO_URL})
  --waf-ref REF                  Online WAF git branch/tag/commit (default: repo default branch)
  --waf-subdir PATH              WAF directory inside repo (default: ${WAF_REPO_SUBDIR})
  --proxy-url URL                Global proxy URL for git/curl/wget (e.g. http://127.0.0.1:7890)
  --github-mirror-gateway URL    Set both git/download mirror gateways for GitHub URLs
                                 gateway supports prefix form or %URL% template
  --git-mirror-gateway URL       Git clone mirror gateway for GitHub repos
  --download-mirror-gateway URL  File download mirror gateway for GitHub URLs
  --workdir PATH                 Reuse a specific working directory
  --nginx-version VER            Force Nginx version
  --openssl-version VER          Force OpenSSL version
  --pcre2-version VER            Force PCRE2 version
  --jemalloc-version VER         Force jemalloc version
  --libmaxminddb-version VER     Force libmaxminddb version
  -h, --help                     Show this help

Environment overrides:
  AUTO_LATEST, AUTO_CLEANUP, ASSUME_YES, ENABLE_JEMALLOC, JOBS
  ACTIVATE_SERVICE, LINK_NGINX_BIN, DRY_RUN, UPDATE_WAF_ONLY, BACKUP_ROOT, SERVICE_NAME
  REWRITE_UNIT, RELEASES_DIR, CURRENT_LINK, RUNTIME_PREFIX, RELEASE_KEEP
  PROXY_URL, GITHUB_MIRROR_GATEWAY, GIT_MIRROR_GATEWAY, DOWNLOAD_MIRROR_GATEWAY
  NGINX_PREFIX, NGINX_USER, NGINX_GROUP, LOG_DIR, PID_FILE, LUAJIT_PREFIX, LUA_SHARE_DIR, LUA_CPATH_DIR
  WAF_SOURCE_MODE, WAF_POLICY, SYNC_WAF, WAF_SOURCE_DIR, WAF_REPO_URL, WAF_REPO_REF, WAF_REPO_SUBDIR
  BRAND_MODE (ask|set|keep), BRAND_NAME
  NGINX_VERSION, OPENSSL_VERSION, PCRE2_VERSION, JEMALLOC_VERSION, LIBMAXMINDDB_VERSION
  LUAJIT_REF, NDK_REF, LUA_NGINX_REF, STREAM_LUA_REF, GEOIP2_REF, SUBS_REF, RESTY_CORE_REF, RESTY_LRUCACHE_REF, RESTY_HTTP_REF, LUA_CJSON_REF
  RESTY_CORE_REPO, RESTY_LRUCACHE_REPO, RESTY_HTTP_REPO, LUA_CJSON_REPO
EOF
}

# ----- Normalization and validation helpers -----------------------------------
normalize_bool() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|on|ON) printf '1\n' ;;
        0|false|FALSE|no|NO|off|OFF) printf '0\n' ;;
        *) die "Invalid boolean value: $1 (expected 0/1/true/false)" ;;
    esac
}

normalize_waf_source_mode() {
    case "${1:-}" in
        local|online) printf '%s\n' "$1" ;;
        *) die "Invalid WAF source mode: $1 (expected local|online)" ;;
    esac
}

normalize_waf_policy() {
    case "${1:-}" in
        required|optional|disabled) printf '%s\n' "$1" ;;
        *) die "Invalid WAF policy: $1 (expected required|optional|disabled)" ;;
    esac
}

normalize_positive_int() {
    case "${1:-}" in
        ''|*[!0-9]*)
            die "Invalid positive integer: ${1:-<empty>}"
            ;;
        0)
            die "Invalid positive integer: 0"
            ;;
        *)
            printf '%s\n' "$1"
            ;;
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

normalize_proxy_url() {
    local value="${1:-}"
    [[ -n "${value}" ]] || { printf '\n'; return 0; }
    if [[ ! "${value}" =~ ^[A-Za-z][A-Za-z0-9+.-]*:// ]]; then
        die "Invalid proxy URL: ${value} (expected scheme://host:port)"
    fi
    printf '%s\n' "${value}"
}

normalize_gateway_url() {
    local name="$1"
    local value="${2:-}"

    [[ -n "${value}" ]] || { printf '\n'; return 0; }
    if [[ ! "${value}" =~ ^https?:// ]]; then
        die "${name} must start with http:// or https://"
    fi
    if [[ "${value}" == *$'\n'* ]]; then
        die "${name} must be a single-line value"
    fi
    if [[ "${value}" != *"%URL%"* ]]; then
        value="${value%/}"
    fi
    printf '%s\n' "${value}"
}

require_option_value() {
    local opt="$1"
    local argc="$2"
    local msg="${3:-requires a value}"
    (( argc >= 2 )) || die "${opt} ${msg}"
}

pin_version_value() {
    local var_name="$1"
    local value="$2"
    printf -v "${var_name}" '%s' "${value}"
    AUTO_LATEST=0
}

normalize_identifier() {
    local name="$1"
    local value="$2"
    local pattern='^[A-Za-z0-9_.@-]+$'

    [[ -n "${value}" ]] || die "${name} cannot be empty"
    if [[ ! "${value}" =~ ${pattern} ]]; then
        die "Invalid ${name}: ${value} (allowed: [A-Za-z0-9_.@-])"
    fi
    printf '%s\n' "${value}"
}

normalize_abs_path() {
    local name="$1"
    local value="$2"
    local allow_root="${3:-0}"

    [[ -n "${value}" ]] || die "${name} cannot be empty"
    [[ "${value}" == /* ]] || die "${name} must be an absolute path: ${value}"

    while [[ "${value}" != "/" && "${value}" == */ ]]; do
        value="${value%/}"
    done

    if [[ "${allow_root}" != "1" && "${value}" == "/" ]]; then
        die "${name} cannot be /"
    fi
    printf '%s\n' "${value}"
}

normalize_abs_file_path() {
    local name="$1"
    local value="$2"

    value="$(normalize_abs_path "${name}" "${value}")"
    [[ "${value}" != "/" ]] || die "${name} cannot be /"
    [[ "${value}" != */ ]] || die "${name} cannot end with /: ${value}"
    printf '%s\n' "${value}"
}

is_same_or_descendant_path() {
    local child="$1"
    local parent="$2"

    child="${child%/}"
    parent="${parent%/}"
    if [[ "${parent}" == "/" ]]; then
        return 0
    fi
    [[ "${child}" == "${parent}" || "${child}" == "${parent}/"* ]]
}

validate_layout_path_relationships() {
    if is_same_or_descendant_path "${RUNTIME_PREFIX}" "${RELEASES_DIR}"; then
        die "RUNTIME_PREFIX (${RUNTIME_PREFIX}) cannot be inside RELEASES_DIR (${RELEASES_DIR})"
    fi
    if is_same_or_descendant_path "${RELEASES_DIR}" "${RUNTIME_PREFIX}"; then
        die "RELEASES_DIR (${RELEASES_DIR}) cannot be inside RUNTIME_PREFIX (${RUNTIME_PREFIX})"
    fi
    if is_same_or_descendant_path "${CURRENT_LINK}" "${RELEASES_DIR}"; then
        die "CURRENT_LINK (${CURRENT_LINK}) cannot be inside RELEASES_DIR (${RELEASES_DIR})"
    fi
    if is_same_or_descendant_path "${CURRENT_LINK}" "${RUNTIME_PREFIX}"; then
        die "CURRENT_LINK (${CURRENT_LINK}) cannot be inside RUNTIME_PREFIX (${RUNTIME_PREFIX})"
    fi
}

resolve_layout_defaults() {
    if [[ -z "${RUNTIME_PREFIX}" ]]; then
        if [[ "${NGINX_PREFIX}" == "/usr/local/nginx" ]]; then
            RUNTIME_PREFIX="/usr/local/nginx-data"
        else
            RUNTIME_PREFIX="${NGINX_PREFIX}-data"
        fi
    fi

    if [[ -z "${RELEASES_DIR}" ]]; then
        RELEASES_DIR="${NGINX_PREFIX}/releases"
    fi

    if [[ -z "${CURRENT_LINK}" ]]; then
        CURRENT_LINK="${NGINX_PREFIX}/current"
    fi
}

# ----- CLI parsing -------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--yes)
                ASSUME_YES=1
                ;;
            --dry-run)
                DRY_RUN=1
                ;;
            --update-waf-only)
                UPDATE_WAF_ONLY=1
                ;;
            --activate)
                ACTIVATE_SERVICE=1
                ;;
            --link-bin)
                LINK_NGINX_BIN=1
                ;;
            --rewrite-unit)
                REWRITE_UNIT=1
                ;;
            --no-rewrite-unit)
                REWRITE_UNIT=0
                ;;
            --backup-root)
                require_option_value "$1" "$#"
                BACKUP_ROOT="$2"
                shift
                ;;
            --service-name)
                require_option_value "$1" "$#"
                SERVICE_NAME="$2"
                shift
                ;;
            --prefix)
                require_option_value "$1" "$#"
                NGINX_PREFIX="$2"
                shift
                ;;
            --runtime-prefix)
                require_option_value "$1" "$#"
                RUNTIME_PREFIX="$2"
                shift
                ;;
            --releases-dir)
                require_option_value "$1" "$#"
                RELEASES_DIR="$2"
                shift
                ;;
            --current-link)
                require_option_value "$1" "$#"
                CURRENT_LINK="$2"
                shift
                ;;
            --release-keep)
                require_option_value "$1" "$#"
                RELEASE_KEEP="$2"
                shift
                ;;
            --brand)
                require_option_value "$1" "$#"
                BRAND_MODE="set"
                BRAND_NAME="$2"
                shift
                ;;
            --no-brand)
                BRAND_MODE="keep"
                ;;
            --auto-latest)
                require_option_value "$1" "$#" "requires 0 or 1"
                AUTO_LATEST="$2"
                shift
                ;;
            --no-jemalloc)
                ENABLE_JEMALLOC=0
                ;;
            --waf-source)
                require_option_value "$1" "$#" "requires local|online"
                WAF_SOURCE_MODE="$2"
                shift
                ;;
            --waf-policy)
                require_option_value "$1" "$#" "requires required|optional|disabled"
                WAF_POLICY="$2"
                shift
                ;;
            --sync-waf)
                SYNC_WAF=1
                ;;
            --no-sync-waf)
                SYNC_WAF=0
                ;;
            --online-waf)
                WAF_SOURCE_MODE="online"
                ;;
            --waf-source-dir)
                require_option_value "$1" "$#"
                WAF_SOURCE_DIR="$2"
                shift
                ;;
            --waf-repo)
                require_option_value "$1" "$#"
                WAF_REPO_URL="$2"
                shift
                ;;
            --waf-ref)
                require_option_value "$1" "$#"
                WAF_REPO_REF="$2"
                shift
                ;;
            --waf-subdir)
                require_option_value "$1" "$#"
                WAF_REPO_SUBDIR="$2"
                shift
                ;;
            --proxy-url)
                require_option_value "$1" "$#"
                PROXY_URL="$2"
                shift
                ;;
            --github-mirror-gateway)
                require_option_value "$1" "$#"
                GITHUB_MIRROR_GATEWAY="$2"
                shift
                ;;
            --git-mirror-gateway)
                require_option_value "$1" "$#"
                GIT_MIRROR_GATEWAY="$2"
                shift
                ;;
            --download-mirror-gateway)
                require_option_value "$1" "$#"
                DOWNLOAD_MIRROR_GATEWAY="$2"
                shift
                ;;
            --workdir)
                require_option_value "$1" "$#"
                WORKDIR="$2"
                shift
                ;;
            --nginx-version)
                require_option_value "$1" "$#"
                pin_version_value "NGINX_VERSION" "$2"
                shift
                ;;
            --openssl-version)
                require_option_value "$1" "$#"
                pin_version_value "OPENSSL_VERSION" "$2"
                shift
                ;;
            --pcre2-version)
                require_option_value "$1" "$#"
                pin_version_value "PCRE2_VERSION" "$2"
                shift
                ;;
            --jemalloc-version)
                require_option_value "$1" "$#"
                pin_version_value "JEMALLOC_VERSION" "$2"
                shift
                ;;
            --libmaxminddb-version)
                require_option_value "$1" "$#"
                pin_version_value "LIBMAXMINDDB_VERSION" "$2"
                shift
                ;;
            -h|--help)
                QUIET_CLEANUP=1
                usage
                exit 0
                ;;
            *)
                die "Unknown option: $1"
                ;;
        esac
        shift
    done
}

resolve_network_options() {
    PROXY_URL="$(normalize_proxy_url "${PROXY_URL}")"
    GITHUB_MIRROR_GATEWAY="$(normalize_gateway_url "GITHUB_MIRROR_GATEWAY" "${GITHUB_MIRROR_GATEWAY}")"
    GIT_MIRROR_GATEWAY="$(normalize_gateway_url "GIT_MIRROR_GATEWAY" "${GIT_MIRROR_GATEWAY}")"
    DOWNLOAD_MIRROR_GATEWAY="$(normalize_gateway_url "DOWNLOAD_MIRROR_GATEWAY" "${DOWNLOAD_MIRROR_GATEWAY}")"

    if [[ -n "${GITHUB_MIRROR_GATEWAY}" ]]; then
        if [[ -z "${GIT_MIRROR_GATEWAY}" ]]; then
            GIT_MIRROR_GATEWAY="${GITHUB_MIRROR_GATEWAY}"
        fi
        if [[ -z "${DOWNLOAD_MIRROR_GATEWAY}" ]]; then
            DOWNLOAD_MIRROR_GATEWAY="${GITHUB_MIRROR_GATEWAY}"
        fi
    fi
}

apply_network_proxy() {
    [[ -n "${PROXY_URL}" ]] || return 0
    export http_proxy="${PROXY_URL}"
    export https_proxy="${PROXY_URL}"
    export all_proxy="${PROXY_URL}"
    export HTTP_PROXY="${PROXY_URL}"
    export HTTPS_PROXY="${PROXY_URL}"
    export ALL_PROXY="${PROXY_URL}"
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

# ----- Error handling and lifecycle -------------------------------------------
on_error() {
    local line_no="$1"
    local failed_command="$2"
    log_error "Failed at line ${line_no}: ${failed_command}"
    if [[ -n "${SERVICE_NAME:-}" ]]; then
        log_error "Context: SERVICE_NAME=${SERVICE_NAME} NGINX_PREFIX=${NGINX_PREFIX:-unknown} RUNTIME_PREFIX=${RUNTIME_PREFIX:-unknown}"
        if command_exists systemctl; then
            local svc_state
            svc_state="$(systemctl is-active "${SERVICE_NAME}" 2>/dev/null || true)"
            log_error "systemd: ${SERVICE_NAME}.service state=${svc_state:-unknown}"
        fi
    fi
}

rollback_if_needed() {
    if [[ "${UPGRADE_IN_PROGRESS}" == "1" ]]; then
        log_warn "Upgrade failed. Attempting rollback..."

        if [[ "${SERVICE_UNIT_CHANGED}" == "1" ]]; then
            if [[ "${HAD_SERVICE_UNIT}" == "1" && -n "${SERVICE_UNIT_BACKUP}" && -f "${SERVICE_UNIT_BACKUP}" ]]; then
                cp -a "${SERVICE_UNIT_BACKUP}" "${SERVICE_UNIT_FILE}" || true
                log_warn "Restored systemd unit from backup: ${SERVICE_UNIT_BACKUP}"
            elif [[ "${HAD_SERVICE_UNIT}" == "0" && -n "${SERVICE_UNIT_FILE}" && -f "${SERVICE_UNIT_FILE}" ]]; then
                rm -f "${SERVICE_UNIT_FILE}" || true
                log_warn "Removed newly created systemd unit: ${SERVICE_UNIT_FILE}"
            fi
        fi

        if [[ "${CURRENT_LINK_SWITCHED}" == "1" ]]; then
            if [[ -n "${CURRENT_LINK_PREV_TARGET}" && -d "${CURRENT_LINK_PREV_TARGET}" ]]; then
                ln -sfn "${CURRENT_LINK_PREV_TARGET}" "${CURRENT_LINK}" || true
                log_warn "Restored current symlink to previous release: ${CURRENT_LINK_PREV_TARGET}"
            else
                rm -f "${CURRENT_LINK}" || true
                log_warn "Removed current symlink due to missing previous release target."
            fi
        fi

        if command_exists systemctl; then
            systemctl daemon-reload || true
        fi

        UPGRADE_IN_PROGRESS=0
    fi
}

cleanup() {
    local exit_code=$?
    set +e

    if [[ "${QUIET_CLEANUP}" == "1" ]]; then
        exit "${exit_code}"
    fi

    local cleanup_mode="${AUTO_CLEANUP}"
    if [[ "${DRY_RUN}" == "1" ]]; then
        cleanup_mode="0"
    fi
    if [[ "${exit_code}" -ne 0 ]]; then
        rollback_if_needed
    fi
    if [[ "${cleanup_mode}" == "1" && "${WORKDIR_CREATED}" == "1" && -n "${WORKDIR}" && -d "${WORKDIR}" ]]; then
        rm -rf "${WORKDIR}"
        log_info "Cleaned workdir: ${WORKDIR}"
    elif [[ -n "${WORKDIR}" && -d "${WORKDIR}" ]]; then
        log_warn "Keeping workdir: ${WORKDIR}"
    fi

    finish_active_phase
    local elapsed_seconds=$(( "$(date +%s)" - START_TS ))
    log_info "Total elapsed: ${elapsed_seconds}s"
    exit "${exit_code}"
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

ensure_root() {
    [[ "$(id -u)" -eq 0 ]] || die "Run as root."
}

safety_guard() {
    case "${NGINX_PREFIX}" in
        ''|/)
            die "Invalid NGINX_PREFIX: ${NGINX_PREFIX:-<empty>}"
            ;;
    esac
}

# ----- Environment and dependency discovery -----------------------------------
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

is_github_http_url() {
    local url="${1:-}"
    [[ "${url}" =~ ^https?://([[:alnum:]-]+\.)?github\.com/ ]]
}

build_gateway_url() {
    local raw_url="$1"
    local gateway="$2"
    local resolved

    if [[ -z "${gateway}" ]]; then
        printf '%s\n' "${raw_url}"
        return 0
    fi

    if [[ "${gateway}" == *"%URL%"* ]]; then
        resolved="${gateway//%URL%/${raw_url}}"
        printf '%s\n' "${resolved}"
        return 0
    fi

    printf '%s/%s\n' "${gateway}" "${raw_url}"
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
    local gateway="${3:-${DOWNLOAD_MIRROR_GATEWAY}}"
    local current_url
    local attempt
    local -a candidates=("${url}")

    if is_github_http_url "${url}" && [[ -n "${gateway}" ]]; then
        local mirrored_url
        mirrored_url="$(build_gateway_url "${url}" "${gateway}")"
        if [[ -n "${mirrored_url}" && "${mirrored_url}" != "${url}" ]]; then
            candidates=("${mirrored_url}" "${url}")
        fi
    fi

    for current_url in "${candidates[@]}"; do
        rm -f "${out}"
        for attempt in 1 2 3; do
            if command_exists curl; then
                if curl -fL --retry 5 --retry-delay 2 --connect-timeout 15 -o "${out}" "${current_url}"; then
                    return 0
                fi
            else
                if wget -O "${out}" "${current_url}"; then
                    return 0
                fi
            fi
            sleep $(( attempt * 2 ))
        done
        log_warn "Download failed via URL candidate: ${current_url}"
    done

    die "Failed to download: ${url}"
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

# ----- Version resolution ------------------------------------------------------
discover_nginx_stable() {
    local listing versions candidate_version minor
    listing="$(fetch_url "https://nginx.org/download/")" || return 1
    versions="$(printf '%s' "${listing}" \
        | grep -Eo 'nginx-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz' \
        | sed -E 's/^nginx-([0-9.]+)\.tar\.gz$/\1/' \
        | sort -Vu)"
    [[ -n "${versions}" ]] || return 1

    while IFS= read -r candidate_version; do
        minor="$(printf '%s' "${candidate_version}" | cut -d. -f2)"
        if [[ "${minor}" =~ ^[0-9]+$ ]] && (( minor % 2 == 0 )); then
            printf '%s\n' "${candidate_version}"
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

    UPDATE_WAF_ONLY="$(normalize_bool "${UPDATE_WAF_ONLY}")"
    if [[ "${UPDATE_WAF_ONLY}" == "1" ]]; then
        AUTO_LATEST=0
    fi

    AUTO_LATEST="$(normalize_bool "${AUTO_LATEST}")"
    ENABLE_JEMALLOC="$(normalize_bool "${ENABLE_JEMALLOC}")"
    ASSUME_YES="$(normalize_bool "${ASSUME_YES}")"
    AUTO_CLEANUP="$(normalize_bool "${AUTO_CLEANUP}")"
    ACTIVATE_SERVICE="$(normalize_bool "${ACTIVATE_SERVICE}")"
    LINK_NGINX_BIN="$(normalize_bool "${LINK_NGINX_BIN}")"
    DRY_RUN="$(normalize_bool "${DRY_RUN}")"
    REWRITE_UNIT="$(normalize_bool "${REWRITE_UNIT}")"
    SYNC_WAF="$(normalize_bool "${SYNC_WAF}")"
    WAF_POLICY="$(normalize_waf_policy "${WAF_POLICY}")"
    RELEASE_KEEP="$(normalize_positive_int "${RELEASE_KEEP}")"
    resolve_layout_defaults

    SERVICE_NAME="$(normalize_identifier "SERVICE_NAME" "${SERVICE_NAME}")"
    NGINX_USER="$(normalize_identifier "NGINX_USER" "${NGINX_USER}")"
    NGINX_GROUP="$(normalize_identifier "NGINX_GROUP" "${NGINX_GROUP}")"

    NGINX_PREFIX="$(normalize_abs_path "NGINX_PREFIX" "${NGINX_PREFIX}")"
    RUNTIME_PREFIX="$(normalize_abs_path "RUNTIME_PREFIX" "${RUNTIME_PREFIX}")"
    RELEASES_DIR="$(normalize_abs_path "RELEASES_DIR" "${RELEASES_DIR}")"
    CURRENT_LINK="$(normalize_abs_path "CURRENT_LINK" "${CURRENT_LINK}")"
    BACKUP_ROOT="$(normalize_abs_path "BACKUP_ROOT" "${BACKUP_ROOT}")"
    LOG_DIR="$(normalize_abs_path "LOG_DIR" "${LOG_DIR}")"
    PID_FILE="$(normalize_abs_file_path "PID_FILE" "${PID_FILE}")"
    if [[ -n "${WORKDIR}" ]]; then
        WORKDIR="$(normalize_abs_path "WORKDIR" "${WORKDIR}")"
    fi
    if [[ -n "${WAF_SOURCE_DIR}" && "${WAF_SOURCE_DIR}" == /* ]]; then
        WAF_SOURCE_DIR="$(normalize_abs_path "WAF_SOURCE_DIR" "${WAF_SOURCE_DIR}")"
    fi
    validate_layout_path_relationships

    log_kv "Install profile" "release-layout"
    log_kv "Dry run" "${DRY_RUN}"
    log_kv "Update waf only" "${UPDATE_WAF_ONLY}"
    log_kv "WAF policy" "${WAF_POLICY}"
    log_kv "Sync WAF" "${SYNC_WAF}"
    log_kv "Proxy URL" "${PROXY_URL:-<none>}"
    log_kv "Git mirror gateway" "${GIT_MIRROR_GATEWAY:-<none>}"
    log_kv "Download gateway" "${DOWNLOAD_MIRROR_GATEWAY:-<none>}"
    log_kv "Runtime prefix" "${RUNTIME_PREFIX}"
    log_kv "Releases dir" "${RELEASES_DIR}"
    log_kv "Current link" "${CURRENT_LINK}"
    log_kv "Release keep" "${RELEASE_KEEP}"

    if [[ "${AUTO_LATEST}" == "1" ]]; then
        local discovered_version
        if discovered_version="$(discover_nginx_stable)"; then NGINX_VERSION="${discovered_version}"; else log_warn "Failed to discover nginx stable; using ${NGINX_VERSION}"; fi
        if discovered_version="$(discover_semver_from_github_latest_release "openssl/openssl" "openssl-")"; then OPENSSL_VERSION="${discovered_version}"; else log_warn "Failed to discover OpenSSL; using ${OPENSSL_VERSION}"; fi
        if discovered_version="$(discover_semver_from_github_latest_release "PCRE2Project/pcre2" "pcre2-")"; then PCRE2_VERSION="${discovered_version}"; else log_warn "Failed to discover PCRE2; using ${PCRE2_VERSION}"; fi
        if discovered_version="$(discover_semver_from_github_latest_release "jemalloc/jemalloc" "")"; then JEMALLOC_VERSION="${discovered_version}"; else log_warn "Failed to discover jemalloc; using ${JEMALLOC_VERSION}"; fi
        if discovered_version="$(discover_semver_from_github_latest_release "maxmind/libmaxminddb" "")"; then LIBMAXMINDDB_VERSION="${discovered_version}"; else log_warn "Failed to discover libmaxminddb; using ${LIBMAXMINDDB_VERSION}"; fi
    fi

    log_kv "Nginx version" "${NGINX_VERSION}"
    log_kv "OpenSSL version" "${OPENSSL_VERSION}"
    log_kv "PCRE2 version" "${PCRE2_VERSION}"
    log_kv "jemalloc version" "${JEMALLOC_VERSION}"
    log_kv "libmaxminddb version" "${LIBMAXMINDDB_VERSION}"
}

# ----- Runtime option resolution ----------------------------------------------
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

    if [[ "${WAF_POLICY}" == "disabled" ]]; then
        WAF_EFFECTIVE_SOURCE_DIR=""
        log_info "WAF policy disabled: skip source resolution."
        return 0
    fi

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
            log_kv "WAF source mode" "local"
            log_kv "WAF local source" "${WAF_EFFECTIVE_SOURCE_DIR}"
        else
            WAF_EFFECTIVE_SOURCE_DIR=""
            if [[ "${WAF_POLICY}" == "required" ]]; then
                die "WAF source mode is local but directory is missing: ${WAF_SOURCE_DIR}"
            fi
            log_warn "WAF source mode is local but directory is missing: ${WAF_SOURCE_DIR} (WAF integration will be skipped)."
        fi
        return 0
    fi

    WAF_EFFECTIVE_SOURCE_DIR=""
    log_kv "WAF source mode" "online"
    log_kv "WAF repo" "${WAF_REPO_URL}"
    log_kv "WAF repo ref" "${WAF_REPO_REF:-<default branch>}"
    log_kv "WAF repo subdir" "${WAF_REPO_SUBDIR}"
}

# ----- Build workspace and sources --------------------------------------------
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
    if [[ "${WAF_POLICY}" == "disabled" || "${WAF_SOURCE_MODE}" != "online" ]]; then
        return 0
    fi

    phase "Fetch online WAF source"
    WAF_REPO_CLONE_DIR="${SRC_DIR}/waf-source-repo"
    if ! clone_repo_once "${WAF_REPO_URL}" "${WAF_REPO_CLONE_DIR}" "${WAF_REPO_REF}"; then
        WAF_EFFECTIVE_SOURCE_DIR=""
        if [[ "${WAF_POLICY}" == "required" ]]; then
            die "Failed to fetch online WAF repo: ${WAF_REPO_URL}"
        fi
        log_warn "Failed to fetch online WAF repo: ${WAF_REPO_URL} (skip WAF integration)"
        return 0
    fi

    WAF_EFFECTIVE_SOURCE_DIR="${WAF_REPO_CLONE_DIR}/${WAF_REPO_SUBDIR}"
    if [[ ! -d "${WAF_EFFECTIVE_SOURCE_DIR}" ]]; then
        WAF_EFFECTIVE_SOURCE_DIR=""
        if [[ "${WAF_POLICY}" == "required" ]]; then
            die "WAF subdir not found: ${WAF_REPO_SUBDIR} (repo=${WAF_REPO_URL}, ref=${WAF_REPO_REF:-default})"
        fi
        log_warn "WAF subdir not found: ${WAF_REPO_SUBDIR} (repo=${WAF_REPO_URL}, ref=${WAF_REPO_REF:-default}); skip WAF integration"
        return 0
    fi

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
    local gateway="${4:-${GIT_MIRROR_GATEWAY}}"
    local attempt
    local current_repo
    local -a repo_candidates=("${repo}")

    if is_github_http_url "${repo}" && [[ -n "${gateway}" ]]; then
        local mirrored_repo
        mirrored_repo="$(build_gateway_url "${repo}" "${gateway}")"
        if [[ -n "${mirrored_repo}" && "${mirrored_repo}" != "${repo}" ]]; then
            repo_candidates=("${mirrored_repo}" "${repo}")
        fi
    fi

    for attempt in 1 2 3; do
        for current_repo in "${repo_candidates[@]}"; do
            rm -rf "${dst}"
            if [[ -n "${ref}" ]]; then
                if git clone --depth 1 --branch "${ref}" "${current_repo}" "${dst}" >/dev/null 2>&1; then
                    return 0
                fi
            fi

            if git clone --depth 1 "${current_repo}" "${dst}" >/dev/null 2>&1; then
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
            log_warn "Clone failed from ${current_repo}, retrying..."
        done
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

# ----- Build Lua and native dependencies --------------------------------------
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

copy_module_lua_lib_if_exists() {
    local module_name="$1"
    local dst_dir="$2"
    local src_dir="${SRC_DIR}/${module_name}/lib"

    [[ -d "${src_dir}" ]] || return 0
    cp -a "${src_dir}/." "${dst_dir}/"
}

install_lua_resty_runtime() {
    phase "Install lua-resty runtime libraries"

    mkdir -p "${LUA_SHARE_DIR}"
    mkdir -p "${LUA_SHARE_DIR}/resty"
    mkdir -p "${LUA_CPATH_DIR}"

    copy_module_lua_lib_if_exists "lua-resty-core" "${LUA_SHARE_DIR}"
    copy_module_lua_lib_if_exists "lua-resty-lrucache" "${LUA_SHARE_DIR}"
    copy_module_lua_lib_if_exists "lua-resty-http" "${LUA_SHARE_DIR}"

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

    copy_module_lua_lib_if_exists "lua-resty-core" "${candidate_lua_dir}"
    copy_module_lua_lib_if_exists "lua-resty-lrucache" "${candidate_lua_dir}"
    copy_module_lua_lib_if_exists "lua-resty-http" "${candidate_lua_dir}"

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

# ----- Nginx source patching and build ----------------------------------------
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

# ----- Config editing and validation ------------------------------------------
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

    local awk_exit_code=$?
    rm -f "${tmp}"
    if [[ "${awk_exit_code}" -eq 42 ]]; then
        return 1
    fi
    return "${awk_exit_code}"
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

lua_runtime_path_for_prefix() {
    local prefix="$1"
    printf '%s\n' "${LUA_SHARE_DIR}/?.lua;${LUA_SHARE_DIR}/?/init.lua;${prefix}/conf/lua/?.lua;${prefix}/conf/lua/?/init.lua;${prefix}/conf/waf/?.lua;${prefix}/conf/waf/?/init.lua;;"
}

lua_runtime_cpath_for_prefix() {
    local prefix="$1"
    printf '%s\n' "${LUA_CPATH_DIR}/?.so;${LUA_CPATH_DIR}/?/?.so;${prefix}/conf/lua/?.so;${prefix}/conf/lua/?/?.so;${LUAJIT_PREFIX}/lib/lua/5.1/?.so;${LUAJIT_PREFIX}/lib/lua/5.1/?/?.so;;"
}

lua_package_path_directive() {
    printf 'lua_package_path "$prefix/conf/lua/?.lua;$prefix/conf/lua/?/init.lua;$prefix/conf/waf/?.lua;$prefix/conf/waf/?/init.lua;%s/?.lua;%s/?/init.lua;;";\n' "${LUA_SHARE_DIR}" "${LUA_SHARE_DIR}"
}

lua_package_cpath_directive() {
    printf 'lua_package_cpath "$prefix/conf/lua/?.so;$prefix/conf/lua/?/?.so;%s/lib/lua/5.1/?.so;%s/lib/lua/5.1/?/?.so;%s/?.so;%s/?/?.so;;";\n' "${LUAJIT_PREFIX}" "${LUAJIT_PREFIX}" "${LUA_CPATH_DIR}" "${LUA_CPATH_DIR}"
}

upsert_http_directive() {
    local conf_file="$1"
    local key="$2"
    local directive="$3"

    if ! replace_first_directive "${conf_file}" "${key}" "    ${directive}"; then
        ensure_line_in_http_block "${conf_file}" "${directive}"
    fi
}

rewrite_waf_templates_for_prefix() {
    local waf_dir="$1"
    local conf_prefix="$2"
    local waf_lua_path_line

    waf_lua_path_line="$(lua_package_path_directive)"
    if [[ -f "${waf_dir}/waf.conf" ]]; then
        sed -i "s|/usr/local/nginx/conf|${conf_prefix}|g" "${waf_dir}/waf.conf"
        if ! replace_first_directive "${waf_dir}/waf.conf" "lua_package_path" "${waf_lua_path_line}"; then
            if ! grep -Fq "${waf_lua_path_line}" "${waf_dir}/waf.conf"; then
                sed -i "1i ${waf_lua_path_line}" "${waf_dir}/waf.conf"
            fi
        fi
    fi
    if [[ -f "${waf_dir}/config.lua" ]]; then
        sed -i "s|/usr/local/nginx/conf|${conf_prefix}|g" "${waf_dir}/config.lua"
    fi
}

ensure_runtime_waf_integration() {
    local runtime_conf="${RUNTIME_PREFIX}/conf/nginx.conf"
    local lua_package_path_line lua_package_cpath_line

    [[ -f "${runtime_conf}" ]] || return 1
    lua_package_path_line="$(lua_package_path_directive)"
    lua_package_cpath_line="$(lua_package_cpath_directive)"

    cp -a "${runtime_conf}" "${runtime_conf}.waf-update.bak.$(date +%Y%m%d%H%M%S)"
    upsert_http_directive "${runtime_conf}" "lua_package_path" "${lua_package_path_line}"
    upsert_http_directive "${runtime_conf}" "lua_package_cpath" "${lua_package_cpath_line}"
    sed -i -E 's|^[[:space:]]*include[[:space:]]+conf/waf/waf\.conf;[[:space:]]*$|    include waf/waf.conf;|g' "${runtime_conf}"
    ensure_line_in_http_block "${runtime_conf}" "include waf/waf.conf;"
    return 0
}

configure_nginx_conf() {
    local target_prefix="$1"
    phase "Configure nginx.conf"

    local conf_file="${target_prefix}/conf/nginx.conf"
    local main_format_line
    local json_format_line
    local lua_package_path_line lua_package_cpath_line
    [[ -f "${conf_file}" ]] || die "nginx.conf not found: ${conf_file}"

    main_format_line='log_format main '"'"'$remote_addr - $remote_user [$time_local] "$request" $status $body_bytes_sent "$http_referer" "$http_user_agent" "$http_x_forwarded_for"'"'"';'
    json_format_line='log_format json escape=json '"'"'{"time":"$time_iso8601","remote_addr":"$remote_addr","x_forwarded_for":"$http_x_forwarded_for","request_id":"$request_id","remote_user":"$remote_user","request":"$request","status":$status,"body_bytes_sent":$body_bytes_sent,"request_time":$request_time,"upstream_addr":"$upstream_addr","upstream_status":"$upstream_status","upstream_response_time":"$upstream_response_time","referer":"$http_referer","user_agent":"$http_user_agent","host":"$host","server_name":"$server_name","uri":"$uri","args":"$args"}'"'"';'
    lua_package_path_line="$(lua_package_path_directive)"
    lua_package_cpath_line="$(lua_package_cpath_directive)"

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

    upsert_http_directive "${conf_file}" "access_log" "access_log ${LOG_DIR}/access.log json;"

    if ! has_active_log_format "${conf_file}" "main"; then
        ensure_line_in_http_block "${conf_file}" "${main_format_line}"
    fi

    if ! has_active_log_format "${conf_file}" "json"; then
        ensure_line_in_http_block "${conf_file}" "${json_format_line}"
    fi

    upsert_http_directive "${conf_file}" "lua_package_path" "${lua_package_path_line}"
    upsert_http_directive "${conf_file}" "lua_package_cpath" "${lua_package_cpath_line}"
}

integrate_waf() {
    local target_prefix="$1"
    phase "Integrate waf/ rules"

    local conf_file="${target_prefix}/conf/nginx.conf"
    local waf_target="${target_prefix}/conf/waf"
    local waf_source="${WAF_EFFECTIVE_SOURCE_DIR}"

    if [[ "${WAF_POLICY}" == "disabled" ]]; then
        log_info "WAF policy disabled: skip waf integration."
        return 0
    fi

    if [[ -z "${waf_source}" || ! -d "${waf_source}" ]]; then
        if [[ "${WAF_POLICY}" == "required" ]]; then
            die "WAF source not found: ${waf_source:-<empty>}"
        fi
        log_warn "waf source not found: ${waf_source:-<empty>} (skip)"
        return 0
    fi

    rm -rf "${waf_target}"
    cp -a "${waf_source}" "${waf_target}"
    rewrite_waf_templates_for_prefix "${waf_target}" "${NGINX_PREFIX}/conf"

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
    lua_path="$(lua_runtime_path_for_prefix "${target_prefix}")"
    lua_cpath="$(lua_runtime_cpath_for_prefix "${target_prefix}")"
    LUA_PATH="${lua_path}" LUA_CPATH="${lua_cpath}" \
        "${nginx_bin}" -t -q -p "${target_prefix}/" -c "${nginx_conf_rel}"
}

validate_candidate() {
    phase "Validate candidate build"
    validate_nginx_conf "${CANDIDATE_PREFIX}"
    log_info "Candidate validation passed: ${CANDIDATE_PREFIX}"
}

runtime_lua_path() {
    local runtime_prefix="$1"
    lua_runtime_path_for_prefix "${runtime_prefix}"
}

runtime_lua_cpath() {
    local runtime_prefix="$1"
    lua_runtime_cpath_for_prefix "${runtime_prefix}"
}

validate_runtime_conf_with_binary() {
    local nginx_bin="$1"
    local nginx_conf_rel="conf/nginx.conf"
    local nginx_conf_abs="${RUNTIME_PREFIX}/${nginx_conf_rel}"
    local lua_path lua_cpath

    [[ -x "${nginx_bin}" ]] || die "nginx binary missing: ${nginx_bin}"
    [[ -f "${nginx_conf_abs}" ]] || die "runtime nginx conf missing: ${nginx_conf_abs}"

    lua_path="$(runtime_lua_path "${RUNTIME_PREFIX}")"
    lua_cpath="$(runtime_lua_cpath "${RUNTIME_PREFIX}")"
    LUA_PATH="${lua_path}" LUA_CPATH="${lua_cpath}" \
        "${nginx_bin}" -t -q -p "${RUNTIME_PREFIX}/" -c "${nginx_conf_rel}"
}

# ----- Release publication and runtime deployment -----------------------------
write_release_manifest() {
    local release_dir="$1"
    local manifest="${release_dir}/.release-manifest"
    local bin="${release_dir}/sbin/nginx"
    local cfg_args=""

    if [[ -x "${bin}" ]]; then
        cfg_args="$("${bin}" -V 2>&1 | sed -n 's/^configure arguments: //p' | head -n1)"
    fi

    cat > "${manifest}" <<EOF
release_dir=${release_dir}
built_at=$(date '+%Y-%m-%d %H:%M:%S')
nginx_version=${NGINX_VERSION}
openssl_version=${OPENSSL_VERSION}
pcre2_version=${PCRE2_VERSION}
jemalloc_version=${JEMALLOC_VERSION}
libmaxminddb_version=${LIBMAXMINDDB_VERSION}
waf_source_mode=${WAF_SOURCE_MODE}
waf_policy=${WAF_POLICY}
waf_source_path=${WAF_EFFECTIVE_SOURCE_DIR:-}
configure_arguments=${cfg_args}
EOF
}

publish_candidate_release() {
    phase "Publish candidate as immutable release"

    local ts release_name
    ts="$(date +%Y%m%d%H%M%S)"
    release_name="nginx-${NGINX_VERSION}-${ts}"
    RELEASE_CANDIDATE_DIR="${RELEASES_DIR}/${release_name}"
    if [[ -e "${RELEASE_CANDIDATE_DIR}" ]]; then
        RELEASE_CANDIDATE_DIR="${RELEASE_CANDIDATE_DIR}-$$"
    fi

    mkdir -p "${RELEASES_DIR}"
    cp -a "${CANDIDATE_PREFIX}" "${RELEASE_CANDIDATE_DIR}"
    [[ -x "${RELEASE_CANDIDATE_DIR}/sbin/nginx" ]] || die "release binary missing: ${RELEASE_CANDIDATE_DIR}/sbin/nginx"
    write_release_manifest "${RELEASE_CANDIDATE_DIR}"
    log_info "Release published: ${RELEASE_CANDIDATE_DIR}"
}

bootstrap_runtime_conf_from_release() {
    local release_dir="$1"
    local runtime_conf="${RUNTIME_PREFIX}/conf"

    mkdir -p "${runtime_conf}"
    if [[ -f "${runtime_conf}/nginx.conf" ]]; then
        log_info "Runtime nginx.conf already exists: ${runtime_conf}/nginx.conf (keep existing config)"
        return 0
    fi

    [[ -d "${release_dir}/conf" ]] || die "release conf dir missing: ${release_dir}/conf"
    cp -a "${release_dir}/conf/." "${runtime_conf}/"
    [[ -f "${runtime_conf}/nginx.conf" ]] || die "Runtime bootstrap failed: ${runtime_conf}/nginx.conf missing after copy"
    log_info "Initialized runtime conf from release: ${runtime_conf}"
}

sync_runtime_lua_from_release() {
    local release_dir="$1"
    local src="${release_dir}/conf/lua"
    local dst="${RUNTIME_PREFIX}/conf/lua"

    if [[ ! -d "${src}" ]]; then
        die "release lua runtime missing: ${src}"
    fi
    mkdir -p "${dst}"
    cp -a "${src}/." "${dst}/"
    log_info "Synced runtime Lua libs: ${dst}"
}

sync_runtime_waf_from_release() {
    local release_dir="$1"
    local src="${release_dir}/conf/waf"
    local dst="${RUNTIME_PREFIX}/conf/waf"
    local do_sync="${SYNC_WAF}"

    if [[ "${WAF_POLICY}" == "disabled" ]]; then
        return 0
    fi
    if [[ "${do_sync}" != "1" && -d "${dst}" ]]; then
        log_info "Skip runtime waf sync (set --sync-waf to enable)."
        return 0
    fi

    if [[ ! -d "${src}" ]]; then
        if [[ "${WAF_POLICY}" == "required" ]]; then
            die "release waf dir missing: ${src}"
        fi
        log_warn "release waf dir missing: ${src} (skip runtime waf sync)"
        return 0
    fi

    if [[ -d "${dst}" ]]; then
        local ts backup_dst
        ts="$(date +%Y%m%d%H%M%S)"
        backup_dst="${BACKUP_ROOT}/runtime-waf.${ts}.bak"
        mkdir -p "${BACKUP_ROOT}"
        cp -a "${dst}" "${backup_dst}"
        log_info "Backed up runtime waf dir: ${backup_dst}"
    fi

    rm -rf "${dst}"
    cp -a "${src}" "${dst}"
    log_info "Synced runtime waf dir: ${dst}"
}

runtime_waf_installed() {
    local runtime_waf_dir="${RUNTIME_PREFIX}/conf/waf"
    [[ -f "${runtime_waf_dir}/waf.conf" && -f "${runtime_waf_dir}/config.lua" ]]
}

resolve_active_nginx_binary() {
    local nginx_bin=""

    if [[ -x "${CURRENT_LINK}/sbin/nginx" ]]; then
        nginx_bin="${CURRENT_LINK}/sbin/nginx"
    elif [[ -x "${NGINX_PREFIX}/sbin/nginx" ]]; then
        nginx_bin="${NGINX_PREFIX}/sbin/nginx"
    elif command_exists nginx; then
        nginx_bin="$(command -v nginx 2>/dev/null || true)"
    fi

    [[ -n "${nginx_bin}" && -x "${nginx_bin}" ]] || return 1
    printf '%s\n' "${nginx_bin}"
}

nginx_binary_supports_lua_waf() {
    local nginx_bin="$1"
    local nginx_v

    nginx_v="$("${nginx_bin}" -V 2>&1 || true)"
    grep -Fq -- "lua-nginx-module" <<<"${nginx_v}" || return 1
    grep -Fq -- "ngx_devel_kit" <<<"${nginx_v}" || return 1
    return 0
}

runtime_has_lua_resty_http() {
    [[ -f "${RUNTIME_PREFIX}/conf/lua/resty/http.lua" || -f "${LUA_SHARE_DIR}/resty/http.lua" ]]
}

runtime_supports_waf_bootstrap() {
    local nginx_bin="$1"

    if ! nginx_binary_supports_lua_waf "${nginx_bin}"; then
        log_warn "Active nginx does not include required Lua modules (lua-nginx-module + ngx_devel_kit)."
        return 1
    fi
    if ! runtime_has_lua_resty_http; then
        log_warn "lua-resty-http missing in runtime/share path; cannot bootstrap WAF safely."
        return 1
    fi
    return 0
}

sync_runtime_waf_from_source() {
    local src="$1"
    local dst="${RUNTIME_PREFIX}/conf/waf"

    [[ -d "${src}" ]] || die "WAF source dir missing: ${src}"
    mkdir -p "${RUNTIME_PREFIX}/conf"

    if [[ -d "${dst}" ]]; then
        local ts backup_dst
        ts="$(date +%Y%m%d%H%M%S)"
        backup_dst="${BACKUP_ROOT}/runtime-waf.${ts}.bak"
        mkdir -p "${BACKUP_ROOT}"
        cp -a "${dst}" "${backup_dst}"
        log_info "Backed up runtime waf dir: ${backup_dst}"
    fi

    rm -rf "${dst}"
    cp -a "${src}" "${dst}"
    rewrite_waf_templates_for_prefix "${dst}" "${NGINX_PREFIX}/conf"
    log_info "Updated runtime waf dir: ${dst}"
}

reload_runtime_for_waf_update() {
    local nginx_bin="$1"
    local nginx_conf_rel="conf/nginx.conf"
    local lua_path lua_cpath

    lua_path="$(runtime_lua_path "${RUNTIME_PREFIX}")"
    lua_cpath="$(runtime_lua_cpath "${RUNTIME_PREFIX}")"
    if command_exists systemctl && systemctl is-active --quiet "${SERVICE_NAME}"; then
        systemctl reload "${SERVICE_NAME}"
        log_info "Reloaded service for WAF update: ${SERVICE_NAME}"
        return 0
    fi

    if pgrep -x nginx >/dev/null 2>&1; then
        LUA_PATH="${lua_path}" LUA_CPATH="${lua_cpath}" \
            "${nginx_bin}" -p "${RUNTIME_PREFIX}/" -c "${nginx_conf_rel}" -s reload
        log_info "Reloaded nginx master process for WAF update."
        return 0
    fi

    log_warn "nginx is not running; WAF files updated, reload manually when ready."
}

prepare_update_waf_mode() {
    if [[ "${WAF_POLICY}" == "disabled" ]]; then
        die "--update-waf-only cannot be used with --waf-policy disabled."
    fi
    if [[ "${WAF_SOURCE_MODE}" != "online" ]]; then
        log_warn "--update-waf-only forces online WAF source; overriding --waf-source to online."
        WAF_SOURCE_MODE="online"
    fi
}

unit_uses_current_layout() {
    local unit_file="$1"
    [[ -f "${unit_file}" ]] || return 1
    grep -Fq "${CURRENT_LINK}/sbin/nginx" "${unit_file}" || return 1
    grep -Fq -- "-p ${RUNTIME_PREFIX}/" "${unit_file}" || return 1
    grep -Fq -- "-c conf/nginx.conf" "${unit_file}" || return 1
}

write_systemd_unit_current_layout() {
    phase "Install systemd service (current/runtime layout)"

    if ! command_exists systemctl; then
        log_warn "systemctl not found; skip systemd unit install."
        return 0
    fi

    local lua_path lua_cpath desc
    local nginx_bin="${CURRENT_LINK}/sbin/nginx"
    local nginx_conf_rel="conf/nginx.conf"
    local nginx_prefix_arg="${RUNTIME_PREFIX}/"
    desc="${TARGET_BRAND:-Nginx} release layout"
    lua_path="$(runtime_lua_path "${RUNTIME_PREFIX}")"
    lua_cpath="$(runtime_lua_cpath "${RUNTIME_PREFIX}")"

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

maybe_rewrite_current_layout_unit() {
    SERVICE_UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
    SERVICE_UNIT_BACKUP="${BACKUP_ROOT}/${SERVICE_NAME}.service.$(date +%Y%m%d%H%M%S).bak"
    HAD_SERVICE_UNIT=0
    SERVICE_UNIT_CHANGED=0

    if ! command_exists systemctl; then
        return 0
    fi

    if [[ -f "${SERVICE_UNIT_FILE}" ]]; then
        HAD_SERVICE_UNIT=1
    fi

    if [[ "${REWRITE_UNIT}" != "1" ]]; then
        if [[ "${HAD_SERVICE_UNIT}" == "1" ]] && ! unit_uses_current_layout "${SERVICE_UNIT_FILE}"; then
            die "Existing systemd unit does not use current/runtime layout. Re-run with --rewrite-unit or set REWRITE_UNIT=1."
        fi
        return 0
    fi

    mkdir -p "${BACKUP_ROOT}"
    if [[ "${HAD_SERVICE_UNIT}" == "1" ]]; then
        cp -a "${SERVICE_UNIT_FILE}" "${SERVICE_UNIT_BACKUP}"
        log_info "Backed up systemd unit: ${SERVICE_UNIT_BACKUP}"
    fi
    write_systemd_unit_current_layout
    SERVICE_UNIT_CHANGED=1
}

switch_current_release() {
    local target_release="$1"

    [[ -d "${target_release}" ]] || die "target release not found: ${target_release}"
    [[ -x "${target_release}/sbin/nginx" ]] || die "target release nginx missing: ${target_release}/sbin/nginx"

    mkdir -p "$(dirname "${CURRENT_LINK}")"
    if [[ -d "${CURRENT_LINK}" && ! -L "${CURRENT_LINK}" ]]; then
        die "current link path exists as directory (expected symlink): ${CURRENT_LINK}"
    fi

    CURRENT_LINK_PREV_TARGET=""
    if [[ -L "${CURRENT_LINK}" ]]; then
        CURRENT_LINK_PREV_TARGET="$(readlink -f "${CURRENT_LINK}" 2>/dev/null || true)"
    fi
    ln -sfn "${target_release}" "${CURRENT_LINK}"
    CURRENT_LINK_SWITCHED=1
    log_info "Current release switched: ${CURRENT_LINK} -> ${target_release}"
}

start_or_reload_current_layout() {
    phase "Validate and start nginx (current/runtime layout)"

    local nginx_bin="${CURRENT_LINK}/sbin/nginx"
    local nginx_conf_rel="conf/nginx.conf"
    local lua_path lua_cpath
    lua_path="$(runtime_lua_path "${RUNTIME_PREFIX}")"
    lua_cpath="$(runtime_lua_cpath "${RUNTIME_PREFIX}")"

    validate_runtime_conf_with_binary "${nginx_bin}"

    if command_exists systemctl; then
        if systemctl is-active --quiet "${SERVICE_NAME}"; then
            systemctl restart "${SERVICE_NAME}"
        else
            systemctl start "${SERVICE_NAME}"
        fi
    else
        if pgrep -x nginx >/dev/null 2>&1; then
            LUA_PATH="${lua_path}" LUA_CPATH="${lua_cpath}" \
                "${nginx_bin}" -p "${RUNTIME_PREFIX}/" -c "${nginx_conf_rel}" -s reload
        else
            LUA_PATH="${lua_path}" LUA_CPATH="${lua_cpath}" \
                "${nginx_bin}" -p "${RUNTIME_PREFIX}/" -c "${nginx_conf_rel}"
        fi
    fi
}

prune_old_releases() {
    phase "Prune old releases"

    local keep="${RELEASE_KEEP}"
    local current_target=""
    local index=0
    local entry ts path
    local -a sorted=()

    [[ -d "${RELEASES_DIR}" ]] || return 0
    current_target="$(readlink -f "${CURRENT_LINK}" 2>/dev/null || true)"

    while IFS= read -r entry; do
        ts="${entry%%	*}"
        path="${entry#*	}"
        [[ -d "${path}" ]] || continue
        sorted+=("${path}")
    done < <(
        for path in "${RELEASES_DIR}"/*; do
            [[ -d "${path}" ]] || continue
            printf '%s\t%s\n' "$(stat -c %Y "${path}" 2>/dev/null || echo 0)" "${path}"
        done | sort -rn
    )

    for path in "${sorted[@]:-}"; do
        index=$((index + 1))
        if (( index <= keep )); then
            continue
        fi
        if [[ -n "${current_target}" && "${path}" == "${current_target}" ]]; then
            continue
        fi
        rm -rf "${path}"
        log_info "Pruned old release: ${path}"
    done
}

deploy_release_layout() {
    phase "Deploy release layout"

    mkdir -p "${BACKUP_ROOT}"
    mkdir -p "${RUNTIME_PREFIX}/conf"
    UPGRADE_IN_PROGRESS=1
    CURRENT_LINK_SWITCHED=0
    CURRENT_LINK_PREV_TARGET=""
    RELEASE_CANDIDATE_DIR=""

    publish_candidate_release

    if [[ ! -f "${RUNTIME_PREFIX}/conf/nginx.conf" ]]; then
        bootstrap_runtime_conf_from_release "${RELEASE_CANDIDATE_DIR}"
    fi
    [[ -f "${RUNTIME_PREFIX}/conf/nginx.conf" ]] || die "runtime nginx.conf not found: ${RUNTIME_PREFIX}/conf/nginx.conf"
    mkdir -p "${RUNTIME_PREFIX}/logs"

    sync_runtime_lua_from_release "${RELEASE_CANDIDATE_DIR}"
    sync_runtime_waf_from_release "${RELEASE_CANDIDATE_DIR}"
    validate_runtime_conf_with_binary "${RELEASE_CANDIDATE_DIR}/sbin/nginx"
    maybe_rewrite_current_layout_unit
    switch_current_release "${RELEASE_CANDIDATE_DIR}"

    if [[ "${LINK_NGINX_BIN}" == "1" ]]; then
        link_nginx_binary "${CURRENT_LINK}/sbin/nginx"
    fi

    if [[ "${ACTIVATE_SERVICE}" == "1" ]]; then
        start_or_reload_current_layout
    else
        log_warn "Release switched without service activation. Use --activate to auto start/reload."
    fi

    UPGRADE_IN_PROGRESS=0
    prune_old_releases
}

link_nginx_binary() {
    local target="${1:-${NGINX_PREFIX}/sbin/nginx}"
    phase "Link nginx into PATH"
    ln -sf "${target}" /usr/bin/nginx
}

# ----- Reporting ---------------------------------------------------------------
print_summary() {
    phase "Summary"
    echo "Install profile    : release-layout"
    echo "Target prefix      : ${NGINX_PREFIX}"
    echo "Candidate prefix   : ${CANDIDATE_PREFIX:-<none>}"
    echo "Runtime prefix     : ${RUNTIME_PREFIX}"
    echo "Releases dir       : ${RELEASES_DIR}"
    echo "Current link       : ${CURRENT_LINK}"
    echo "Runtime config     : ${RUNTIME_PREFIX}/conf/nginx.conf"
    echo "PID file           : ${PID_FILE}"
    echo "Log dir            : ${LOG_DIR}"
    echo "WAF source mode    : ${WAF_SOURCE_MODE}"
    echo "WAF policy         : ${WAF_POLICY}"
    echo "WAF source path    : ${WAF_EFFECTIVE_SOURCE_DIR:-<none>}"
    echo "Proxy URL          : ${PROXY_URL:-<none>}"
    echo "Git mirror gateway : ${GIT_MIRROR_GATEWAY:-<none>}"
    echo "Download gateway   : ${DOWNLOAD_MIRROR_GATEWAY:-<none>}"
    if [[ "${WAF_SOURCE_MODE}" == "online" ]]; then
        echo "WAF repo           : ${WAF_REPO_URL}"
        echo "WAF repo ref       : ${WAF_REPO_REF:-<default branch>}"
        echo "WAF repo subdir    : ${WAF_REPO_SUBDIR}"
    fi
    echo "WAF dir (runtime)  : ${RUNTIME_PREFIX}/conf/waf"
    echo "Service name       : ${SERVICE_NAME}"
    echo "Backup root        : ${BACKUP_ROOT}"
    echo ""
    echo "Modules            :"
    echo "  - ngx_devel_kit"
    echo "  - lua-nginx-module"
    echo "  - stream-lua-nginx-module"
    echo "  - ngx_http_geoip2_module"
    echo "  - ngx_http_substitutions_filter_module"
    echo ""
    local info_bin=""
    if [[ -x "${CANDIDATE_PREFIX}/sbin/nginx" ]]; then
        info_bin="${CANDIDATE_PREFIX}/sbin/nginx"
    elif [[ -x "${CURRENT_LINK}/sbin/nginx" ]]; then
        info_bin="${CURRENT_LINK}/sbin/nginx"
    fi
    if [[ -n "${info_bin}" ]]; then
        "${info_bin}" -V 2>&1 | sed 's/^/  /'
    fi
    echo ""
    echo "Next step:"
    if [[ "${ACTIVATE_SERVICE}" == "1" ]]; then
        echo "  Verify service/runtime health and application routes."
    else
        echo "  Manual check before restart: nginx -t with runtime config, then restart/reload when ready."
    fi
}

print_dry_run_plan() {
    phase "Dry-run execution plan"
    echo "Install profile   : release-layout"
    echo "Dry run           : ${DRY_RUN}"
    echo "Target prefix     : ${NGINX_PREFIX}"
    echo "Runtime prefix    : ${RUNTIME_PREFIX}"
    echo "Releases dir      : ${RELEASES_DIR}"
    echo "Current link      : ${CURRENT_LINK}"
    echo "Release keep      : ${RELEASE_KEEP}"
    echo "Service name      : ${SERVICE_NAME}"
    echo "Backup root       : ${BACKUP_ROOT}"
    echo "WAF source mode   : ${WAF_SOURCE_MODE}"
    echo "WAF policy        : ${WAF_POLICY}"
    echo "Sync WAF          : ${SYNC_WAF}"
    echo "Proxy URL         : ${PROXY_URL:-<none>}"
    echo "Git mirror        : ${GIT_MIRROR_GATEWAY:-<none>}"
    echo "Download gateway  : ${DOWNLOAD_MIRROR_GATEWAY:-<none>}"
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
    echo "Rewrite unit      : ${REWRITE_UNIT}"
    echo ""
    echo "Planned steps:"
    echo "  1) Detect OS and install build dependencies"
    echo "  2) Resolve dependency versions (Nginx/OpenSSL/PCRE2/jemalloc/libmaxminddb)"
    echo "  3) Download sources and modules"
    if [[ "${WAF_SOURCE_MODE}" == "online" && "${WAF_POLICY}" != "disabled" ]]; then
        echo "  4) Fetch online WAF repo (${WAF_REPO_URL}) and locate ${WAF_REPO_SUBDIR}/"
        echo "  5) Build candidate nginx under workdir (DESTDIR install)"
        echo "  6) Patch candidate nginx.conf and integrate waf/"
        echo "  7) Validate candidate with nginx -t"
    else
        echo "  4) Build candidate nginx under workdir (DESTDIR install)"
        echo "  5) Patch candidate nginx.conf and integrate waf/"
        echo "  6) Validate candidate with nginx -t"
    fi
    echo "  7+) Publish candidate to immutable release under ${RELEASES_DIR}"
    echo "  8+) Initialize runtime config only if missing at ${RUNTIME_PREFIX}/conf/nginx.conf"
    echo "  9+) Sync runtime Lua assets and optional WAF assets under ${RUNTIME_PREFIX}/conf"
    echo "  10+) Validate runtime config with new release binary"
    echo "  11+) Switch ${CURRENT_LINK} to new release"
    if [[ "${ACTIVATE_SERVICE}" == "1" ]]; then
        echo "  12+) Start/reload service automatically"
    else
        echo "  12+) Keep service untouched for manual verification/restart"
    fi
    echo "  13+) Prune old releases, keeping newest ${RELEASE_KEEP}"
}

print_update_waf_dry_run_plan() {
    phase "Dry-run execution plan (update-waf-only)"
    echo "Execution mode     : update-waf-only"
    echo "Dry run            : ${DRY_RUN}"
    echo "Runtime prefix     : ${RUNTIME_PREFIX}"
    echo "Current link       : ${CURRENT_LINK}"
    echo "Service name       : ${SERVICE_NAME}"
    echo "Backup root        : ${BACKUP_ROOT}"
    echo "WAF source mode    : ${WAF_SOURCE_MODE}"
    echo "WAF policy         : ${WAF_POLICY}"
    echo "WAF repo           : ${WAF_REPO_URL}"
    echo "WAF repo ref       : ${WAF_REPO_REF:-<default branch>}"
    echo "WAF repo subdir    : ${WAF_REPO_SUBDIR}"
    echo "Proxy URL          : ${PROXY_URL:-<none>}"
    echo "Git mirror gateway : ${GIT_MIRROR_GATEWAY:-<none>}"
    echo "Download gateway   : ${DOWNLOAD_MIRROR_GATEWAY:-<none>}"
    echo ""
    echo "Planned steps:"
    echo "  1) Check runtime nginx binary and runtime conf path"
    echo "  2) Check whether runtime waf is already installed"
    echo "  3) If WAF missing, verify Lua module support + lua-resty-http availability"
    echo "  4) Clone/fetch online WAF repository only (no compile/build)"
    echo "  5) Replace ${RUNTIME_PREFIX}/conf/waf with repo content"
    echo "  6) If WAF missing, patch runtime nginx.conf include + Lua package directives"
    echo "  7) Validate runtime config and reload running nginx/service"
}

# ----- Orchestration -----------------------------------------------------------
run_dry_run_flow() {
    if [[ "${UPDATE_WAF_ONLY}" == "1" ]]; then
        prepare_update_waf_mode
        resolve_waf_source
        print_update_waf_dry_run_plan
        return 0
    fi

    resolve_waf_source
    resolve_brand
    print_dry_run_plan
}

run_update_waf_flow() {
    phase "Update runtime WAF only"

    local runtime_conf="${RUNTIME_PREFIX}/conf/nginx.conf"
    local nginx_bin=""
    local waf_installed=0

    prepare_update_waf_mode
    ensure_root

    if [[ ! -f "${runtime_conf}" ]]; then
        log_warn "Runtime nginx.conf not found: ${runtime_conf}. Skip --update-waf-only."
        return 0
    fi

    if ! nginx_bin="$(resolve_active_nginx_binary)"; then
        log_warn "Active nginx binary not found. Skip --update-waf-only."
        return 0
    fi
    log_kv "Active nginx bin" "${nginx_bin}"

    if runtime_waf_installed; then
        waf_installed=1
        log_info "Runtime WAF installation detected."
    else
        log_warn "Runtime WAF not detected under ${RUNTIME_PREFIX}/conf/waf."
    fi

    if [[ "${waf_installed}" != "1" ]]; then
        phase "Preflight runtime support for WAF bootstrap"
        if ! runtime_supports_waf_bootstrap "${nginx_bin}"; then
            log_warn "Runtime lacks required Lua/WAF support. Skip WAF update."
            return 0
        fi
    fi

    resolve_waf_source
    prepare_workspace
    prepare_waf_source

    if [[ -z "${WAF_EFFECTIVE_SOURCE_DIR}" || ! -d "${WAF_EFFECTIVE_SOURCE_DIR}" ]]; then
        if [[ "${WAF_POLICY}" == "required" ]]; then
            die "WAF update source unavailable: ${WAF_EFFECTIVE_SOURCE_DIR:-<empty>}"
        fi
        log_warn "WAF update source unavailable: ${WAF_EFFECTIVE_SOURCE_DIR:-<empty>} (skip update)"
        return 0
    fi

    sync_runtime_waf_from_source "${WAF_EFFECTIVE_SOURCE_DIR}"
    if [[ "${waf_installed}" != "1" ]]; then
        if ! ensure_runtime_waf_integration; then
            log_warn "Runtime nginx.conf missing; skip WAF integration patch."
        fi
    fi

    validate_runtime_conf_with_binary "${nginx_bin}"
    reload_runtime_for_waf_update "${nginx_bin}"
    log_info "WAF update-only flow completed."
}

run_install_flow() {
    resolve_waf_source
    resolve_brand
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
    deploy_release_layout
    print_summary
}

main() {
    parse_args "$@"
    resolve_network_options
    apply_network_proxy
    safety_guard
    detect_os
    resolve_versions

    if [[ "${DRY_RUN}" == "1" ]]; then
        run_dry_run_flow
        return 0
    fi

    if [[ "${UPDATE_WAF_ONLY}" == "1" ]]; then
        run_update_waf_flow
        return 0
    fi

    run_install_flow
}

main "$@"

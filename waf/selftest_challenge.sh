#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# Minimal runtime self-test for waf/challenge flow.
# Requirements on target:
# - C.switch.cc = true
# - C.cc.action = "captcha"
# - C.challenge.enabled = true
# - C.challenge.secret set to non-default
# - Use provider "native" for full automation (turnstile requires manual token)

BASE_URL="${BASE_URL:-http://127.0.0.1}"
TARGET_URI="${TARGET_URI:-/}"
PROBE_URI="${PROBE_URI:-/robots.txt?__waf_probe=1}"
CAPTCHA_URI="${CAPTCHA_URI:-/captcha-waf.html}"
VERIFY_URI="${VERIFY_URI:-/captcha-waf/verify}"
CONTINUE_PARAM="${CONTINUE_PARAM:-continue}"
PASS_COOKIE_NAME="${PASS_COOKIE_NAME:-__waf_pass}"
CC_BURST_MAX="${CC_BURST_MAX:-80}"
UA="${UA:-waf-selftest/1.0}"
COOKIE_JAR="${COOKIE_JAR:-}"
CURL_TIMEOUT="${CURL_TIMEOUT:-15}"
CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-5}"
TLS_INSECURE="${TLS_INSECURE:-1}"

TMP_DIR="$(mktemp -d -t waf-selftest-XXXXXX)"
if [[ -z "${COOKIE_JAR}" ]]; then
    COOKIE_JAR="${TMP_DIR}/cookie.jar"
fi
HDR_FILE="${TMP_DIR}/headers.txt"
BODY_FILE="${TMP_DIR}/body.txt"

STATUS=""
LOCATION=""
CONTINUE_RAW=""

cleanup() {
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

log() { printf '[selftest] %s\n' "$*"; }
fail() { printf '[selftest][FAIL] %s\n' "$*" >&2; exit 1; }
pass() { printf '[selftest][PASS] %s\n' "$*"; }

normalize_bool() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|on|ON) printf '1\n' ;;
        0|false|FALSE|no|NO|off|OFF) printf '0\n' ;;
        *) fail "invalid boolean value: ${1} (expected true/false/1/0)" ;;
    esac
}

escape_ere() {
    printf '%s' "${1:-}" | sed 's/[][(){}.^$*+?|\/\\]/\\&/g'
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

TLS_INSECURE="$(normalize_bool "${TLS_INSECURE}")"
PASS_COOKIE_NAME_RE="$(escape_ere "${PASS_COOKIE_NAME}")"
CONTINUE_PARAM_RE="$(escape_ere "${CONTINUE_PARAM}")"

require_cmd curl
require_cmd awk
require_cmd sed
require_cmd grep
require_cmd tr

curl_common() {
    local -a args=(
        -sS
        -A "${UA}"
        -b "${COOKIE_JAR}"
        -c "${COOKIE_JAR}"
        -D "${HDR_FILE}"
        -o "${BODY_FILE}"
        --max-time "${CURL_TIMEOUT}"
        --connect-timeout "${CURL_CONNECT_TIMEOUT}"
    )
    if [[ "${TLS_INSECURE}" == "1" ]]; then
        args=(-k "${args[@]}")
    fi
    printf '%s\0' "${args[@]}"
}

http_get() {
    local uri="$1"
    local -a args=()
    while IFS= read -r -d '' v; do
        args+=("${v}")
    done < <(curl_common)
    curl "${args[@]}" "${BASE_URL}${uri}" >/dev/null
    STATUS="$(awk 'toupper($1) ~ /^HTTP\// {code=$2} END {print code+0}' "${HDR_FILE}")"
    LOCATION="$(awk 'BEGIN{IGNORECASE=1} /^Location:/{sub(/\r$/,"",$2); print $2; exit}' "${HDR_FILE}")"
}

http_post_native_verify() {
    local cont="$1"
    local nonce="$2"
    local code="$3"
    local -a args=()
    while IFS= read -r -d '' v; do
        args+=("${v}")
    done < <(curl_common)
    curl "${args[@]}" \
        --data-urlencode "${CONTINUE_PARAM}=${cont}" \
        --data-urlencode "native_nonce=${nonce}" \
        --data-urlencode "native_code=${code}" \
        "${BASE_URL}${VERIFY_URI}" >/dev/null
    STATUS="$(awk 'toupper($1) ~ /^HTTP\// {code=$2} END {print code+0}' "${HDR_FILE}")"
    LOCATION="$(awk 'BEGIN{IGNORECASE=1} /^Location:/{sub(/\r$/,"",$2); print $2; exit}' "${HDR_FILE}")"
}

extract_continue_from_location() {
    local loc="$1"
    printf '%s\n' "${loc}" | sed -n "s/.*[?&]${CONTINUE_PARAM_RE}=\([^&]*\).*/\1/p" | head -n1
}

extract_form_value() {
    local key="$1"
    local key_re
    key_re="$(escape_ere "${key}")"
    sed -n "s/.*name=\"${key_re}\" value=\"\\([^\"]*\\)\".*/\\1/p" "${BODY_FILE}" | head -n1
}

extract_continue_from_body() {
    extract_form_value "${CONTINUE_PARAM}"
}

extract_native_nonce() {
    extract_form_value "native_nonce"
}

extract_native_code() {
    sed -n 's/.*<div class="code">\([^<]*\)<\/div>.*/\1/p' "${BODY_FILE}" | head -n1 | tr -d '[:space:]'
}

has_set_cookie_pass() {
    grep -Eqi "^Set-Cookie:[[:space:]]*${PASS_COOKIE_NAME_RE}=" "${HDR_FILE}"
}

is_redirect_to_captcha() {
    case "${STATUS}" in
        301|302|303|307|308) ;;
        *) return 1 ;;
    esac
    [[ "${LOCATION}" == "${CAPTCHA_URI}"* ]] && return 0
    return 1
}

trigger_challenge_lock() {
    local i
    for ((i=1; i<=CC_BURST_MAX; i++)); do
        http_get "${TARGET_URI}"
        if is_redirect_to_captcha; then
            CONTINUE_RAW="$(extract_continue_from_location "${LOCATION}")"
            if [[ -z "${CONTINUE_RAW}" ]]; then
                fail "redirected to captcha but missing continue parameter"
            fi
            pass "CC triggered captcha lock after ${i} requests"
            return 0
        fi
    done
    fail "CC challenge not triggered within ${CC_BURST_MAX} requests. Lower cc rate or use clean test IP."
}

main() {
    log "Base URL: ${BASE_URL}"
    log "Target URI: ${TARGET_URI}"
    log "Probe URI: ${PROBE_URI}"
    log "Captcha URI: ${CAPTCHA_URI}"
    log "Verify URI: ${VERIFY_URI}"
    log "Continue param: ${CONTINUE_PARAM}"
    log "Pass cookie name: ${PASS_COOKIE_NAME}"
    log "TLS insecure: ${TLS_INSECURE}"

    http_get "${CAPTCHA_URI}"
    [[ "${STATUS}" == "200" ]] || fail "captcha page expected 200, got ${STATUS}"
    pass "captcha page reachable"

    trigger_challenge_lock

    http_get "${PROBE_URI}"
    is_redirect_to_captcha || fail "locked client should be redirected from another URL"
    pass "lock applies across URL changes"

    http_get "${CAPTCHA_URI}"
    [[ "${STATUS}" == "200" ]] || fail "captcha page should return 200 during lock"
    local cont_from_page
    cont_from_page="$(extract_continue_from_body)"
    [[ -n "${cont_from_page}" ]] || fail "captcha page missing continue hidden field"
    [[ "${cont_from_page}" == "${CONTINUE_RAW}" ]] || fail "continue mismatch between lock redirect and captcha page"
    pass "continue target persisted in lock state"

    if grep -q 'cf-turnstile' "${BODY_FILE}"; then
        log "provider=turnstile detected (manual solve required)."
        log "Manual check:"
        log "1) Open ${BASE_URL}${CAPTCHA_URI}"
        log "2) Complete turnstile challenge"
        log "3) Confirm redirected to original URL"
        log "4) Re-trigger CC and confirm old cookie cannot bypass new lock"
        pass "automated checks completed for turnstile mode"
        exit 0
    fi

    local nonce code
    nonce="$(extract_native_nonce)"
    code="$(extract_native_code)"
    [[ -n "${nonce}" && -n "${code}" ]] || fail "native challenge fields not found"
    pass "native challenge fields extracted"

    http_post_native_verify "${cont_from_page}" "${nonce}" "WRONGCODE"
    [[ "${STATUS}" == "200" ]] || fail "wrong native code should stay on challenge page (200), got ${STATUS}"
    pass "wrong native code rejected"

    http_get "${CAPTCHA_URI}"
    [[ "${STATUS}" == "200" ]] || fail "captcha page should still be reachable after wrong attempt"
    nonce="$(extract_native_nonce)"
    code="$(extract_native_code)"
    [[ -n "${nonce}" && -n "${code}" ]] || fail "failed to extract refreshed native challenge"

    http_post_native_verify "${cont_from_page}" "${nonce}" "${code}"
    case "${STATUS}" in
        301|302|303|307|308) ;;
        *) fail "correct native code should redirect (3xx), got ${STATUS}" ;;
    esac
    has_set_cookie_pass || fail "expected ${PASS_COOKIE_NAME} Set-Cookie after successful verify"
    pass "correct native code accepted and pass cookie issued"

    http_get "${TARGET_URI}"
    if is_redirect_to_captcha; then
        fail "verified client should not be redirected to captcha immediately"
    fi
    pass "verified client can access normal URL"

    # Re-trigger lock and verify stale cookie cannot bypass.
    trigger_challenge_lock
    http_get "${PROBE_URI}"
    is_redirect_to_captcha || fail "old pass cookie bypassed new lock (regression)"
    pass "old pass cookie cannot bypass newly issued lock"

    pass "all automated challenge checks passed"
}

main "$@"

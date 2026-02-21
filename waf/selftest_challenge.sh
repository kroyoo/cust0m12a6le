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
CC_BURST_MAX="${CC_BURST_MAX:-80}"
UA="${UA:-waf-selftest/1.0}"
COOKIE_JAR="${COOKIE_JAR:-}"

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

http_get() {
    local uri="$1"
    curl -ksS \
        -A "${UA}" \
        -b "${COOKIE_JAR}" \
        -c "${COOKIE_JAR}" \
        -D "${HDR_FILE}" \
        -o "${BODY_FILE}" \
        "${BASE_URL}${uri}" >/dev/null
    STATUS="$(awk 'toupper($1) ~ /^HTTP\// {code=$2} END {print code+0}' "${HDR_FILE}")"
    LOCATION="$(awk 'BEGIN{IGNORECASE=1} /^Location:/{sub(/\r$/,"",$2); print $2; exit}' "${HDR_FILE}")"
}

http_post_native_verify() {
    local cont="$1"
    local nonce="$2"
    local code="$3"
    curl -ksS \
        -A "${UA}" \
        -b "${COOKIE_JAR}" \
        -c "${COOKIE_JAR}" \
        -D "${HDR_FILE}" \
        -o "${BODY_FILE}" \
        --data-urlencode "continue=${cont}" \
        --data-urlencode "native_nonce=${nonce}" \
        --data-urlencode "native_code=${code}" \
        "${BASE_URL}${VERIFY_URI}" >/dev/null
    STATUS="$(awk 'toupper($1) ~ /^HTTP\// {code=$2} END {print code+0}' "${HDR_FILE}")"
    LOCATION="$(awk 'BEGIN{IGNORECASE=1} /^Location:/{sub(/\r$/,"",$2); print $2; exit}' "${HDR_FILE}")"
}

extract_continue_from_location() {
    local loc="$1"
    printf '%s\n' "${loc}" | sed -n 's/.*[?&]continue=\([^&]*\).*/\1/p' | head -n1
}

extract_continue_from_body() {
    sed -n 's/.*name="continue" value="\([^"]*\)".*/\1/p' "${BODY_FILE}" | head -n1
}

extract_native_nonce() {
    sed -n 's/.*name="native_nonce" value="\([^"]*\)".*/\1/p' "${BODY_FILE}" | head -n1
}

extract_native_code() {
    sed -n 's/.*<div class="code">\([^<]*\)<\/div>.*/\1/p' "${BODY_FILE}" | head -n1 | tr -d '[:space:]'
}

has_set_cookie_pass() {
    grep -Eqi '^Set-Cookie:[[:space:]]*__waf_pass=' "${HDR_FILE}"
}

is_redirect_to_captcha() {
    [[ "${STATUS}" == "302" ]] || return 1
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
    log "Captcha URI: ${CAPTCHA_URI}"
    log "Verify URI: ${VERIFY_URI}"

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
    [[ "${STATUS}" == "302" ]] || fail "correct native code should redirect (302), got ${STATUS}"
    has_set_cookie_pass || fail "expected __waf_pass Set-Cookie after successful verify"
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

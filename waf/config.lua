local C = {}

C.defaults = {
    nginx_conf_dir = "/usr/local/nginx/conf",
    fallback_log_dir = "/tmp",
    deny_redirect_uri = "/403.html",
    captcha_uri = "/captcha-waf.html",
    captcha_verify_uri = "/captcha-waf/verify",
    forbidden_json = [[{"code":403,"message":"Forbidden by WAF"}]],
    fail_closed_status = 500,
    fail_closed_json = [[{"code":500,"message":"WAF internal error"}]],
    cc_rate_count = 120,
    cc_rate_seconds = 60,
    output_status = 403,
    cc_status = 429,
    header_limit = 64,
    request_arg_limit = 256,
    post_arg_limit = 256,
    max_body_inspect_bytes = 65536,
    rule_ttl = 30,
    post_methods = { "POST", "PUT", "PATCH" },
    hit_detail_max_len = 512,
    challenge_cookie_name = "__waf_pass",
    challenge_cookie_ttl = 1800,
    challenge_lock_ttl = 600,
    challenge_secret = "CHANGE_ME_TO_A_RANDOM_32B_SECRET",
    challenge_native_code_len = 5,
    challenge_native_code_ttl = 300,
    challenge_verify_timeout_ms = 3000,
    challenge_turnstile_verify_url = "https://challenges.cloudflare.com/turnstile/v0/siteverify"
}

local function copy_array(src)
    local out = {}
    for i, v in ipairs(src or {}) do
        out[i] = v
    end
    return out
end

local function detect_conf_dir()
    local prefix = ""
    if ngx and ngx.config and ngx.config.prefix then
        prefix = ngx.config.prefix() or ""
    end

    prefix = tostring(prefix):gsub("/+$", "")
    if prefix ~= "" then
        return prefix .. "/conf"
    end
    return C.defaults.nginx_conf_dir
end

C.meta = {
    name = "waf-v3",
    version = "3.2.1"
}

C.runtime = {
    -- fail open keeps site available if waf module crashes
    fail_open = true
}

C.route = {
    captcha_uri = C.defaults.captcha_uri,
    captcha_verify_uri = C.defaults.captcha_verify_uri,
    deny_redirect_uri = C.defaults.deny_redirect_uri
}

C.paths = {
    nginx_conf_dir = detect_conf_dir(),
    rule_dir = nil,
    log_dir = "/data/wwwlogs",
    fallback_log_dir = C.defaults.fallback_log_dir
}
C.paths.rule_dir = C.paths.rule_dir or (C.paths.nginx_conf_dir .. "/waf/wafconf")

C.log = {
    -- file | error | off
    mode = "file",
    detail_max_len = C.defaults.hit_detail_max_len,
    async = true,
    flush_interval = 0.2,
    batch_lines = 128,
    max_queue_lines = 5000,
    -- drop_oldest | drop_newest
    drop_policy = "drop_newest"
}

C.cache = {
    rule_ttl = C.defaults.rule_ttl
}

C.trust = {
    -- trust x-forwarded-for / x-real-ip only when behind trusted reverse proxy
    forwarded_ip = false
}

C.switch = {
    waf = true,
    white_url = true,
    white_referer = false,
    white_ip = true,
    black_ip = true,
    url = true,
    url_args = true,
    user_agent = true,
    cookie = true,
    cc = true,
    post = true
}

C.pipeline_default = {
    "black_ip",
    "white_ip",
    "white_referer",
    "white_url",
    "user_agent",
    "cc",
    "cookie",
    "url",
    "url_args",
    "post"
}
C.pipeline = copy_array(C.pipeline_default)

C.parse = {
    header_limit = C.defaults.header_limit,
    -- ngx.req.get_headers(limit, raw): raw=true keeps original header case
    raw_headers = false,
    -- legacy alias retained for backward compatibility
    include_underscored_headers = true,
    request_arg_limit = C.defaults.request_arg_limit,
    post_arg_limit = C.defaults.post_arg_limit,
    block_on_truncated_args = true,
    block_on_truncated_post = true,
    max_body_inspect_bytes = C.defaults.max_body_inspect_bytes,
    post_methods = C.defaults.post_methods,
    hit_detail_max_len = C.defaults.hit_detail_max_len
}

C.cc = {
    -- count per seconds
    rate = "120/60",
    default_count = C.defaults.cc_rate_count,
    default_seconds = C.defaults.cc_rate_seconds,
    -- forbidden | captcha
    -- when captcha is selected, challenge lock + verify flow is required
    action = "forbidden",
    status = C.defaults.cc_status
}

C.challenge = {
    enabled = true,
    -- turnstile | native
    provider = "turnstile",
    lock_ttl = C.defaults.challenge_lock_ttl,
    cookie_name = C.defaults.challenge_cookie_name,
    cookie_ttl = C.defaults.challenge_cookie_ttl,
    bind_ua = true,
    cookie_secure = false,
    cookie_samesite = "Lax",
    secret = C.defaults.challenge_secret,
    continue_param = "continue",
    turnstile = {
        site_key = "",
        secret_key = "",
        verify_url = C.defaults.challenge_turnstile_verify_url,
        timeout_ms = C.defaults.challenge_verify_timeout_ms
    },
    native = {
        code_len = C.defaults.challenge_native_code_len,
        code_ttl = C.defaults.challenge_native_code_ttl
    }
}

C.output = {
    -- html | json | redirect
    mode = "html",
    status = C.defaults.output_status,
    redirect_url = C.route.deny_redirect_uri,
    json = C.defaults.forbidden_json,
    fail_closed_status = C.defaults.fail_closed_status,
    fail_closed_json = C.defaults.fail_closed_json
}

C.page = {
    brand = "Nginx WAF v3",
    note = "Adaptive edge defense",
    defaults = {
        lang = "en",
        badge = "Protected",
        title = "Request blocked",
        description = "Your request was denied by security policy.",
        hint = "If this appears to be a false positive, contact support.",
        action_label = "Return",
        action_href = "/"
    },
    themes = {
        deny = {
            bg_a = "#0f172a",
            bg_b = "#451a03",
            accent = "#fb7185",
            accent_soft = "rgba(251, 113, 133, 0.2)"
        },
        cc = {
            bg_a = "#111827",
            bg_b = "#3f2f0f",
            accent = "#f59e0b",
            accent_soft = "rgba(245, 158, 11, 0.2)"
        },
        wechat = {
            bg_a = "#0f172a",
            bg_b = "#064e3b",
            accent = "#34d399",
            accent_soft = "rgba(52, 211, 153, 0.22)"
        },
        captcha = {
            bg_a = "#0f172a",
            bg_b = "#0b3a67",
            accent = "#38bdf8",
            accent_soft = "rgba(56, 189, 248, 0.2)"
        }
    },
    deny = {
        lang = "en",
        badge = "Request denied",
        title = "Access Rejected",
        description = "This request was blocked by active security policy.",
        hint = "If this is unexpected, contact support and provide the Request ID.",
        action_label = "Return Home",
        action_href = "/"
    },
    cc = {
        lang = "en",
        badge = "Rate limited",
        title = "Too Many Requests",
        description = "Traffic from your network exceeded the current threshold.",
        hint = "Please wait for the cooldown window and try again.",
        action_label = "Retry Later",
        action_href = "/"
    },
    wechat = {
        lang = "zh-CN",
        badge = "访问受限",
        title = "请切换系统浏览器访问",
        description = "当前客户端环境受限，已触发站点安全策略。",
        hint = "请点击右上角“...”并选择“在浏览器打开”后重试。",
        action_label = "",
        action_href = ""
    },
    captcha = {
        lang = "en",
        badge = "Verification required",
        title = "Temporary Verification Gate",
        description = "Abnormal traffic traits were detected from your network.",
        hint = "Wait briefly and retry. If this persists, contact support.",
        action_label = "Try Again",
        action_href = "/"
    }
}

-- keep filenames centralized so policy code does not hardcode magic strings
C.rule_files = {
    white_ip = "whiteip",
    black_ip = "blackip",
    white_referer = "whitereferer",
    white_url = "whiteurl",
    black_url = "blackurl",
    args = "args",
    cookie = "cookie",
    post = "post",
    useragent = "useragent",
    tencent_useragent = "tencent_useragent"
}

return C

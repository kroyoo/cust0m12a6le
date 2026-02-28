local C = require "config"
local U = require "util"
local Logger = require "logger"

local Challenge = {}

local WARNED = {}
local RNG_SEEDED = false
local LOCK_VALUE_VERSION = "v1"
local challenge_lock_info

local cjson = nil
do
    local ok, mod = pcall(require, "cjson.safe")
    if ok and mod and mod.decode then
        cjson = mod
    else
        ok, mod = pcall(require, "cjson")
        if ok and mod and mod.decode then
            cjson = mod
        end
    end
end

local function warn_once(key, ...)
    if WARNED[key] then
        return
    end
    WARNED[key] = true
    Logger.warn(...)
end

local function seed_rng_once()
    if RNG_SEEDED then
        return
    end
    RNG_SEEDED = true

    local base = table.concat({
        tostring((ngx and ngx.worker and ngx.worker.pid and ngx.worker.pid()) or ""),
        tostring((ngx and ngx.now and ngx.now()) or os.time()),
        tostring((ngx and ngx.var and ngx.var.request_id) or ""),
        tostring(math.random())
    }, "|")

    local seed = 0
    for i = 1, #base do
        seed = (seed * 131 + base:byte(i)) % 2147483647
    end
    if seed == 0 then
        seed = 1315423911
    end
    math.randomseed(seed)
    math.random()
    math.random()
    math.random()
end

local function challenge_cfg()
    return C.challenge or {}
end

local function route_page()
    return (C.route and C.route.captcha_uri) or (C.defaults and C.defaults.captcha_uri) or "/captcha-waf.html"
end

local function route_verify()
    return (C.route and C.route.captcha_verify_uri) or (C.defaults and C.defaults.captcha_verify_uri) or "/captcha-waf/verify"
end

local function page_path_from_uri(uri)
    local s = tostring(uri or "")
    local q = s:find("?", 1, true)
    if q then
        return s:sub(1, q - 1)
    end
    return s
end

local function shared_dict()
    if ngx and ngx.shared then
        return ngx.shared.waf_challenge
    end
    return nil
end

local function now_epoch()
    if ngx and ngx.time then
        return ngx.time()
    end
    return os.time()
end

local function html_escape(v)
    local s = tostring(v or "")
    s = s:gsub("&", "&amp;")
    s = s:gsub("<", "&lt;")
    s = s:gsub(">", "&gt;")
    s = s:gsub("\"", "&quot;")
    s = s:gsub("'", "&#39;")
    return s
end

local function get_secret()
    local s = tostring((challenge_cfg().secret) or "")
    if s == "" or s == "CHANGE_ME_TO_A_RANDOM_32B_SECRET" then
        return nil
    end
    return s
end

local function b64url_encode(v)
    if not (ngx and ngx.encode_base64) then
        return tostring(v or "")
    end
    local out = ngx.encode_base64(tostring(v or ""), true)
    out = out:gsub("+", "-"):gsub("/", "_"):gsub("=", "")
    return out
end

local function b64url_decode(v)
    if not (ngx and ngx.decode_base64) then
        return nil
    end
    if not v or v == "" then
        return nil
    end
    local s = tostring(v):gsub("-", "+"):gsub("_", "/")
    local rem = #s % 4
    if rem == 2 then
        s = s .. "=="
    elseif rem == 3 then
        s = s .. "="
    elseif rem == 1 then
        return nil
    end
    return ngx.decode_base64(s)
end

local function sign_payload(payload)
    local secret = get_secret() or ""
    if ngx and ngx.hmac_sha1 and ngx.encode_base64 then
        local raw = ngx.hmac_sha1(secret, payload)
        return ngx.encode_base64(raw, true)
    end
    if ngx and ngx.md5 then
        return ngx.md5(secret .. "|" .. payload)
    end
    return secret .. "|" .. payload
end

local function binding_value(ctx)
    local ip = tostring((ctx and ctx.client_ip) or "-")
    if challenge_cfg().bind_ua then
        local ua = U.lower((ctx and ctx.user_agent) or "")
        ip = ip .. "|" .. ua
    end
    if ngx and ngx.md5 then
        return ngx.md5(ip)
    end
    return ip
end

local function lock_key(ctx)
    local ip = tostring((ctx and ctx.client_ip) or "-")
    return "lock:" .. ip
end

local function pass_cookie_name()
    return tostring(challenge_cfg().cookie_name or (C.defaults and C.defaults.challenge_cookie_name) or "__waf_pass")
end

local function pass_cookie_ttl()
    return tonumber(challenge_cfg().cookie_ttl) or tonumber(C.defaults and C.defaults.challenge_cookie_ttl) or 1800
end

local function lock_ttl()
    return tonumber(challenge_cfg().lock_ttl) or tonumber(C.defaults and C.defaults.challenge_lock_ttl) or 600
end

local function append_set_cookie(line)
    local key = "Set-Cookie"
    local current = ngx.header[key]
    if not current then
        ngx.header[key] = line
        return
    end
    if type(current) == "table" then
        current[#current + 1] = line
        ngx.header[key] = current
        return
    end
    ngx.header[key] = { current, line }
end

local function set_cookie(name, value, max_age)
    local cfg = challenge_cfg()
    local same_site = tostring(cfg.cookie_samesite or "Lax")
    local secure = U.bool(cfg.cookie_secure)
    local cookie = {
        tostring(name), "=",
        tostring(value or ""),
        "; Path=/; HttpOnly; SameSite=", same_site,
        "; Max-Age=", tostring(tonumber(max_age) or 0)
    }
    if secure then
        cookie[#cookie + 1] = "; Secure"
    end
    append_set_cookie(table.concat(cookie))
end

local function clear_pass_cookie()
    set_cookie(pass_cookie_name(), "", 0)
end

local function parse_cookie(name)
    local source = (ngx and ngx.var and ngx.var.http_cookie) or ""
    for segment in tostring(source):gmatch("([^;]+)") do
        local k, v = segment:match("^%s*([^=]+)%s*=%s*(.-)%s*$")
        if k == name then
            return v
        end
    end
    return nil
end

local function issue_pass_cookie(ctx)
    local exp = now_epoch() + pass_cookie_ttl()
    local iat = now_epoch()
    local bind = binding_value(ctx)
    local payload = tostring(exp) .. "|" .. tostring(iat) .. "|" .. bind
    local sig = sign_payload(payload)
    local token = b64url_encode(payload .. "|" .. sig)
    set_cookie(pass_cookie_name(), token, pass_cookie_ttl())
end

local function has_valid_pass(ctx)
    local token = parse_cookie(pass_cookie_name())
    if not token then
        return false
    end

    local raw = b64url_decode(token)
    if not raw then
        return false
    end

    local exp, iat, bind, sig = tostring(raw):match("^(%d+)|(%d+)|([0-9a-fA-F]+)|(.+)$")
    local legacy = false
    if not exp then
        exp, bind, sig = tostring(raw):match("^(%d+)|([0-9a-fA-F]+)|(.+)$")
        iat = "0"
        legacy = true
    end
    if not exp or not bind or not sig then
        return false
    end
    if tonumber(exp) <= now_epoch() then
        return false
    end

    if bind ~= binding_value(ctx) then
        return false
    end

    local payload
    if legacy then
        payload = exp .. "|" .. bind
    else
        payload = exp .. "|" .. iat .. "|" .. bind
    end

    local expected = sign_payload(payload)
    if sig ~= expected then
        return false
    end

    local lock = challenge_lock_info(ctx)
    if lock and (tonumber(lock.issued) or 0) >= (tonumber(iat) or 0) then
        return false
    end

    return true
end

local function first_value(v)
    if type(v) == "table" then
        return tostring(v[1] or "")
    end
    if v == nil then
        return nil
    end
    return tostring(v)
end

local function encode_continue_target(uri)
    return b64url_encode(tostring(uri or "/"))
end

local function encode_lock_value(reason, continue_raw, issued_at)
    local reason_enc = b64url_encode(tostring(reason or "challenge"))
    local continue_enc = tostring(continue_raw or encode_continue_target("/"))
    local issued = tonumber(issued_at) or now_epoch()
    return table.concat({
        LOCK_VALUE_VERSION,
        tostring(issued),
        continue_enc,
        reason_enc
    }, ".")
end

local function decode_lock_value(raw)
    local s = tostring(raw or "")
    if s == "" then
        return nil
    end

    local ver, issued, cont, reason_enc = s:match("^([^%.]+)%.(%d+)%.([^%.]*)%.(.+)$")
    if ver == LOCK_VALUE_VERSION then
        local reason = b64url_decode(reason_enc)
        if not reason or reason == "" then
            reason = tostring(reason_enc or "challenge")
        end
        if not cont or cont == "" then
            cont = encode_continue_target("/")
        end
        return {
            issued = tonumber(issued) or 0,
            continue_raw = cont,
            reason = tostring(reason)
        }
    end

    -- backward-compatible parsing for legacy plain reason string
    return {
        issued = 0,
        continue_raw = encode_continue_target("/"),
        reason = s
    }
end

local function decode_continue_target(raw)
    local decoded = b64url_decode(raw)
    if not decoded and ngx and ngx.decode_base64 then
        decoded = ngx.decode_base64(tostring(raw or ""))
    end
    decoded = tostring(decoded or "/")

    if decoded == "" then
        return "/"
    end
    if decoded:sub(1, 1) ~= "/" or decoded:sub(1, 2) == "//" then
        return "/"
    end
    if decoded:find("[\r\n]") then
        return "/"
    end
    return decoded
end

local function build_challenge_redirect(ctx)
    local cont = encode_continue_target((ctx and ctx.request_uri) or "/")
    local p = tostring((challenge_cfg().continue_param) or "continue")
    local page_uri = route_page()
    local qv = ngx and ngx.escape_uri and ngx.escape_uri(cont) or cont
    return page_uri .. "?" .. p .. "=" .. qv
end

challenge_lock_info = function(ctx)
    local dict = shared_dict()
    if not dict then
        return nil
    end
    local raw = dict:get(lock_key(ctx))
    if not raw then
        return nil
    end
    return decode_lock_value(raw)
end

local function challenge_required(ctx)
    return challenge_lock_info(ctx) ~= nil
end

local function set_challenge_lock(ctx, reason)
    local dict = shared_dict()
    if not dict then
        warn_once("challenge_dict", "[waf] lua_shared_dict waf_challenge not found")
        return false
    end
    local continue_raw = encode_continue_target((ctx and ctx.request_uri) or "/")
    local value = encode_lock_value(reason, continue_raw, now_epoch())
    local ok, err = dict:set(lock_key(ctx), value, lock_ttl())
    if not ok then
        Logger.warn("[waf] challenge lock set failed err=", err or "unknown")
        return false
    end
    clear_pass_cookie()
    return true
end

local function clear_challenge_lock(ctx)
    local dict = shared_dict()
    if not dict then
        return
    end
    dict:delete(lock_key(ctx))
end

local function random_nonce(seed)
    seed_rng_once()
    seed = tostring(seed or "")
    local now = tostring((ngx and ngx.now and ngx.now()) or os.time())
    local rid = tostring((ngx and ngx.var and ngx.var.request_id) or "")
    local pid = tostring((ngx and ngx.worker and ngx.worker.pid and ngx.worker.pid()) or "")
    local src = table.concat({ seed, now, rid, pid, tostring(math.random()) }, "|")
    if ngx and ngx.md5 then
        return ngx.md5(src)
    end
    return src:gsub("[^%w]", "")
end

local function random_code(len)
    seed_rng_once()
    local chars = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
    len = tonumber(len) or tonumber(C.defaults and C.defaults.challenge_native_code_len) or 5
    local out = {}
    for i = 1, len do
        local idx = math.random(1, #chars)
        out[i] = chars:sub(idx, idx)
    end
    return table.concat(out)
end

local function native_code_key(nonce)
    return "native:" .. tostring(nonce or "")
end

local function store_native_code(ctx, nonce, code)
    local dict = shared_dict()
    if not dict then
        return false
    end
    local ttl = tonumber(challenge_cfg().native and challenge_cfg().native.code_ttl)
        or tonumber(C.defaults and C.defaults.challenge_native_code_ttl)
        or 300
    local value = binding_value(ctx) .. "|" .. tostring(code or "")
    local ok, err = dict:set(native_code_key(nonce), value, ttl)
    if not ok then
        Logger.warn("[waf] native code set failed err=", err or "unknown")
        return false
    end
    return true
end

local function check_native_code(ctx, nonce, code)
    local dict = shared_dict()
    if not dict then
        return false, "storage_unavailable"
    end
    local key = native_code_key(nonce)
    local raw = dict:get(key)
    dict:delete(key)
    if not raw then
        return false, "challenge_expired"
    end

    local bind, expected = tostring(raw):match("^([^|]+)|(.+)$")
    if not bind or not expected then
        return false, "challenge_invalid"
    end
    if bind ~= binding_value(ctx) then
        return false, "challenge_binding_mismatch"
    end

    local got = string.upper(tostring(code or ""))
    if string.upper(tostring(expected)) ~= got then
        return false, "challenge_code_wrong"
    end
    return true
end

local function effective_provider()
    local cfg = challenge_cfg()
    local provider = string.lower(tostring(cfg.provider or "native"))
    if provider == "turnstile" then
        local tcfg = cfg.turnstile or {}
        local site = tostring(tcfg.site_key or "")
        local secret = tostring(tcfg.secret_key or "")
        if site ~= "" and secret ~= "" then
            return "turnstile"
        end
        warn_once("turnstile_config", "[waf] turnstile keys missing, fallback to native challenge")
    end
    return "native"
end

local function verify_turnstile(token, ctx)
    if not token or token == "" then
        return false, "missing_token"
    end

    local tcfg = challenge_cfg().turnstile or {}
    local ok_http, http_mod = pcall(require, "resty.http")
    if not ok_http or not http_mod then
        warn_once("turnstile_http", "[waf] resty.http missing, cannot verify turnstile token")
        return false, "http_client_missing"
    end

    local client = http_mod.new()
    local timeout = tonumber(tcfg.timeout_ms) or tonumber(C.defaults and C.defaults.challenge_verify_timeout_ms) or 3000
    client:set_timeout(timeout)

    local body = ngx.encode_args({
        secret = tostring(tcfg.secret_key or ""),
        response = token,
        remoteip = tostring((ctx and ctx.client_ip) or "")
    })

    local url = tostring(tcfg.verify_url or (C.defaults and C.defaults.challenge_turnstile_verify_url) or "")
    local res, err = client:request_uri(url, {
        method = "POST",
        body = body,
        headers = {
            ["Content-Type"] = "application/x-www-form-urlencoded"
        },
        ssl_verify = true
    })
    if not res then
        return false, "http_error:" .. tostring(err or "unknown")
    end
    if res.status ~= 200 then
        return false, "http_status:" .. tostring(res.status)
    end

    if not cjson or not cjson.decode then
        return false, "json_decoder_missing"
    end

    local decoded = cjson.decode(res.body or "{}")
    if type(decoded) ~= "table" then
        return false, "invalid_json"
    end
    if decoded.success == true then
        return true
    end

    local codes = decoded["error-codes"]
    if type(codes) == "table" then
        return false, table.concat(codes, ",")
    end
    return false, "turnstile_failed"
end

local function render_page(ctx, provider, continue_raw, err_msg)
    continue_raw = tostring(continue_raw or encode_continue_target("/"))
    local verify_uri = html_escape(route_verify())
    local continue_param = html_escape(tostring(challenge_cfg().continue_param or "continue"))
    local title = "Verification Required"
    local err_block = ""
    if err_msg and err_msg ~= "" then
        err_block = '<div class="err">Verification failed. Please try again.</div>'
    end

    local common_head = [[
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>]] .. title .. [[</title>
  <style>
    * { box-sizing: border-box; }
    body {
      margin: 0;
      min-height: 100vh;
      display: grid;
      place-items: center;
      padding: 20px;
      color: #e5e7eb;
      font: 16px/1.6 "Source Sans 3","Noto Sans SC","Microsoft YaHei",sans-serif;
      background: radial-gradient(1000px 500px at 10% -10%, rgba(56,189,248,.15), transparent 60%),
                  linear-gradient(140deg, #0b1020, #111827);
    }
    .card {
      width: min(620px, 100%);
      background: rgba(17,24,39,.82);
      border: 1px solid rgba(148,163,184,.28);
      border-radius: 16px;
      padding: 22px;
      box-shadow: 0 16px 50px rgba(2,6,23,.45);
    }
    h1 { margin: 0 0 8px; font-size: 30px; line-height: 1.15; }
    p { margin: 0; color: #cbd5e1; }
    .form { margin-top: 16px; }
    .row { margin-top: 12px; }
    .btn {
      margin-top: 14px;
      border: 0;
      border-radius: 10px;
      background: linear-gradient(135deg, #38bdf8, #f8fafc);
      color: #0f172a;
      font-weight: 700;
      padding: 10px 16px;
      cursor: pointer;
    }
    .err {
      margin-top: 12px;
      border: 1px solid rgba(251,113,133,.42);
      border-radius: 10px;
      background: rgba(251,113,133,.13);
      color: #fecdd3;
      padding: 8px 10px;
      font-size: 14px;
    }
    .code {
      margin-top: 10px;
      display: inline-block;
      font: 700 30px/1.2 "Space Grotesk","Consolas",monospace;
      letter-spacing: .18em;
      color: #f8fafc;
      background: rgba(2,132,199,.22);
      padding: 8px 12px;
      border-radius: 10px;
      border: 1px solid rgba(56,189,248,.35);
      user-select: none;
    }
    input[type="text"] {
      width: min(240px, 100%);
      border: 1px solid rgba(148,163,184,.35);
      border-radius: 10px;
      background: rgba(15,23,42,.58);
      color: #e5e7eb;
      padding: 9px 10px;
    }
  </style>
</head>
<body>
  <main class="card">
    <h1>Verification Required</h1>
    <p>Suspicious traffic was detected. Complete the challenge to continue.</p>
    ]] .. err_block

    if provider == "turnstile" then
        local site_key = html_escape(tostring(((challenge_cfg().turnstile or {}).site_key) or ""))
        return common_head .. [[
    <form class="form" method="post" action="]] .. verify_uri .. [[">
      <input type="hidden" name="]] .. continue_param .. [[" value="]] .. html_escape(continue_raw) .. [[">
      <div class="row">
        <div class="cf-turnstile" data-sitekey="]] .. site_key .. [["></div>
      </div>
      <button class="btn" type="submit">Continue</button>
    </form>
    <script src="https://challenges.cloudflare.com/turnstile/v0/api.js" async defer></script>
  </main>
</body>
</html>]]
    end

    local nonce = random_nonce(continue_raw)
    local code = random_code((challenge_cfg().native or {}).code_len)
    local stored = store_native_code(ctx, nonce, code)
    if not stored then
        warn_once("native_store", "[waf] native challenge unavailable: cannot store code in waf_challenge")
        return common_head .. [[
    <div class="err">Challenge service is temporarily unavailable. Please retry later.</div>
  </main>
</body>
</html>]]
    end
    local native_code = html_escape(code)
    local native_nonce = html_escape(nonce)

    return common_head .. [[
    <form class="form" method="post" action="]] .. verify_uri .. [[">
      <input type="hidden" name="]] .. continue_param .. [[" value="]] .. html_escape(continue_raw) .. [[">
      <input type="hidden" name="native_nonce" value="]] .. native_nonce .. [[">
      <div class="row">Enter this code:</div>
      <div class="code">]] .. native_code .. [[</div>
      <div class="row">
        <input type="text" name="native_code" maxlength="12" autocomplete="off" placeholder="Type code here">
      </div>
      <button class="btn" type="submit">Continue</button>
    </form>
  </main>
</body>
</html>]]
end

local function page_continue_raw(ctx)
    local param = tostring(challenge_cfg().continue_param or "continue")
    local arg = (ngx and ngx.var and ngx.var["arg_" .. param]) or nil
    if arg and arg ~= "" then
        return arg
    end
    local info = challenge_lock_info(ctx)
    if info and info.continue_raw and info.continue_raw ~= "" then
        return info.continue_raw
    end
    return encode_continue_target("/")
end

local function handle_challenge_page(ctx, err_msg, continue_raw_override)
    ngx.status = 200
    ngx.header.content_type = "text/html; charset=utf-8"
    ngx.header["Cache-Control"] = "no-store, no-cache, must-revalidate, max-age=0"
    ngx.header["Pragma"] = "no-cache"
    ngx.header["Expires"] = "0"
    local continue_raw = continue_raw_override or page_continue_raw(ctx)
    ngx.say(render_page(ctx, effective_provider(), continue_raw, err_msg))
    return ngx.exit(200)
end

local function handle_verify(ctx)
    if string.upper(tostring((ctx and ctx.method) or "")) ~= "POST" then
        return handle_challenge_page(ctx, "method_not_allowed")
    end

    local args = ctx:post_args(C.parse.post_arg_limit)
    if type(args) ~= "table" then
        args = {}
    end

    local continue_param = tostring(challenge_cfg().continue_param or "continue")
    local continue_raw = first_value(args[continue_param]) or page_continue_raw(ctx)
    local continue_target = decode_continue_target(continue_raw)
    if continue_target == route_page() or continue_target == route_verify() then
        continue_target = "/"
    end

    local provider = effective_provider()
    local ok, err
    if provider == "turnstile" then
        local token = first_value(args["cf-turnstile-response"]) or first_value(args.token)
        ok, err = verify_turnstile(token, ctx)
    else
        local nonce = first_value(args.native_nonce)
        local code = first_value(args.native_code)
        ok, err = check_native_code(ctx, nonce, string.upper(tostring(code or "")))
    end

    if ok then
        clear_challenge_lock(ctx)
        issue_pass_cookie(ctx)
        local redirect_ok, redirect_err = ngx.redirect(continue_target, ngx.HTTP_MOVED_TEMPORARILY)
        if not redirect_ok then
            Logger.warn("[waf] challenge verify redirect failed err=", tostring(redirect_err))
            return handle_challenge_page(ctx, "redirect_failed", continue_raw)
        end
        return redirect_ok
    end

    return handle_challenge_page(ctx, err or "verify_failed", continue_raw)
end

function Challenge.available()
    local cfg = challenge_cfg()
    if not U.bool(cfg.enabled) then
        return false
    end

    if not shared_dict() then
        warn_once("challenge_dict", "[waf] lua_shared_dict waf_challenge not found")
        return false
    end

    if not get_secret() then
        warn_once("challenge_secret", "[waf] challenge secret is empty or default placeholder")
        return false
    end

    return true
end

function Challenge.flag(ctx, reason)
    if not Challenge.available() then
        return false
    end
    return set_challenge_lock(ctx, reason)
end

function Challenge.handle_request(ctx)
    if not U.bool(challenge_cfg().enabled) then
        return false
    end
    if not Challenge.available() then
        return false
    end

    local path = page_path_from_uri((ctx and ctx.request_uri) or "")
    if path == route_page() then
        handle_challenge_page(ctx)
        return true
    end
    if path == route_verify() then
        handle_verify(ctx)
        return true
    end
    return false
end

function Challenge.enforce(ctx)
    if not U.bool(challenge_cfg().enabled) then
        return false
    end
    if not Challenge.available() then
        return false
    end

    local path = page_path_from_uri((ctx and ctx.request_uri) or "")
    if path == route_page() or path == route_verify() then
        return false
    end

    if challenge_required(ctx) then
        if has_valid_pass(ctx) then
            clear_challenge_lock(ctx)
            return false
        end
        local ok, err = ngx.redirect(build_challenge_redirect(ctx), ngx.HTTP_MOVED_TEMPORARILY)
        if not ok then
            Logger.warn("[waf] challenge redirect failed err=", tostring(err))
            return false
        end
        return true
    end
    return false
end

return Challenge

local C = require "config"
local U = require "util"
local Rules = require "rules"
local Logger = require "logger"
local Challenge = require "challenge"

local bit = _G.bit or _G.bit32
if not bit then
    local ok, mod = pcall(require, "bit")
    if ok and mod then
        bit = mod
    else
        ok, mod = pcall(require, "bit32")
        if ok and mod then
            bit = mod
        end
    end
end
if not bit then
    error("waf/checks.lua: bit library not found (need bit or bit32)")
end

local Checks = {}

local function match_one(subject, rule)
    if not subject or subject == "" or not rule or rule == "" then
        return false
    end
    local from, _, err = ngx.re.find(subject, rule, "ijo")
    if err then
        Logger.warn("[waf] regex error rule=", rule, " err=", err)
        return false
    end
    return from ~= nil
end

local function match_rule(subject, rules)
    if not subject or subject == "" then
        return nil
    end
    for _, rule in ipairs(rules or {}) do
        if match_one(subject, rule) then
            return rule
        end
    end
    return nil
end

local function parse_ipv4(ip)
    local a, b, c, d = tostring(ip or ""):match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then
        return nil
    end
    a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
    if not a or not b or not c or not d then
        return nil
    end
    if a > 255 or b > 255 or c > 255 or d > 255 then
        return nil
    end
    return a, b, c, d
end

local function ipv4_to_u32(ip)
    local a, b, c, d = parse_ipv4(ip)
    if not a then
        return nil
    end
    return bit.bor(
        bit.lshift(a, 24),
        bit.lshift(b, 16),
        bit.lshift(c, 8),
        d
    )
end

local function cidr_match_ipv4(ip, cidr)
    local net_ip, prefix = tostring(cidr or ""):match("^([%d%.]+)/(%d+)$")
    if not net_ip then
        return false
    end
    prefix = tonumber(prefix)
    if not prefix or prefix < 0 or prefix > 32 then
        return false
    end

    local ip_u = ipv4_to_u32(ip)
    local net_u = ipv4_to_u32(net_ip)
    if not ip_u or not net_u then
        return false
    end

    local mask
    if prefix == 0 then
        mask = 0
    else
        mask = bit.lshift(0xffffffff, 32 - prefix)
    end
    return bit.band(ip_u, mask) == bit.band(net_u, mask)
end

local function is_ipv4_literal(rule)
    local a = parse_ipv4(rule)
    return a ~= nil
end

local function ip_match(ip, rule)
    if not ip or ip == "" or not rule or rule == "" then
        return false
    end
    if tostring(rule):find("/", 1, true) then
        return cidr_match_ipv4(ip, rule)
    end
    if is_ipv4_literal(rule) then
        return tostring(ip) == tostring(rule)
    end
    return match_one(ip, rule)
end

local function allow(event, rule, detail, ctx)
    return {
        decision = "allow",
        event = event,
        rule = rule or "-",
        detail = detail or "-",
        client_ip = (ctx and ctx.client_ip) or "-"
    }
end

local function deny(event, rule, detail, responder, ctx)
    return {
        decision = "deny",
        event = event,
        rule = rule or "-",
        detail = detail or "-",
        client_ip = (ctx and ctx.client_ip) or "-",
        responder = responder or "default"
    }
end

function Checks.black_ip(ctx)
    if not C.switch.black_ip then
        return nil
    end
    local ip = ctx.client_ip or ""
    for _, rule in ipairs(Rules.get("black_ip")) do
        if ip_match(ip, rule) then
            return deny("Black_IP", rule, ip, "default", ctx)
        end
    end
    return nil
end

function Checks.white_ip(ctx)
    if not C.switch.white_ip then
        return nil
    end
    local ip = ctx.client_ip or ""
    for _, rule in ipairs(Rules.get("white_ip")) do
        if ip_match(ip, rule) then
            return allow("White_IP", rule, ip, ctx)
        end
    end
    return nil
end

function Checks.white_url(ctx)
    if not C.switch.white_url then
        return nil
    end

    local uri = U.lower(ctx.uri)
    local req_uri = U.lower(ctx.request_uri)
    if req_uri and req_uri:find("?", 1, true) then
        return nil
    end
    local req_uri_unescaped = U.lower(U.safe_unescape(req_uri))
    local rules = Rules.get("white_url")

    local rule = match_rule(uri, rules) or match_rule(req_uri, rules) or match_rule(req_uri_unescaped, rules)
    if rule then
        return allow("White_URL", rule, uri, ctx)
    end
    return nil
end

function Checks.user_agent(ctx)
    if not C.switch.user_agent then
        return nil
    end

    local ua = U.lower(ctx.user_agent)
    local rule = match_rule(ua, Rules.get("tencent_useragent"))
    if rule then
        return deny("Deny_User_Agent", rule, ua, "wechat", ctx)
    end

    rule = match_rule(ua, Rules.get("useragent"))
    if rule then
        return deny("Deny_User_Agent", rule, ua, "default", ctx)
    end
    return nil
end

local function cc_counter(dict, key, seconds)
    local new, err = dict:incr(key, 1, 0, seconds)
    if new then
        return new
    end

    local current = dict:get(key)
    if current then
        new, err = dict:incr(key, 1)
        if new then
            return new
        end
    else
        dict:set(key, 1, seconds)
        return 1
    end

    Logger.warn("[waf] cc counter incr failed key=", key, " err=", err or "unknown")
    return tonumber(dict:get(key) or 0)
end

function Checks.cc(ctx)
    if not C.switch.cc then
        return nil
    end

    if not (ngx and ngx.shared and ngx.shared.limit) then
        Logger.warn("[waf] lua_shared_dict limit not found, skip cc")
        return nil
    end
    if not (ngx and ngx.md5) then
        Logger.warn("[waf] ngx.md5 not found, skip cc")
        return nil
    end

    local dict = ngx.shared.limit
    local cc_count, cc_seconds = U.parse_rate(
        C.cc.rate,
        C.cc.default_count or (C.defaults and C.defaults.cc_rate_count),
        C.cc.default_seconds or (C.defaults and C.defaults.cc_rate_seconds)
    )
    local token_src = U.lower((ctx.host or "") .. (ctx.uri or "")) .. "|" .. (ctx.user_agent or "")
    local token = (ctx.client_ip or "-") .. "." .. ngx.md5(token_src)
    local count = cc_counter(dict, token, cc_seconds)
    if count > cc_count then
        dict:set(token, math.max(1, math.floor(cc_count / 2)), cc_seconds)
        local cc_action = tostring(C.cc.action or "forbidden")
        if cc_action == "captcha" then
            if not Challenge.available() then
                Logger.warn("[waf] challenge unavailable, fallback to direct deny for cc")
                return deny("CC_Attack", token, "count=" .. tostring(count), "default", ctx)
            end
            local flagged = Challenge.flag(ctx, "cc")
            if not flagged then
                Logger.warn("[waf] challenge flag failed, fallback to direct deny for cc")
                return deny("CC_Attack", token, "count=" .. tostring(count), "default", ctx)
            end
        end
        return deny("CC_Attack", token, "count=" .. tostring(count), "cc", ctx)
    end
    return nil
end

function Checks.cookie(ctx)
    if not C.switch.cookie then
        return nil
    end

    local data = U.lower(ctx.cookie)
    if not data or data == "" then
        return nil
    end

    local rule = match_rule(data, Rules.get("cookie"))
    if rule then
        return deny("Deny_Cookie", rule, data, "default", ctx)
    end
    return nil
end

function Checks.url(ctx)
    if not C.switch.url then
        return nil
    end

    local uri = U.lower(ctx.request_uri)
    local rule = match_rule(uri, Rules.get("black_url"))
    if rule then
        return deny("Deny_URL", rule, uri, "default", ctx)
    end
    return nil
end

function Checks.url_args(ctx)
    if not C.switch.url_args then
        return nil
    end

    local args, err = ctx:uri_args(C.parse.request_arg_limit)
    if err == "truncated" and C.parse.block_on_truncated_args then
        return deny("Deny_URL_Args_Truncated", "truncated", "uri args truncated", "default", ctx)
    end
    if type(args) ~= "table" then
        return nil
    end

    local rules = Rules.get("args")
    for _, rule in ipairs(rules) do
        for _, val in pairs(args) do
            local data = U.normalize_value(val)
            if data and match_one(U.safe_unescape(data), rule) then
                return deny("Deny_URL_Args", rule, data, "default", ctx)
            end
        end
    end

    return nil
end

function Checks.post(ctx)
    if not C.switch.post then
        return nil
    end

    local method = ctx.method or ""
    local post_methods = C.parse.post_methods or (C.defaults and C.defaults.post_methods) or {}
    if not U.in_list(method, post_methods) then
        return nil
    end

    local rules = Rules.get("post")
    local post, err = ctx:post_args(C.parse.post_arg_limit)
    if err == "truncated" and C.parse.block_on_truncated_post then
        return deny("Deny_POST_Truncated", "truncated", "post args truncated", "default", ctx)
    end

    if type(post) == "table" then
        for _, rule in ipairs(rules) do
            for _, val in pairs(post) do
                local data = U.normalize_value(val)
                if data and match_one(U.safe_unescape(data), rule) then
                    return deny("Deny_POST", rule, data, "default", ctx)
                end
            end
        end
    end

    local body = U.lower(ctx:body_preview(C.parse.max_body_inspect_bytes))
    if body and body ~= "" then
        local rule = match_rule(body, rules)
        if rule then
            local detail_max = C.parse.hit_detail_max_len or C.log.detail_max_len or (C.defaults and C.defaults.hit_detail_max_len)
            return deny("Deny_POST_Body", rule, U.safe_slice(body, detail_max), "default", ctx)
        end
    end

    return nil
end

function Checks.run_ordered(ctx)
    if type(ctx) ~= "table" then
        return nil
    end

    local order = C.pipeline
    if type(order) ~= "table" then
        order = C.pipeline_default or {}
    end

    for _, step in ipairs(order) do
        local fn = Checks[step]
        if type(fn) ~= "function" then
            Logger.warn("[waf] unknown pipeline step: ", tostring(step))
        else
            local res = fn(ctx)
            if res then
                return res
            end
        end
    end
    return nil
end

return Checks

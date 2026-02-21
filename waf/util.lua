local U = {}
local cached_slice_len = nil
local cached_defaults = nil

local function load_defaults()
    if cached_defaults ~= nil then
        return cached_defaults
    end
    local ok, cfg = pcall(require, "config")
    if ok and cfg and cfg.defaults then
        cached_defaults = cfg.defaults
    else
        cached_defaults = false
    end
    return cached_defaults
end

local function default_slice_len()
    if cached_slice_len then
        return cached_slice_len
    end
    local defaults = load_defaults()
    if defaults and defaults.hit_detail_max_len then
        cached_slice_len = tonumber(defaults.hit_detail_max_len)
    end
    cached_slice_len = cached_slice_len or 256
    return cached_slice_len
end

function U.trim(v)
    if v == nil then
        return nil
    end
    return (tostring(v):gsub("^%s+", ""):gsub("%s+$", ""))
end

function U.lower(v)
    if v == nil then
        return nil
    end
    return string.lower(tostring(v))
end

function U.first_ip_from_xff(v)
    if v == nil then
        return nil
    end
    local first = tostring(v):match("^%s*([^,]+)")
    return U.trim(first)
end

function U.safe_unescape(v)
    if v == nil then
        return nil
    end
    if ngx and ngx.unescape_uri then
        local ok, out = pcall(ngx.unescape_uri, tostring(v))
        if ok then
            return out
        end
    end
    return tostring(v)
end

function U.normalize_value(v)
    if type(v) == "table" then
        return U.lower(table.concat(v, " "))
    elseif type(v) == "boolean" then
        return nil
    end
    return U.lower(v)
end

function U.parse_rate(v, default_count, default_seconds)
    local defaults = load_defaults()
    local cfg_default_count = defaults and defaults.cc_rate_count
    local cfg_default_seconds = defaults and defaults.cc_rate_seconds
    default_count = tonumber(default_count) or tonumber(cfg_default_count) or 60
    default_seconds = tonumber(default_seconds) or tonumber(cfg_default_seconds) or 60

    if type(v) == "table" then
        local c = tonumber(v.count) or default_count
        local s = tonumber(v.seconds) or default_seconds
        return c, s
    end

    local count, seconds = tostring(v or ""):match("^%s*(%d+)%s*/%s*(%d+)%s*$")
    return tonumber(count) or default_count, tonumber(seconds) or default_seconds
end

function U.now()
    if ngx and ngx.now then
        return ngx.now()
    end
    return os.time()
end

function U.bool(v)
    if type(v) == "boolean" then
        return v
    end
    local s = U.lower(v)
    return s == "on" or s == "true" or s == "1" or s == "yes"
end

function U.in_list(value, list)
    for _, item in ipairs(list) do
        if value == item then
            return true
        end
    end
    return false
end

function U.safe_slice(v, max_len)
    max_len = tonumber(max_len) or default_slice_len()
    local s = tostring(v or "")
    if #s <= max_len then
        return s
    end
    return s:sub(1, max_len) .. "...(truncated)"
end

return U

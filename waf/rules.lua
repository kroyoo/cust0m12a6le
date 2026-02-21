local C = require "config"
local U = require "util"
local Logger = require "logger"

local Rules = {}

local CACHE = {}

local function validate_rule(rule)
    local _, _, err = ngx.re.find("", rule, "jo")
    return err == nil, err
end

local function parse_rule_file(path)
    local fh, err = io.open(path, "r")
    if not fh then
        Logger.warn("[waf] cannot open rule file: ", path, " err=", err)
        return {}
    end

    local rules = {}
    for line in fh:lines() do
        local v = U.trim(line)
        if v and v ~= "" and not v:match("^#") then
            local ok, why = validate_rule(v)
            if ok then
                rules[#rules + 1] = v
            else
                Logger.warn("[waf] invalid rule skipped file=", path, " rule=", v, " err=", why or "unknown")
            end
        end
    end
    fh:close()
    return rules
end

local function cache_get(name)
    local ttl = tonumber(C.cache.rule_ttl)
    if not ttl or ttl <= 0 then
        return nil
    end
    local item = CACHE[name]
    if item and (U.now() - item.ts) < ttl then
        return item.rules
    end
    return nil
end

local function cache_set(name, rules)
    CACHE[name] = {
        ts = U.now(),
        rules = rules or {}
    }
end

function Rules.get(name)
    local cached = cache_get(name)
    if cached then
        return cached
    end

    local file = C.rule_files[name] or name
    local path = C.paths.rule_dir .. "/" .. file
    local rules = parse_rule_file(path)
    cache_set(name, rules)
    return rules
end

function Rules.preload()
    for name, _ in pairs(C.rule_files) do
        Rules.get(name)
    end
end

function Rules.invalidate(name)
    if name then
        CACHE[name] = nil
        return
    end
    CACHE = {}
end

return Rules

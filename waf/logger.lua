local C = require "config"
local U = require "util"

local Logger = {}

local cjson = nil
do
    local ok, mod = pcall(require, "cjson.safe")
    if ok and mod and mod.encode then
        cjson = mod
    else
        ok, mod = pcall(require, "cjson")
        if ok and mod and mod.encode then
            cjson = mod
        end
    end
end

local function ngx_log(level, ...)
    if ngx and ngx.log then
        ngx.log(level or ngx.WARN, ...)
    end
end

local function now_localtime()
    if ngx and ngx.localtime then
        return ngx.localtime()
    end
    return os.date("%Y-%m-%d %H:%M:%S")
end

local function day_stamp()
    if ngx and ngx.today then
        return ngx.today()
    end
    return os.date("%Y-%m-%d")
end

local function var_or_dash(ctx, key, ngx_name)
    if ctx and ctx[key] and ctx[key] ~= "" then
        return tostring(ctx[key])
    end
    if ngx and ngx.var and ngx.var[ngx_name] and ngx.var[ngx_name] ~= "" then
        return tostring(ngx.var[ngx_name])
    end
    return "-"
end

local function json_escape(v)
    local s = tostring(v or "")
    s = s:gsub("\\", "\\\\")
    s = s:gsub("\"", "\\\"")
    s = s:gsub("\r", "\\r")
    s = s:gsub("\n", "\\n")
    return s
end

local function encode_json(obj)
    if cjson and cjson.encode then
        local ok, line = pcall(cjson.encode, obj)
        if ok and line then
            return line
        end
    end

    return string.format(
        "{\"time\":\"%s\",\"event\":\"%s\",\"decision\":\"%s\",\"rule\":\"%s\",\"client_ip\":\"%s\",\"method\":\"%s\",\"uri\":\"%s\",\"host\":\"%s\",\"request_id\":\"%s\",\"detail\":\"%s\"}",
        json_escape(obj.time),
        json_escape(obj.event),
        json_escape(obj.decision),
        json_escape(obj.rule),
        json_escape(obj.client_ip),
        json_escape(obj.method),
        json_escape(obj.uri),
        json_escape(obj.host),
        json_escape(obj.request_id),
        json_escape(obj.detail)
    )
end

local QUEUE = {}
local DROPPED = 0
local TIMER_PENDING = false

local function queue_size()
    return #QUEUE
end

local function log_path()
    local log_dir = C.paths.log_dir or C.paths.fallback_log_dir
    return log_dir .. "/" .. day_stamp() .. "_sec.log"
end

local function max_queue_lines()
    return tonumber(C.log.max_queue_lines) or 5000
end

local function batch_lines()
    return tonumber(C.log.batch_lines) or 128
end

local function flush_interval()
    return tonumber(C.log.flush_interval) or 0.2
end

local function drop_policy()
    local p = tostring(C.log.drop_policy or "drop_oldest")
    if p == "drop_newest" then
        return p
    end
    return "drop_oldest"
end

local function enqueue_line(line)
    local max_lines = max_queue_lines()
    if queue_size() >= max_lines then
        if drop_policy() == "drop_newest" then
            DROPPED = DROPPED + 1
            return false
        end

        table.remove(QUEUE, 1)
        DROPPED = DROPPED + 1
    end

    QUEUE[#QUEUE + 1] = line
    return true
end

local function take_queue_snapshot()
    if queue_size() == 0 then
        return nil, 0
    end
    local lines = QUEUE
    local dropped = DROPPED

    QUEUE = {}
    DROPPED = 0
    return lines, dropped
end

local function write_batch(lines, dropped)
    local path = log_path()
    local fh, err = io.open(path, "a")
    if fh == nil then
        ngx_log(ngx.WARN, "[waf] log open failed: ", path, " err=", err)
        return false
    end

    local payload
    if dropped > 0 then
        local dropped_line = encode_json({
            time = now_localtime(),
            event = "Log_Dropped",
            decision = "info",
            rule = "-",
            client_ip = "-",
            method = "-",
            uri = "-",
            host = "-",
            request_id = "-",
            detail = "dropped=" .. tostring(dropped) .. " queue=" .. tostring(max_queue_lines())
        })
        lines[#lines + 1] = dropped_line
    end
    payload = table.concat(lines, "\n") .. "\n"

    local ok, werr = fh:write(payload)
    if not ok then
        fh:close()
        ngx_log(ngx.WARN, "[waf] log write failed: ", path, " err=", werr)
        return false
    end
    fh:close()
    return true
end

local function flush_sync_once()
    local lines, dropped = take_queue_snapshot()
    if not lines then
        return
    end
    write_batch(lines, dropped)
end

local function flush_timer(premature)
    TIMER_PENDING = false
    if premature then
        return
    end

    flush_sync_once()

    if queue_size() > 0 then
        local ok, err = ngx.timer.at(0, flush_timer)
        if ok then
            TIMER_PENDING = true
        else
            ngx_log(ngx.WARN, "[waf] log timer schedule failed: ", err)
            flush_sync_once()
        end
    end
end

local function schedule_flush(delay)
    if TIMER_PENDING then
        return
    end

    if not (ngx and ngx.timer and ngx.timer.at) then
        flush_sync_once()
        return
    end

    local ok, err = ngx.timer.at(delay, flush_timer)
    if ok then
        TIMER_PENDING = true
        return
    end

    ngx_log(ngx.WARN, "[waf] log timer schedule failed: ", err)
    flush_sync_once()
end

function Logger.security(event, ctx)
    local log_mode = tostring(C.log.mode or "file")
    if log_mode == "off" then
        return
    end

    local data = {
        time = now_localtime(),
        event = event.event or "-",
        decision = event.decision or "-",
        rule = event.rule or "-",
        detail = U.safe_slice(event.detail or "-", C.log.detail_max_len or (C.defaults and C.defaults.hit_detail_max_len)),
        client_ip = event.client_ip or var_or_dash(ctx, "client_ip", "remote_addr"),
        method = var_or_dash(ctx, "method", "request_method"),
        uri = var_or_dash(ctx, "request_uri", "request_uri"),
        host = var_or_dash(ctx, "host", "host"),
        request_id = var_or_dash(ctx, "request_id", "request_id")
    }
    local line = encode_json(data)

    if log_mode == "error" then
        ngx_log(ngx.WARN, "[waf] ", line)
        return
    end

    if C.log.async == false then
        local ok = write_batch({ line }, 0)
        if not ok then
            ngx_log(ngx.WARN, "[waf] sync log write dropped")
        end
        return
    end

    enqueue_line(line)
    if queue_size() >= batch_lines() then
        schedule_flush(0)
    else
        schedule_flush(flush_interval())
    end
end

function Logger.warn(...)
    ngx_log(ngx.WARN, ...)
end

function Logger.err(...)
    ngx_log(ngx.ERR, ...)
end

return Logger

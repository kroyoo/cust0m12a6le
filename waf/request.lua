local C = require "config"
local U = require "util"

local Request = {}

local function ngx_var(name)
    if ngx and ngx.var then
        return ngx.var[name]
    end
    return nil
end

local function get_headers()
    if not (ngx and ngx.req and ngx.req.get_headers) then
        return {}
    end
    local limit = tonumber(C.parse.header_limit) or C.defaults.header_limit
    local raw = C.parse.raw_headers
    if raw == nil then
        raw = C.parse.include_underscored_headers
    end
    raw = U.bool(raw)
    local ok, headers = pcall(ngx.req.get_headers, limit, raw)
    if ok and type(headers) == "table" then
        return headers
    end
    return {}
end

local function header_first(v)
    if type(v) == "table" then
        for _, item in ipairs(v) do
            local s = tostring(item or "")
            if s ~= "" then
                return s
            end
        end
        return nil
    end
    local s = tostring(v or "")
    if s == "" then
        return nil
    end
    return s
end

local function detect_client_ip(headers)
    local remote_addr = ngx_var("remote_addr")
    if not C.trust.forwarded_ip then
        return remote_addr
    end

    local xff = header_first(headers["x-forwarded-for"]) or header_first(headers["X-Forwarded-For"])
    local first = U.first_ip_from_xff(xff)
    if first and first ~= "" then
        return first
    end

    local xri = header_first(headers["x-real-ip"]) or header_first(headers["X-Real-IP"])
    if xri and xri ~= "" then
        return tostring(xri)
    end

    return remote_addr
end

local function read_body_once(ctx)
    if ctx._body_read then
        return
    end
    ctx._body_read = true

    if ngx and ngx.req and ngx.req.read_body then
        pcall(ngx.req.read_body)
    end
end

local function read_body_file(path, max_len)
    if not path or path == "" then
        return nil
    end

    local fh, err = io.open(path, "rb")
    if not fh then
        return nil, err
    end

    local read_len = tonumber(max_len) or tonumber(C.parse.max_body_inspect_bytes) or tonumber(C.defaults.max_body_inspect_bytes)
    local data = fh:read(read_len)
    fh:close()
    return data
end

local function get_body_data(ctx)
    if ctx._body_data_loaded then
        return ctx._body_data
    end
    ctx._body_data_loaded = true

    read_body_once(ctx)
    if not (ngx and ngx.req and ngx.req.get_body_data) then
        return nil
    end
    local ok, body = pcall(ngx.req.get_body_data)
    if ok then
        ctx._body_data = body
    end
    return ctx._body_data
end

function Request.new()
    local headers = get_headers()
    local method = tostring(ngx_var("request_method") or "")
    if method == "" and ngx and ngx.req and ngx.req.get_method then
        local ok, value = pcall(ngx.req.get_method)
        if ok and value then
            method = tostring(value)
        end
    end
    local uri = tostring(ngx_var("uri") or "")
    local request_uri = tostring(ngx_var("request_uri") or "")
    if request_uri == "" then
        request_uri = uri
    end

    local ctx = {
        headers = headers,
        client_ip = detect_client_ip(headers) or "-",
        user_agent = tostring(header_first(headers["user-agent"]) or header_first(headers["User-Agent"]) or ngx_var("http_user_agent") or ""),
        referer = tostring(header_first(headers["referer"]) or header_first(headers["Referer"]) or ngx_var("http_referer") or ""),
        uri = uri,
        request_uri = request_uri,
        method = method,
        host = tostring(ngx_var("host") or ""),
        request_id = tostring(ngx_var("request_id") or ""),
        cookie = tostring(ngx_var("http_cookie") or "")
    }

    function ctx:uri_args(limit)
        if self._uri_args_loaded then
            return self._uri_args, self._uri_args_err
        end
        self._uri_args_loaded = true

        if not (ngx and ngx.req and ngx.req.get_uri_args) then
            return nil
        end
        local arg_limit = tonumber(limit) or tonumber(C.parse.request_arg_limit) or tonumber(C.defaults.request_arg_limit)
        local ok, args, err = pcall(ngx.req.get_uri_args, arg_limit)
        if not ok then
            self._uri_args_err = "failed"
            return nil, self._uri_args_err
        end

        self._uri_args = args
        self._uri_args_err = err
        return self._uri_args, self._uri_args_err
    end

    function ctx:post_args(limit)
        if self._post_args_loaded then
            return self._post_args, self._post_args_err
        end
        self._post_args_loaded = true

        read_body_once(self)
        if not (ngx and ngx.req and ngx.req.get_post_args) then
            return nil
        end
        local arg_limit = tonumber(limit) or tonumber(C.parse.post_arg_limit) or tonumber(C.defaults.post_arg_limit)
        local ok, args, err = pcall(ngx.req.get_post_args, arg_limit)
        if not ok then
            self._post_args_err = "failed"
            return nil, self._post_args_err
        end

        self._post_args = args
        self._post_args_err = err
        return self._post_args, self._post_args_err
    end

    function ctx:body_preview(max_len)
        if self._body_preview_loaded then
            return self._body_preview
        end
        self._body_preview_loaded = true

        max_len = tonumber(max_len) or tonumber(C.parse.max_body_inspect_bytes) or tonumber(C.defaults.max_body_inspect_bytes)
        local body = get_body_data(self)
        if body and body ~= "" then
            self._body_preview = U.safe_slice(body, max_len)
            return self._body_preview
        end

        if not (ngx and ngx.req and ngx.req.get_body_file) then
            return nil
        end
        local ok, file = pcall(ngx.req.get_body_file)
        if not ok then
            return nil
        end

        local data = read_body_file(file, max_len)
        if data and data ~= "" then
            self._body_preview = U.safe_slice(data, max_len)
            return self._body_preview
        end
        return nil
    end

    return ctx
end

return Request

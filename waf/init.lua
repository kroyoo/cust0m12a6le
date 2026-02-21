local ok, engine = pcall(require, "engine")
if not ok then
    ngx.log(ngx.ERR, "[waf] init require engine failed: ", tostring(engine))
    return
end

local warm_ok, warm_err = pcall(engine.warmup)
if not warm_ok then
    ngx.log(ngx.WARN, "[waf] warmup error: ", tostring(warm_err))
end


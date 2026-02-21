local ok, engine = pcall(require, "engine")
if not ok then
    ngx.log(ngx.ERR, "[waf] access require engine failed: ", tostring(engine))
    return
end

local run_ok, run_err = pcall(engine.run_access)
if not run_ok then
    ngx.log(ngx.ERR, "[waf] run_access error: ", tostring(run_err))
end


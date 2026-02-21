local C = require "config"
local Req = require "request"
local Rules = require "rules"
local Checks = require "checks"
local Logger = require "logger"
local Responder = require "responder"
local Challenge = require "challenge"

local Engine = {}

local function dispatch(decision, ctx)
    if decision.decision == "allow" then
        return
    end

    Logger.security(decision, ctx)

    if decision.responder == "wechat" then
        return Responder.deny_wechat()
    elseif decision.responder == "cc" then
        return Responder.deny_cc()
    end
    return Responder.deny_default()
end

function Engine.warmup()
    local ok, err = pcall(Rules.preload)
    if not ok then
        Logger.warn("[waf] warmup failed: ", tostring(err))
    end
end

function Engine.run_access()
    if not C.switch.waf then
        return
    end

    local ok_ctx, ctx = pcall(Req.new)
    if not ok_ctx then
        Logger.err("[waf] request context build failed: ", tostring(ctx))
        if C.runtime.fail_open then
            return
        end
        return Responder.fail_closed()
    end

    local ok_handle, handled = pcall(Challenge.handle_request, ctx)
    if not ok_handle then
        Logger.err("[waf] challenge handle crashed: ", tostring(handled))
        if not C.runtime.fail_open then
            return Responder.fail_closed()
        end
    elseif handled then
        return
    end

    local ok_enforce, enforced = pcall(Challenge.enforce, ctx)
    if not ok_enforce then
        Logger.err("[waf] challenge enforce crashed: ", tostring(enforced))
        if not C.runtime.fail_open then
            return Responder.fail_closed()
        end
    elseif enforced then
        return
    end

    local ok, decision = pcall(Checks.run_ordered, ctx)
    if not ok then
        Logger.err("[waf] checks crashed: ", tostring(decision))
        if C.runtime.fail_open then
            return
        end
        return Responder.fail_closed()
    end

    if decision then
        return dispatch(decision, ctx)
    end
end

return Engine

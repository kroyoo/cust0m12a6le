local C = require "config"

local R = {}

local function page_theme(kind)
    local themes = (C.page and C.page.themes) or {}
    return themes[kind] or themes.deny or {}
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

local function replace_tokens(tpl, vars)
    return (tpl:gsub("{{([%w_]+)}}", function(key)
        return vars[key] or ""
    end))
end

local function page_now()
    if ngx and ngx.localtime then
        return ngx.localtime()
    end
    return os.date("%Y-%m-%d %H:%M:%S")
end

local function request_id()
    if ngx and ngx.var and ngx.var.request_id and ngx.var.request_id ~= "" then
        return tostring(ngx.var.request_id)
    end
    return "-"
end

local function page_section(kind)
    local defaults = (C.page and C.page.defaults) or {}
    local page_cfg = (C.page and C.page[kind]) or {}
    return {
        lang = tostring(page_cfg.lang or defaults.lang or ""),
        badge = tostring(page_cfg.badge or defaults.badge or ""),
        title = tostring(page_cfg.title or defaults.title or ""),
        description = tostring(page_cfg.description or defaults.description or ""),
        hint = tostring(page_cfg.hint or defaults.hint or ""),
        action_label = tostring(page_cfg.action_label or defaults.action_label or ""),
        action_href = tostring(page_cfg.action_href or defaults.action_href or "")
    }
end

local function render_page(kind, status_code)
    local section = page_section(kind)
    local theme = page_theme(kind)
    local brand = tostring((C.page and C.page.brand) or (C.meta and C.meta.name) or "")
    local note = tostring((C.page and C.page.note) or "")
    local status = tostring(status_code or (C.output and C.output.status) or (C.defaults and C.defaults.output_status) or "")
    local action_html = ""
    local wechat_guide_html = ""
    local body_class = ""

    if section.action_label ~= "" and section.action_href ~= "" then
        action_html = string.format(
            '<a class="action" href="%s">%s</a>',
            html_escape(section.action_href),
            html_escape(section.action_label)
        )
    end

    if kind == "wechat" then
        body_class = "wechat-block"
        wechat_guide_html = [[
    <div class="wechat-guide" role="note">
      <span class="wechat-arrow">↗</span>
      <span>点击右上角“...”后选择“在浏览器打开”</span>
    </div>]]
    end

    local tpl = [[
<!doctype html>
<html lang="{{lang}}">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
  <title>{{title}}</title>
  <style>
    :root{
      --bg-a: {{bg_a}};
      --bg-b: {{bg_b}};
      --accent: {{accent}};
      --accent-soft: {{accent_soft}};
      --ink: #e6ecff;
      --ink-muted: #a8b3cf;
      --panel: rgba(15, 23, 42, 0.58);
      --line: rgba(148, 163, 184, 0.28);
    }
    * { box-sizing: border-box; }
    html, body { height: 100%; margin: 0; }
    body {
      font-family: "Source Sans 3", "Noto Sans SC", "Microsoft YaHei", sans-serif;
      color: var(--ink);
      background:
        radial-gradient(1100px 640px at 12% -8%, var(--accent-soft) 0%, rgba(2, 6, 23, 0) 56%),
        radial-gradient(900px 560px at 90% 108%, rgba(99, 102, 241, 0.12) 0%, rgba(2, 6, 23, 0) 62%),
        linear-gradient(130deg, var(--bg-a), var(--bg-b));
      display: grid;
      place-items: center;
      padding: 24px;
    }
    body.wechat-block::before {
      content: "";
      position: fixed;
      inset: 0;
      background: rgba(255, 255, 255, 0.82);
      pointer-events: none;
    }
    .panel {
      width: min(760px, 100%);
      border-radius: 20px;
      border: 1px solid var(--line);
      background: linear-gradient(170deg, rgba(15, 23, 42, 0.82), var(--panel));
      box-shadow: 0 24px 72px rgba(2, 6, 23, 0.45);
      padding: clamp(22px, 4vw, 36px);
      animation: rise 420ms cubic-bezier(.21,.98,.31,1);
      backdrop-filter: blur(7px);
    }
    body.wechat-block .panel {
      position: relative;
      z-index: 1;
      color: #0f172a;
      border: 1px solid rgba(148, 163, 184, 0.35);
      background: linear-gradient(170deg, rgba(255, 255, 255, 0.98), rgba(248, 250, 252, 0.95));
      box-shadow: 0 24px 64px rgba(15, 23, 42, 0.16);
      backdrop-filter: none;
    }
    .chip {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      font-size: 13px;
      letter-spacing: .08em;
      text-transform: uppercase;
      color: var(--ink-muted);
    }
    body.wechat-block .chip { color: #475569; }
    .dot {
      width: 9px;
      height: 9px;
      border-radius: 50%;
      background: var(--accent);
      box-shadow: 0 0 0 0 var(--accent-soft);
      animation: pulse 1.8s infinite;
    }
    body.wechat-block .dot {
      animation: none;
      background: #22c55e;
      box-shadow: none;
    }
    h1 {
      margin: 14px 0 8px;
      font-family: "Space Grotesk", "Bahnschrift", "Noto Sans SC", sans-serif;
      font-size: clamp(28px, 5vw, 42px);
      line-height: 1.08;
      letter-spacing: .01em;
    }
    .desc {
      margin: 0;
      color: #d0d9ee;
      font-size: clamp(16px, 2.2vw, 18px);
    }
    body.wechat-block .desc { color: #334155; }
    .hint {
      margin-top: 10px;
      color: var(--ink-muted);
      font-size: 14px;
      line-height: 1.7;
    }
    body.wechat-block .hint { color: #64748b; }
    .wechat-guide {
      display: none;
      margin-top: 12px;
      padding: 12px 44px 12px 12px;
      border: 1px dashed rgba(100, 116, 139, 0.5);
      border-radius: 12px;
      font-size: 14px;
      line-height: 1.6;
      color: #334155;
      background: rgba(255, 255, 255, 0.92);
      position: relative;
    }
    .wechat-arrow {
      position: absolute;
      top: 6px;
      right: 10px;
      font-size: 22px;
      line-height: 1;
      font-weight: 700;
      color: #0f172a;
    }
    body.wechat-block .wechat-guide { display: block; }
    .meta {
      margin-top: 20px;
      display: grid;
      grid-template-columns: repeat(3, minmax(0, 1fr));
      gap: 10px;
    }
    .meta-item {
      border: 1px solid var(--line);
      border-radius: 12px;
      padding: 10px 12px;
      background: rgba(15, 23, 42, 0.52);
    }
    body.wechat-block .meta-item {
      border-color: rgba(148, 163, 184, 0.35);
      background: rgba(255, 255, 255, 0.92);
    }
    .meta-k {
      color: var(--ink-muted);
      font-size: 12px;
      text-transform: uppercase;
      letter-spacing: .06em;
      margin-bottom: 3px;
    }
    body.wechat-block .meta-k { color: #64748b; }
    .meta-v {
      font-size: 14px;
      color: var(--ink);
      word-break: break-all;
    }
    body.wechat-block .meta-v { color: #0f172a; }
    .action {
      margin-top: 22px;
      display: inline-flex;
      align-items: center;
      gap: 8px;
      color: #0f172a;
      background: linear-gradient(135deg, var(--accent), #f8fafc);
      border: 0;
      border-radius: 12px;
      text-decoration: none;
      font-weight: 700;
      letter-spacing: .02em;
      padding: 11px 16px;
      transition: transform .18s ease, box-shadow .18s ease;
      box-shadow: 0 10px 30px rgba(2, 6, 23, 0.28);
    }
    .action:hover { transform: translateY(-1px); }
    body.wechat-block .action { display: none; }
    .brand {
      margin-top: 16px;
      color: var(--ink-muted);
      font-size: 12px;
      letter-spacing: .04em;
      text-transform: uppercase;
    }
    body.wechat-block .brand { color: #64748b; }
    @keyframes pulse {
      0% { box-shadow: 0 0 0 0 var(--accent-soft); }
      70% { box-shadow: 0 0 0 11px rgba(255,255,255,0); }
      100% { box-shadow: 0 0 0 0 rgba(255,255,255,0); }
    }
    @keyframes rise {
      from { opacity: 0; transform: translateY(16px) scale(.985); }
      to { opacity: 1; transform: translateY(0) scale(1); }
    }
    @media (max-width: 640px) {
      .meta { grid-template-columns: 1fr; }
      .panel { border-radius: 16px; }
    }
  </style>
</head>
<body class="{{body_class}}">
  <main class="panel">
    <div class="chip"><span class="dot"></span>{{badge}}</div>
    <h1>{{title}}</h1>
    <p class="desc">{{description}}</p>
    <p class="hint">{{hint}}</p>
    {{wechat_guide_html}}
    <div class="meta">
      <div class="meta-item">
        <div class="meta-k">status</div>
        <div class="meta-v">{{status}}</div>
      </div>
      <div class="meta-item">
        <div class="meta-k">request id</div>
        <div class="meta-v">{{request_id}}</div>
      </div>
      <div class="meta-item">
        <div class="meta-k">time</div>
        <div class="meta-v">{{time}}</div>
      </div>
    </div>
    {{action_html}}
    <div class="brand">{{brand}} / {{note}}</div>
  </main>
</body>
</html>
]]

    local vars = {
        lang = html_escape(section.lang),
        badge = html_escape(section.badge),
        title = html_escape(section.title),
        description = html_escape(section.description),
        hint = html_escape(section.hint),
        action_html = action_html,
        wechat_guide_html = wechat_guide_html,
        body_class = html_escape(body_class),
        status = html_escape(status),
        request_id = html_escape(request_id()),
        time = html_escape(page_now()),
        brand = html_escape(brand),
        note = html_escape(note),
        bg_a = tostring(theme.bg_a or ""),
        bg_b = tostring(theme.bg_b or ""),
        accent = tostring(theme.accent or ""),
        accent_soft = tostring(theme.accent_soft or "")
    }
    return replace_tokens(tpl, vars)
end

local function exit_html(status, body)
    ngx.status = status
    ngx.header.content_type = "text/html; charset=utf-8"
    ngx.say(body or "")
    return ngx.exit(status)
end

local function exit_json(status, body)
    ngx.status = status
    ngx.header.content_type = "application/json; charset=utf-8"
    ngx.say(body or "{}")
    return ngx.exit(status)
end

function R.captcha_page()
    if C.page and type(C.page.captcha_html) == "string" and C.page.captcha_html ~= "" then
        return exit_html(200, C.page.captcha_html)
    end
    return exit_html(200, render_page("captcha", 200))
end

function R.deny_default()
    local mode = tostring(C.output.mode or "html")
    local status = tonumber(C.output.status) or tonumber(C.defaults.output_status)

    if mode == "redirect" then
        local target = C.output.redirect_url
            or (C.route and C.route.deny_redirect_uri)
            or (C.defaults and C.defaults.deny_redirect_uri)
        if target and target ~= "" then
            return ngx.redirect(target, ngx.HTTP_MOVED_TEMPORARILY)
        end
    elseif mode == "json" then
        return exit_json(status, C.output.json or (C.defaults and C.defaults.forbidden_json) or "{}")
    end

    if C.page and type(C.page.deny_html) == "string" and C.page.deny_html ~= "" then
        return exit_html(status, C.page.deny_html)
    end
    return exit_html(status, render_page("deny", status))
end

function R.deny_wechat()
    local status = tonumber(C.output.status) or tonumber(C.defaults.output_status)
    if C.page and type(C.page.wechat_html) == "string" and C.page.wechat_html ~= "" then
        return exit_html(status, C.page.wechat_html)
    end
    return exit_html(status, render_page("wechat", status))
end

function R.deny_cc()
    local action = tostring(C.cc.action or "forbidden")
    if action == "captcha" then
        local captcha_uri = (C.route and C.route.captcha_uri) or (C.defaults and C.defaults.captcha_uri)
        if captcha_uri and captcha_uri ~= "" then
            return ngx.redirect(captcha_uri, ngx.HTTP_MOVED_TEMPORARILY)
        end
    end

    local status = tonumber(C.cc.status) or tonumber(C.defaults.cc_status)
    if C.page and type(C.page.cc_html) == "string" and C.page.cc_html ~= "" then
        return exit_html(status, C.page.cc_html)
    end
    return exit_html(status, render_page("cc", status))
end

function R.fail_closed()
    local status = tonumber(C.output.fail_closed_status) or (C.defaults and C.defaults.fail_closed_status)
    local body = C.output.fail_closed_json or (C.defaults and C.defaults.fail_closed_json)
    return exit_json(status, body)
end

return R

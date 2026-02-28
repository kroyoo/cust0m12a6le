# nginx/install_nginx.sh

Source installer for Nginx + Lua WAF + GeoIP2 modules.

## What it does

- Builds Nginx from source with Lua-related modules.
- Writes a candidate install tree first (`stage` mode).
- Optionally promotes candidate to live prefix (`promote` mode) with rollback safety.
- Integrates WAF rules into `nginx.conf` by copying `waf/` into `conf/waf`.
- Installs Lua runtime dependencies used by WAF challenge flow, including `lua-resty-http`.

## Runtime modes

- `stage` (default): build + config + `nginx -t` only, no live replacement.
- `promote`: backup current live tree and switch to new tree.

## WAF source modes

`install_nginx.sh` now supports two WAF sources:

- `local` (default): read local `waf/` directory.
  - Auto-detect order when `WAF_SOURCE_DIR` is empty:
    1. `../waf` (relative to script directory)
    2. `./waf` (relative to script directory)
- `online`: clone remote git repo and use one subdirectory as WAF source.

Default online source:

- Repo: `https://github.com/kroyoo/cust0m12a6le.git`
- Subdir: `waf`
- Ref: repository default branch (unless `--waf-ref` is set)

## Quick start

Dry-run (no changes):

```bash
bash nginx/install_nginx.sh --dry-run
```

Stage build with local WAF:

```bash
bash nginx/install_nginx.sh --mode stage
```

Stage build with online WAF:

```bash
bash nginx/install_nginx.sh --mode stage --online-waf
```

Promote to live and restart service:

```bash
bash nginx/install_nginx.sh --mode promote --activate --link-bin
```

## WAF options

- `--waf-source local|online`
- `--online-waf` (shortcut for `--waf-source online`)
- `--waf-source-dir PATH`
- `--waf-repo URL`
- `--waf-ref REF`
- `--waf-subdir PATH`

Examples:

```bash
# Use a custom local waf directory
bash nginx/install_nginx.sh --waf-source local --waf-source-dir /opt/my-waf

# Use online waf from a fixed branch
bash nginx/install_nginx.sh --waf-source online \
  --waf-repo https://github.com/kroyoo/cust0m12a6le.git \
  --waf-ref main \
  --waf-subdir waf
```

## Lua HTTP dependency (`lua-resty-http`)

Turnstile verification in `waf/challenge.lua` uses `require("resty.http")`.

`install_nginx.sh` fetches and installs `lua-resty-http` into:

- shared Lua path: `${LUA_SHARE_DIR}/resty/http.lua` (default `/usr/local/share/lua/5.1/resty/http.lua`)
- candidate/runtime Lua path: `${NGINX_PREFIX}/conf/lua/resty/http.lua` (default `/usr/local/nginx/conf/lua/resty/http.lua`)

## Post-install verification commands

Run these on target host after `--promote`:

```bash
# 1) Confirm compiled modules include Lua/WAF prerequisites
nginx -V 2>&1 | grep -E 'ngx_devel_kit|lua-nginx-module|stream-lua-nginx-module|ngx_http_geoip2_module|ngx_http_substitutions_filter_module'

# 2) Confirm running binary is the expected one
ps -ef | grep '[n]ginx: master'

# 3) Confirm lua module files exist
ls -l /usr/local/share/lua/5.1/resty/http.lua
ls -l /usr/local/nginx/conf/lua/resty/http.lua

# 4) Confirm service has LUA_PATH/LUA_CPATH injected
systemctl cat nginx | grep -E 'LUA_PATH|LUA_CPATH'

# 5) Confirm WAF include + Lua directives are in active config
nginx -T 2>/dev/null | grep -nE 'include waf/waf.conf|lua_package_path|lua_shared_dict waf_challenge'

# 6) Confirm nginx config is valid
nginx -t

# 7) (Optional) verify outbound connectivity to Turnstile verify endpoint
curl -I https://challenges.cloudflare.com/turnstile/v0/siteverify
```

If step 3 fails, Turnstile verification will fail at runtime (`resty.http` missing).
If step 7 fails, Turnstile token verification cannot complete.

## Notes

- Run as root for real install/promotion.
- In `stage` mode, workdir is kept by default for manual verification.
- `--dry-run` prints the full plan, including chosen WAF source.
- Default install mode is `stage`; use `--mode promote` to switch live service.

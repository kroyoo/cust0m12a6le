# nginx/install_nginx.sh

Source installer for Nginx + Lua WAF + GeoIP2 modules (single release-layout workflow).

## What it does

- Builds Nginx from source with Lua-related modules.
- Publishes each build into immutable release directory.
- Switches active binary by updating `current` symlink.
- Keeps runtime config persistent in separate runtime prefix (no full prefix replacement).
- Default behavior does **not** auto-restart service; you can verify first, then restart manually.

## Release Layout

Default paths:

- `NGINX_PREFIX=/usr/local/nginx`
- `RELEASES_DIR=/usr/local/nginx/releases`
- `CURRENT_LINK=/usr/local/nginx/current`
- `RUNTIME_PREFIX=/usr/local/nginx-data`

Operational behavior:

- binaries/modules live in release dirs;
- `current` points to active release;
- `RUNTIME_PREFIX/conf` keeps persistent config (`nginx.conf`, `vhost/`, `ssl/`, etc).

## Runtime Behavior

Installer flow is always:

1. build candidate
2. validate candidate config
3. publish release
4. initialize runtime config if missing
5. sync runtime Lua assets (+ optional WAF sync)
6. validate runtime config with new binary
7. switch `current` symlink
8. optional service reload/restart (`--activate`)

By default (`--activate` not set), script does not touch service state.

## WAF Source And Policy

WAF source:

- `--waf-source local|online` (default: `local`)
- `--online-waf` (shortcut)

WAF policy:

- `--waf-policy required`: missing/failed WAF source stops execution.
- `--waf-policy optional` (default): WAF issues are skipped with warning.
- `--waf-policy disabled`: skip WAF resolution/integration/sync.

Optional runtime WAF sync:

- `--sync-waf` / `--no-sync-waf`

## CLI Parameters (Full)

General:

- `-y`, `--yes`: non-interactive mode.
- `--dry-run`: print plan only, do not execute install.
- `-h`, `--help`: show help.

Service and systemd:

- `--activate`: auto start/restart after successful switch.
- `--link-bin`: link `/usr/bin/nginx` to active binary.
- `--rewrite-unit`: rewrite systemd unit for current/runtime layout.
- `--no-rewrite-unit`: keep existing unit (fails if unit does not match new layout).
- `--service-name NAME`: systemd service name (default `nginx`).
- `--backup-root PATH`: backup root for unit/runtime backups.
- `SERVICE_NAME`, `NGINX_USER`, `NGINX_GROUP` allow only: `[A-Za-z0-9_.@-]`.

Layout:

- `--prefix PATH`: install prefix (default `/usr/local/nginx`).
- `--runtime-prefix PATH`: runtime prefix (default `/usr/local/nginx-data` when prefix is default).
- `--releases-dir PATH`: immutable releases directory (default `<prefix>/releases`).
- `--current-link PATH`: active release symlink path (default `<prefix>/current`).
- `--release-keep N`: keep newest `N` releases.
- Path options are validated as absolute paths.
- Layout guardrails:
  - `RUNTIME_PREFIX` cannot be inside `RELEASES_DIR`
  - `RELEASES_DIR` cannot be inside `RUNTIME_PREFIX`
  - `CURRENT_LINK` cannot be inside `RELEASES_DIR` or `RUNTIME_PREFIX`

Build and version control:

- `--auto-latest 0|1`: discover latest versions at runtime.
- `--nginx-version VER`
- `--openssl-version VER`
- `--pcre2-version VER`
- `--jemalloc-version VER`
- `--libmaxminddb-version VER`
- `--no-jemalloc`: disable jemalloc.
- `--workdir PATH`: reuse a fixed build workdir.

Branding:

- `--brand NAME`: set custom server brand in source patch step.
- `--no-brand`: keep upstream `nginx` branding.
- Default behavior is interactive (`BRAND_MODE=ask`); default brand value is `Fungit` when branding is enabled without custom input.

WAF:

- `--waf-source local|online`
- `--online-waf`: shortcut for online source.
- `--waf-policy required|optional|disabled`
- `--sync-waf`
- `--no-sync-waf`
- `--waf-source-dir PATH`
- `--waf-repo URL`
- `--waf-ref REF`
- `--waf-subdir PATH`

## Quick Start

Dry-run:

```bash
bash nginx/install_nginx.sh --dry-run
```

Install (build + release switch), keep service untouched for manual verification:

```bash
bash nginx/install_nginx.sh --rewrite-unit --link-bin
```

Install and auto reload/restart service:

```bash
bash nginx/install_nginx.sh --rewrite-unit --link-bin --activate
```

Online WAF, non-blocking if repo unavailable:

```bash
bash nginx/install_nginx.sh --waf-source online --waf-policy optional \
  --waf-repo https://github.com/kroyoo/cust0m12a6le.git \
  --waf-ref main \
  --waf-subdir waf
```

## Upgrade Existing Install

If Nginx was already installed by this script, run the same installer again to upgrade.

Recommended flow:

```bash
# 1) Review plan first
bash nginx/install_nginx.sh --dry-run

# 2) Upgrade (build new release + switch current symlink), keep service untouched
bash nginx/install_nginx.sh -y

# 3) Validate and restart manually
/usr/local/nginx/current/sbin/nginx -t -p /usr/local/nginx-data/ -c conf/nginx.conf
systemctl restart nginx
```

Pin versions explicitly:

```bash
bash nginx/install_nginx.sh -y --auto-latest 0 \
  --nginx-version 1.28.2 \
  --openssl-version 3.6.1 \
  --pcre2-version 10.47
```

Useful upgrade options:

- `--activate`: auto restart/reload service after successful release switch.
- `--release-keep N`: keep newest `N` release directories.
- `--sync-waf`: overwrite runtime `conf/waf` from prepared release copy.
- `--no-sync-waf`: keep existing runtime `conf/waf` as-is (default behavior).

Config safety during upgrade:

- Existing runtime `nginx.conf` is preserved if already present.
- Runtime Lua assets are synced from release to ensure module compatibility.
- Runtime `waf/` is only replaced when `--sync-waf` is enabled.

## Lua HTTP dependency (`lua-resty-http`)

Turnstile verification in `waf/challenge.lua` uses `require("resty.http")`.

`install_nginx.sh` installs `lua-resty-http` into:

- shared Lua path: `${LUA_SHARE_DIR}/resty/http.lua` (default `/usr/local/share/lua/5.1/resty/http.lua`)
- release candidate path: `<release>/conf/lua/resty/http.lua`
- runtime path: `${RUNTIME_PREFIX}/conf/lua/resty/http.lua`

## Post-install verification commands

Run these after install (before manual restart if `--activate` was not used):

```bash
# 1) Confirm current release symlink and binary
readlink -f /usr/local/nginx/current
/usr/local/nginx/current/sbin/nginx -V 2>&1 | grep -E 'ngx_devel_kit|lua-nginx-module|stream-lua-nginx-module|ngx_http_geoip2_module|ngx_http_substitutions_filter_module'

# 2) Confirm runtime config path exists
ls -l /usr/local/nginx-data/conf/nginx.conf

# 3) Confirm lua module files exist
ls -l /usr/local/share/lua/5.1/resty/http.lua
ls -l /usr/local/nginx-data/conf/lua/resty/http.lua

# 4) Validate runtime config with active binary
/usr/local/nginx/current/sbin/nginx -t -p /usr/local/nginx-data/ -c conf/nginx.conf

# 5) Confirm service has LUA_PATH/LUA_CPATH (if using systemd)
systemctl cat nginx | grep -E 'LUA_PATH|LUA_CPATH'

# 6) Optional Turnstile endpoint connectivity check
curl -I https://challenges.cloudflare.com/turnstile/v0/siteverify
```

If step 3 fails, Turnstile verification will fail at runtime (`resty.http` missing).
If step 6 fails, Turnstile token verification cannot complete.

## Manual restart after check

```bash
# systemd
systemctl restart nginx

# or reload
systemctl reload nginx
```

## Notes

- Run as root for non-dry-run execution.
- `--dry-run` prints full execution plan.
- Runtime config and custom assets (`vhost/`, `ssl/`, `waf/`) should be maintained under `${RUNTIME_PREFIX}/conf`.

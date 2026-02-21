# nginx/install_nginx.sh

Source installer for Nginx + Lua WAF + GeoIP2 modules.

## What it does

- Builds Nginx from source with Lua-related modules.
- Writes a candidate install tree first (`stage` mode).
- Optionally promotes candidate to live prefix (`promote` mode) with rollback safety.
- Integrates WAF rules into `nginx.conf` by copying `waf/` into `conf/waf`.

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

## Notes

- Run as root for real install/promotion.
- In `stage` mode, workdir is kept by default for manual verification.
- `--dry-run` prints the full plan, including chosen WAF source.

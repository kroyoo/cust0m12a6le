
### example
#### https://fung.eu.org/renewx/

```
  location /renewx/ {
    proxy_pass http://127.0.0.1:22006/;

    proxy_redirect default;
    proxy_redirect / /renewx/;
    proxy_redirect  http://127.0.0.1:22006/ https://fung.eu.org/renewx/;

    proxy_set_header Accept-Encoding '';
    subs_filter (/Admin/.*) /renewx$1 gr;
    subs_filter (/User/.*) /renewx$1 gr;
    subs_filter (/System/.*) /renewx$1 gr;
    subs_filter (/Account/.*) /renewx$1 gr;
    sub_filter '<a class="navbar-brand" href="/">'  '<a class="navbar-brand" href="/renewx">';
    sub_filter '<a class="btn btn-primary btn-block" href="/">'  '<a class="btn btn-primary btn-block" href="/renewx">';
    sub_filter_once off;
  }

```

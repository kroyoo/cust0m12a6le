# google reverse




```nginx
location /
{
    auth_basic  "basic";
    auth_basic_user_file /www/wwwroot/.htpasswd;

    autoindex on;
    autoindex_exact_size on;
    autoindex_localtime on;
    proxy_redirect off;
    proxy_cookie_domain google.com domian.com;
    proxy_connect_timeout 60s;
    proxy_read_timeout 600s;
    proxy_send_timeout 600s;
    proxy_set_header Referer https://www.google.com;
    proxy_set_header Accept-Encoding "";
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header User-Agent $http_user_agent;
    proxy_set_header Accept-Language "en-US";
    proxy_set_header Cookie $http_cookie;

    proxy_pass https://www.google.com;
    proxy_set_header Host www.google.com;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header REMOTE-HOST $remote_addr;

    sub_filter_types  text/css text/javascript application/json;
    sub_filter_once off;
    sub_filter  //maps.google.com/ 		   //$host/;
    sub_filter  //www.google.com/                  //$host/;
    sub_filter  //apis.google.com/                 //$host/__gapis/;
    sub_filter  //ajax.googleapis.com/             //$host/__gajax/;
    sub_filter  //fonts.googleapis.com/            //$host/__gfonts/;
    sub_filter  //www.gstatic.com/                 //$host/__gstatic/www/;
    sub_filter  //ssl.gstatic.com/                 //$host/__gstatic/ssl/;
    sub_filter  //encrypted-tbn0.gstatic.com/      //$host/__gstatic/enc-tbn0/;
                # Google Images
    sub_filter  //webcache.googleusercontent.com/  //$host/__gwebcache/;

    add_header X-Cache $upstream_cache_status;

    #Set Nginx Cache

    add_header Cache-Control no-cache;
    expires 12h;
}

    location ^~ /__gwebcache/ {
        # ^~ will make location search stop here if matched.
        proxy_pass  https://webcache.googleusercontent.com/;
        # Note the trailing '/' above, which tells Nginx to strip the
        # matched URI.
        # Credit: https://serverfault.com/a/725433/387898

        proxy_set_header  Host     webcache.googleusercontent.com;
        proxy_set_header  Referer  https://webcache.googleusercontent.com;
        # NOTE: The upper level "proxy_set_header" directives are *not*
        #       inherited since there are such directives on this level!
        proxy_set_header  User-Agent         $http_user_agent;
        proxy_set_header  X-Real-IP          $remote_addr;
        proxy_set_header  X-Forwarded-For    $proxy_add_x_forwarded_for;
        proxy_set_header  X-Forwarded-Proto  $scheme;
        proxy_set_header  Cookie             "";
        proxy_set_header  Accept-Language    "en-US";
        proxy_set_header  Accept-Encoding    "";
    }
    location ^~ /__gstatic/ssl/ {
        proxy_pass        https://ssl.gstatic.com/;
        proxy_set_header  Host     ssl.gstatic.com;
        proxy_set_header  Referer  https://ssl.gstatic.com;
        proxy_set_header  User-Agent         $http_user_agent;
        proxy_set_header  X-Real-IP          $remote_addr;
        proxy_set_header  X-Forwarded-For    $proxy_add_x_forwarded_for;
        proxy_set_header  X-Forwarded-Proto  $scheme;
        proxy_set_header  Cookie             "";
        proxy_set_header  Accept-Language    "en-US";
        proxy_set_header  Accept-Encoding    "";
    }
    location ^~ /__gstatic/www/ {
        proxy_pass        https://www.gstatic.com/;
        proxy_set_header  Host     ssl.gstatic.com;
        proxy_set_header  Referer  https://ssl.gstatic.com;
        proxy_set_header  User-Agent         $http_user_agent;
        proxy_set_header  X-Real-IP          $remote_addr;
        proxy_set_header  X-Forwarded-For    $proxy_add_x_forwarded_for;
        proxy_set_header  X-Forwarded-Proto  $scheme;
        proxy_set_header  Cookie             "";
        proxy_set_header  Accept-Language    "en-US";
        proxy_set_header  Accept-Encoding    "";
    }
    location ^~ /__gstatic/enc-tbn0/ {
        proxy_pass        https://encrypted-tbn0.gstatic.com/;
        proxy_set_header  Host     encrypted-tbn0.gstatic.com;
        proxy_set_header  Referer  https://encrypted-tbn0.gstatic.com;
        proxy_set_header  User-Agent         $http_user_agent;
        proxy_set_header  X-Real-IP          $remote_addr;
        proxy_set_header  X-Forwarded-For    $proxy_add_x_forwarded_for;
        proxy_set_header  X-Forwarded-Proto  $scheme;
        proxy_set_header  Cookie             "";
        proxy_set_header  Accept-Language    "en-US";
        proxy_set_header  Accept-Encoding    "";
    }
    location ^~ /__gapis/ {
        proxy_pass        https://apis.google.com/;
        proxy_set_header  Host     apis.google.com;
        proxy_set_header  Referer  https://apis.google.com;
        proxy_set_header  User-Agent         $http_user_agent;
        proxy_set_header  X-Real-IP          $remote_addr;
        proxy_set_header  X-Forwarded-For    $proxy_add_x_forwarded_for;
        proxy_set_header  X-Forwarded-Proto  $scheme;
        proxy_set_header  Cookie             "";
        proxy_set_header  Accept-Language    "en-US";
        proxy_set_header  Accept-Encoding    "";
    }
    location ^~ /__gfonts/ {
        proxy_pass        https://fonts.googleapis.com/;
        proxy_set_header  Host     fonts.googleapis.com;
        proxy_set_header  Referer  https://fonts.googleapis.com;
        proxy_set_header  User-Agent         $http_user_agent;
        proxy_set_header  X-Real-IP          $remote_addr;
        proxy_set_header  X-Forwarded-For    $proxy_add_x_forwarded_for;
        proxy_set_header  X-Forwarded-Proto  $scheme;
        proxy_set_header  Cookie             "";
        proxy_set_header  Accept-Language    "en-US";
        proxy_set_header  Accept-Encoding    "";
    }
    location ^~ /__gajax/ {
        proxy_pass        https://ajax.googleapis.com/;
        proxy_set_header  Host     ajax.googleapis.com;
        proxy_set_header  Referer  https://ajax.googleapis.com;
        proxy_set_header  User-Agent         $http_user_agent;
        proxy_set_header  X-Real-IP          $remote_addr;
        proxy_set_header  X-Forwarded-For    $proxy_add_x_forwarded_for;
        proxy_set_header  X-Forwarded-Proto  $scheme;
        proxy_set_header  Cookie             "";
        proxy_set_header  Accept-Language    "en-US";
        proxy_set_header  Accept-Encoding    "";
    }

    # Forbid spider
    if ($http_user_agent ~* "qihoobot|Baiduspider|Googlebot|Googlebot-Mobile|Googlebot-Image|Mediapartners-Google|Adsbot-Google|Feedfetcher-Google|Yahoo! Slurp|Yahoo! Slurp China|YoudaoBot|Sosospider|Sogou spider|Sogou web spider|MSNBot|ia_archiver|Tomato Bot") {
        return  403;
    }

    location /robots.txt {
        default_type  text/plain;
        return  200  "User-agent: *\nDisallow: /\n";
    }
```

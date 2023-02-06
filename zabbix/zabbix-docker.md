## zabbix docker configuration

``` conf

OS: Debian GNU/Linux 11 (bullseye) aarch64
Docker version 20.10.23, build 7155243
zabbix: zabbix/zabbix-server-mysql:6.0.0-alpine
host MySQL: mysql  Ver 8.0.31 for Linux on aarch64 (Source distribution)
host Nginx : 
```

### database
create database and user

``` mysql
create database zabbix character set utf8 collate utf8_bin;
create user 'zabbix'@'172.%.%.%' identified by 'I.zabbix';
grant all on zabbix.* to 'zabbix'@'172.%.%.%' with grant option;
FLUSH PRIVILEGES;

```

allow docker0 connect
``` shell
ufw allow in on docker0 to any port 3306
```


### zabbix server

``` shell
# mkdir valume dir
mkdir -p /docker-volume/zabbix

docker run --name zabbix-server -d \
      -e DB_SERVER_HOST="172.17.0.1" \
      -e MYSQL_DATABASE="zabbix" \
      -e MYSQL_USER="zabbix" \
      -e MYSQL_PASSWORD="I.zabbix" \
      -v /docker-volume/zabbix:/var/lib/zabbix/ \
      -p 10051:10051 \
      --restart unless-stopped \
      -d zabbix/zabbix-server-mysql:6.0.0-alpine

```

when start and see log

``` shell
docker logs -f zabbix-server
```

### zabbix-web-nginx-mysql
``` shell
docker run --name zabbix-web-nginx-mysql -d \ 
--link zabbix-server:zabbix-server \ 
-e DB_SERVER_HOST="172.17.0.1" \ 
-e MYSQL_USER="zabbix" \ 
-e MYSQL_PASSWORD="I.zabbix" \ 
-e ZBX_SERVER_HOST="127.0.0.1" \ 
-e PHP_TZ="America/Chicago" \ 
-p 127.0.0.1:38080:8080  \ 
-d zabbix/zabbix-web-nginx-mysql:6.0.0-alpine

````
in the host nginx config proxy

``` nginx
  location / {
    proxy_intercept_errors on;
    proxy_pass http://127.0.0.1:38080;
    include proxy.conf;
  }

```



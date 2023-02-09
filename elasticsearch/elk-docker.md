### first start a container

```shell
docker run -d \
 --name elasticsearch \
 --restart always \
 --net elastic \
 -e ES_JAVA_OPTS="-Xms3g -Xmx3g" \
 elasticsearch:8.6.1
```

and then copy container file to host, and restart container

```shell
mkdir -p /docker-volume/es
cd /docker-volume/es
docker cp elasticsearch:/usr/share/elasticsearch ./
docker rm -f elasticsearch

docker run -d \
 --name elasticsearch \
 --restart unless-stopped \
 --net elastic \
 -e ES_JAVA_OPTS="-Xms3g -Xmx3g" \
 -v /docker-volume/es:/usr/share/elasticsearch \
 -p 127.0.0.1:9200:9200 \
 -p 127.0.0.1:9300:9300 \
 elasticsearch:8.6.1

```

kibana also to

```shell

docker run -d \
 --name kibana \
 --net elastic \
 kibana:8.6.1

mdkir -p  /docker-volume/kibana
cd  /docker-volume/kibana
docker cp kibana:/usr/share/kibana ./
docker rm -f kibana

docker run -d \
 --name kibana \
 --net elastic \
 -e SERVER_REWRITEBASEPATH=true \
 -p 127.0.0.1:5601:5601 \
 -v /docker-volume/kibana:/usr/share/kibana \
 kibana:8.6.1

```


logstash

```shell
docker run -d \
    --name logstash\
    --net elastic \
    --restart unless-stopped \
    -p 127.0.0.1:5044:5044 \
    -p 127.0.0.1:5000:5000/tcp \
    -p 127.0.0.1:5000:5000/udp \
    -p 127.0.0.1:9600 :9600 \
    --privileged \
    -v /docker-volume/logstash/config:/usr/share/logstash/config \
    -v /docker-volume/logstash/data:/usr/share/logstash/data \
    logstash:8.6.1
```

### outbounds

[outbounds](https://www.v2fly.org/config/outbounds.html)

```
{
  "log": null,
  "routing": {
    "rules": [
      {
        "inboundTag": [
          "api"
        ],
        "outboundTag": "api",
        "type": "field"
      },
      {
        "ip": [
          "geoip:private"
        ],
        "outboundTag": "blocked",
        "type": "field"
      },
      {
        "outboundTag": "blocked",
        "protocol": [
          "bittorrent"
        ],
        "type": "field"
      }
    ]
  },
  "dns": null,
  "inbounds": [
    {
      "listen": null,
      "port": 33302,
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "15378d27-xxx-xxxx-d4f6-e175ec268cf8",
            "alterId": 0
          }
        ],
        "disableInsecureEncryption": false
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "/ws",
          "headers": {}
        }
      },
      "tag": "inbound-33302",
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "http",
      "settings": {
        "servers": [
          {
            "address": "ip",
            "port": 10208,
            "users": [
              {
                "user": "user",
                "pass": "password"
              }
            ]
          }
        ]
      }
    }
  ],
  "transport": null,
  "policy": {
    "system": {
      "statsInboundDownlink": true,
      "statsInboundUplink": true
    }
  },
  "api": {
    "services": [
      "HandlerService",
      "LoggerService",
      "StatsService"
    ],
    "tag": "api"
  },
  "stats": {},
  "reverse": null,
  "fakeDns": null
}
```

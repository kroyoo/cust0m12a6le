```
    # upos-sz-mirrorhw.bilivideo.com -> 华为云
    # upos-sz-mirrorcos.bilivideo.com -> 腾讯云
    # upos-sz-mirrorbs.bilivideo.com -> 白山云
    # upos-sz-mirrorali.bilivideo.com -> 阿里云
    # cn-gddg-ct-01-01.bilivideo.com -> 广东东莞电信
    # cn-lnsy-cu-01-01.bilivideo.com -> 辽宁沈阳联通
    # cn-gddg-cm-01-01.bilivideo.com -> 广东东莞移动

```

```
        hwb: 'upos-sz-mirrorhwb.bilivideo.com',
        upbda2: 'upos-sz-upcdnbda2.bilivideo.com',
        upws: 'upos-sz-upcdnws.bilivideo.com',
        uptx: 'upos-sz-upcdntx.bilivideo.com',
        uphw: 'upos-sz-upcdnhw.bilivideo.com',
        js: 'upos-tf-all-js.bilivideo.com',
        hk: 'cn-hk-eq-bcache-01.bilivideo.com',
        akamai: 'upos-hz-mirrorakam.akamaized.net',
        upos-sz-mirroraliov.bilivideo.com

```

and more
```

https://rec.danmuji.org/dev/bilibili-cdn
```



code
``` javascript
// 去 P2P CDN
if ( location.href.startsWith('https://www.bilibili.com/video/') || location.href.startsWith('https://www.bilibili.com/bangumi/play/') || location.href.startsWith('https://www.bilibili.com/blackboard/') ) {
    const cdnDomains = [
        "upos-sz-mirrorhw.bilivideo.com",
        "upos-sz-mirrorcos.bilivideo.com",
        "upos-sz-mirrorali.bilivideo.com",
        "upos-sz-mirrorcoso1.bilivideo.com"
    ];

    function getRandomCdnDomain() {
        const randomIndex = Math.floor(Math.random() * cdnDomains.length);
        return cdnDomains[randomIndex];
    }
    function replaceP2PUrl(url) {
        try {
            const urlObj = new URL(url);
            const hostName = urlObj.hostname;
            if ( url.includes('bilibili') || url.includes('hdslb') || url.includes('biliapi') ) {
                return url;
            }
            // console.warn(hostName)
            urlObj.host = getRandomCdnDomain();
            urlObj.port = 443;
            console.warn(`更换视频源: ${hostName} -> ${urlObj.host}`);
            return urlObj.toString();
        } catch(e) {
            return url;
        }
    }

    function replaceP2PUrlDeep(obj) {
        for (const key in obj) {
            if ( key === 'baseUrl' ) {
                obj[key] = replaceP2PUrl(obj[key]);
            } else if (typeof obj[key] === 'array' || typeof obj[key] === 'object') {
                replaceP2PUrlDeep(obj[key]);
            }
        }
    }

    replaceP2PUrlDeep(unsafeWindow.__playinfo__);

    (function (open) {
        unsafeWindow.XMLHttpRequest.prototype.open = function () {
            try {
                arguments[1] = replaceP2PUrl(arguments[1]);
            } finally {
                return open.apply(this, arguments);
            }
        }
    })(unsafeWindow.XMLHttpRequest.prototype.open);
}

```
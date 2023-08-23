```

// ==UserScript==
// @name         Make BiliBili Great Again
// @namespace    https://www.kookxiang.com/
// @version      1.5.1
// @description  useful tweaks for bilibili.com
// @author       kookxiang
// @match        https://*.bilibili.com/*
// @run-at       document-body
// @grant        unsafeWindow
// @grant        GM_addStyle
// ==/UserScript==

GM_addStyle("html, body { -webkit-filter: none !important; filter: none !important; }");

// Block WebRTC，CNM 陈睿你就缺这点棺材钱？
try {
    Object.defineProperty(unsafeWindow, 'webkitRTCPeerConnection', { value: undefined, enumerable: false, writable: false });
} catch(e) {}

window.addEventListener('load', function () {
    document.body.classList.remove('harmony-font');
})

// 首页优化
if (location.host === "www.bilibili.com") {
    GM_addStyle('.feed2 .container > *:has(a[href*="cm.bilibili.com"]) { display: none } .feed2 .container > * { margin-top: 0 !important }');
}

// 动态页面优化
if (location.host === "t.bilibili.com") {
    GM_addStyle("html[wide] #app { display: flex; } html[wide] .bili-dyn-home--member { box-sizing: border-box;padding: 0 10px;width: 100%;flex: 1; } html[wide] .bili-dyn-content { width: initial; } html[wide] main { margin: 0 8px;flex: 1;overflow: hidden;width: initial; } #wide-mode-switch { margin-left: 0;margin-right: 20px; }");
    if (!localStorage.WIDE_OPT_OUT) {
        document.documentElement.setAttribute('wide', 'wide');
    }
    window.addEventListener('load', function () {
        const tabContainer = document.querySelector('.bili-dyn-list-tabs__list');
        const placeHolder = document.createElement('div');
        placeHolder.style.flex = 1;
        const switchButton = document.createElement('a');
        switchButton.id = 'wide-mode-switch';
        switchButton.className = 'bili-dyn-list-tabs__item';
        switchButton.textContent = '宽屏模式';
        switchButton.addEventListener('click', function (e) {
            e.preventDefault();
            if (localStorage.WIDE_OPT_OUT) {
                localStorage.removeItem('WIDE_OPT_OUT');
                document.documentElement.setAttribute('wide', 'wide');
            } else {
                localStorage.setItem('WIDE_OPT_OUT', '1');
                document.documentElement.removeAttribute('wide');
            }
        })
        tabContainer.appendChild(placeHolder);
        tabContainer.appendChild(switchButton);
    })
}

// 去广告
GM_addStyle('.ad-report, a[href*="cm.bilibili.com"] { display: none !important; }');
if (unsafeWindow.__INITIAL_STATE__?.adData) {
    for (const key in unsafeWindow.__INITIAL_STATE__.adData) {
        for (const item of unsafeWindow.__INITIAL_STATE__.adData[key]) {
            item.name = 'B 站未来有可能会倒闭，但绝不会变质';
            item.pic = 'https://static.hdslb.com/images/transparent.gif';
            item.url = 'https://space.bilibili.com/208259';
        }
    }
}

// 去充电列表（叔叔的跳过按钮越做越小了，就尼玛离谱）
if (unsafeWindow.__INITIAL_STATE__?.elecFullInfo) {
    delete unsafeWindow.__INITIAL_STATE__.elecFullInfo;
}

// 修复文章区复制
if (location.href.startsWith('https://www.bilibili.com/read/cv')) {
    unsafeWindow.original.reprint = "1";
    document.querySelector('.article-holder').classList.remove("unable-reprint");
    document.querySelector('.article-holder').addEventListener('copy', e => e.stopImmediatePropagation(), true);
}

// 去 P2P CDN
if (location.href.startsWith('https://www.bilibili.com/video/') || location.href.startsWith('https://www.bilibili.com/bangumi/play/')) {
    let cdnDomain;

    function replaceP2PUrl(url) {
        cdnDomain ||= document.head.innerHTML.match(/up[\w-]+\.bilivideo\.com/)?.[0];

        try {
            const urlObj = new URL(url);
            const hostName = urlObj.hostname;
            if (urlObj.hostname.endsWith(".mcdn.bilivideo.cn")) {
                urlObj.host = cdnDomain || 'upos-sz-mirrorcoso1.bilivideo.com';
                urlObj.port = 443;
                console.warn(`更换视频源: ${hostName} -> ${urlObj.host}`);
                return urlObj.toString();
            } else if (urlObj.hostname.endsWith(".szbdyd.com")) {
                urlObj.host = urlObj.searchParams.get('xy_usource');
                urlObj.port = 443;
                console.warn(`更换视频源: ${hostName} -> ${urlObj.host}`);
                return urlObj.toString();
            }
            return url;
        } catch(e) {
            return url;
        }
    }

    function replaceP2PUrlDeep(obj) {
        for (const key in obj) {
            if (typeof obj[key] === 'string') {
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

// 真·原画直播
if (location.href.startsWith('https://live.bilibili.com/')) {
    const oldFetch = unsafeWindow.fetch;
    unsafeWindow.disableMcdn = false;
    unsafeWindow.forceHighestQuality = false;
    unsafeWindow.fetch = function(url) {
        try {
            const mcdnRegexp = /[xy0-9]+\.mcdn\.bilivideo\.cn:\d+/
            const qualityRegexp = /(live-bvc\/\d+\/live_\d+_\d+)_\w+/;
            if (mcdnRegexp.test(arguments[0]) && unsafeWindow.disableMcdn) {
                return Promise.reject();
            }
            if (qualityRegexp.test(arguments[0]) && unsafeWindow.forceHighestQuality) {
                arguments[0] = arguments[0].replace(qualityRegexp, '$1');
            }
            return oldFetch.apply(this, arguments);
        } catch(e) {}
        return oldFetch.apply(this, arguments);
    }
}

// 视频裁切
if (location.href.startsWith('https://www.bilibili.com/video/')) {
    GM_addStyle("body[video-fit] #bilibili-player video { object-fit: cover; } .bpx-player-ctrl-setting-fit-mode { display: flex;width: 100%;height: 32px;line-height: 32px; } .bpx-player-ctrl-setting-box .bui-panel-wrap, .bpx-player-ctrl-setting-box .bui-panel-item { min-height: 172px !important; }");
    let timer;
    function toggleMode(enabled) {
        if (enabled) {
            document.body.setAttribute('video-fit', '');
        } else {
            document.body.removeAttribute('video-fit');
        }
    }
    function injectButton() {
        if (!document.querySelector('.bpx-player-ctrl-setting-menu-left')) {
            return;
        }
        clearInterval(timer);
        const parent = document.querySelector('.bpx-player-ctrl-setting-menu-left');
        const item = document.createElement('div');
        item.className = 'bpx-player-ctrl-setting-fit-mode bui bui-switch';
        item.innerHTML = '<input class="bui-switch-input" type="checkbox"><label class="bui-switch-label"><span class="bui-switch-name">裁切模式</span><span class="bui-switch-body"><span class="bui-switch-dot"><span></span></span></span></label>';
        parent.insertBefore(item, document.querySelector('.bpx-player-ctrl-setting-more'));
        document.querySelector('.bpx-player-ctrl-setting-fit-mode input').addEventListener('change', e => toggleMode(e.target.checked));
        document.querySelector('.bpx-player-ctrl-setting-box .bui-panel-item').style.height = '';
    }
    timer = setInterval(injectButton, 200);
}

// 去掉 B 站的傻逼上报
!function(){
    unsafeWindow.MReporter = {
        appear(){},
        tech(){},
        pv(){},
        import: { auto(){} },
    }
    unsafeWindow.navigator.sendBeacon = function(){}
    const sentryHub = class{ bindClient(){} }
    const fakeSentry = {
        SDK_NAME: 'sentry.javascript.browser',
        SDK_VERSION: '0.0.0',
        BrowserClient: class{},
        Hub: sentryHub,
        Integrations: { Vue: class{} },
        init(){},
        configureScope(){},
        getCurrentHub: () => new sentryHub(),
        setContext(){},
        setExtra(){},
        setExtras(){},
        setTag(){},
        setTags(){},
        setUser(){},
        wrap(){},
    }
    if (!unsafeWindow.Sentry || unsafeWindow.Sentry.SDK_VERSION !== fakeSentry.SDK_VERSION) {
        if (unsafeWindow.Sentry) { delete unsafeWindow.Sentry }
        Object.defineProperty(unsafeWindow, 'Sentry', { value: fakeSentry, enumerable: false, writable: false });
    }
}()

```
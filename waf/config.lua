--WAF config file,enable = "on",disable = "off"

--waf status
config_waf_enable = "on"
--log dir
config_log_dir = "/data/wwwlogs"
-- rule setting
-- your dir
config_rule_dir = "/usr/local/openresty/nginx/conf/waf/wafconf"
--enable/disable white url
config_white_url_check = "on"
--enable/disable white ip
config_white_ip_check = "on"
--enable/disable block ip
config_black_ip_check = "on"
--enable/disable url filtering
config_url_check = "on"
--enalbe/disable url args filtering
config_url_args_check = "on"
--enable/disable user agent filtering
config_user_agent_check = "on"
--enable/disable cookie deny filtering
config_cookie_check = "on"
--enable/disable cc filtering
config_cc_check = "on"
--cc rate the xxx of xxx seconds
config_cc_rate = "60/60"
--enable/disable post filtering
config_post_check = "on"
--config waf output redirect/html
config_waf_output = "html"
--if config_waf_output ,setting url
config_waf_redirect_url = "/captcha"
config_waf_captcha_html=[[
<html>
        <head>
                <meta http-equiv="content-type" content="text/html; charset=UTF-8">
                <title data-sw-translate>Please enter verification code - OneinStack WAF</title>
                <style>
                        body { font-family: Tahoma, Verdana, Arial, sans-serif; }
                        .head_title{margin-top:100px; font-family:"微软雅黑"; font-size:50px; font-weight:lighter;}
                        p{font-family:"微软雅黑"; font-size:16px; font-weight:lighter; color:#666666;}
                        .btn{ float:left;margin-left:15px; margin-top:5px; width:85px; height:30px; background:#56c458;font-family:"微软雅黑"; font-size:16px; color:#FFFFFF; border:0;}
                        .inp_s{ float:left; margin-left:15px; margin-top:5px; width:200px; height:30px;}
                        .yz{float:left; width:160px; height:40px;}
                        .fors{ margin:0 auto;width:500px; height:40px;}
                .form {width: 500px; margin: 2em auto;}
        </style>
        </head>
        <body>
                <div align="center">
                        <p>
                                <h1 class="head_title" data-sw-translate>Sorry...</h1>
                        </p>
                        <p data-sw-translate>Your query looks similar to an automated request from computer software. In order to protect
                                our users, please forgive us for temporarily not processing your request.</p>
                        <p data-sw-translate>To continue accessing the webpage, please enter the characters shown below:</p>
                        <div class="form">
                                <img id="captcha-img" class="yz" src="https://oneinstack.com/api/v1/captcha/BrqDr57p3mjj0xAuEQEW.png" alt="Captcha image">
                                <input id="captcha-input" class="inp_s" type="text" name="response" />
                                <input id="captcha-id" class="inp_s" type="hidden" name="response" />
                                 <input id="captcha-submit" class="btn" type="submit"
                                 data-sw-translate value="Submit" />
                        </div>
                </div>
                <script src="https://cdn.bootcss.com/jquery/3.3.1/jquery.min.js"></script>
                <script>
                        let captcha_id = ''
                        var url = 'https://oneinstack.com/api/v1/captcha'
                        var urlimg = 'https://oneinstack.com/api/v1'
                        // 获取验证码 hash
                        getImg()
                        function getImg() {
                                $.get(url).then((res) => {
                                        $('#captcha-img').attr('src', urlimg + res.data.image_url)
                                        $('#captcha-id').val(res.data.captcha_id)
                                })
                        }
                        $('#captcha-img').on('click',function(e) {
                                getImg()
                        })
                        $('#captcha-submit').on('click', function(e) {
                                var data = {
                                        captcha_id: $('#captcha-id').val(),
                                        captcha_code: document.querySelector('#captcha-input').value,
                                }

                $.ajax({
                    url: `${url}/verify`,
                    type: 'post',
                    dataType: 'json',
                                        contentType: 'application/json',
                    data: JSON.stringify(data),
                                        cache: false,
                    success: function(res){
                                                var targetUrl = new URLSearchParams(location.search).get('continue')
                                                targetUrl = atob(targetUrl)
                                                location.href = targetUrl
                    },
                    error: function(e) {
                                                location.reload()
                    }
                })

                        })
                        window.SwaggerTranslator = {
                                _words: [],
                                translate: function() {
                                        var $this = this;
                                        $('[data-sw-translate]').each(function() {
                                                $(this).html($this._tryTranslate($(this).html()));
                                                $(this).val($this._tryTranslate($(this).val()));
                                                $(this).attr('title', $this._tryTranslate($(this).attr('title')));
                                        });
                                },

                                _tryTranslate: function(word) {
                                        return this._words[$.trim(word)] !== undefined ? this._words[$.trim(word)] : word;
                                },

                                learn: function(wordsMap) {
                                        this._words = wordsMap;
                                }
                        };

                        window.SwaggerTranslator.learn({
                                "Please enter verification code - OneinStack WAF": "输入验证码 - OneinStack防火墙",
                                "Your query looks similar to an automated request from computer software. In order to protect our users, please forgive us for temporarily not processing your request.": "您的查询看起来类似于来自计算机软件的自动请求。为了保护我们的用户，请原谅我们现在暂时不能处理您的请求。",
                                "To continue accessing the webpage, please enter the characters shown below:": "要继续访问网页，请输入下面所示字符：",
                                "Sorry...": "很抱歉...",
                                "Submit": "提交",
                        });

                        $(function() {
                                window.SwaggerTranslator.translate();
                        });
                </script>
        </body>
</html>
]]
config_output_html=[[
<html xmlns="http://www.w3.org/1999/xhtml"><head>
<meta http-equiv="Content-Type" content="text/html; charset=utf-8">
<title>网站防火墙</title>
<style>
p {
        line-height:20px;
}
ul{ list-style-type:none;}
li{ list-style-type:none;}
</style>
</head>
<body style=" padding:0; margin:0; font:14px/1.5 Microsoft Yahei, 宋体,sans-serif; color:#555;">
 <div style="margin: 0 auto; width:1000px; padding-top:70px; overflow:hidden;">
  <div style="width:600px; float:left;">
    <div style=" height:40px; line-height:40px; color:#fff; font-size:16px; overflow:hidden; background:#6bb3f6; padding-left:20px;">网站防火墙 </div>
    <div style="border:1px dashed #cdcece; border-top:none; font-size:14px; background:#fff; color:#555; line-height:24px; height:220px; padding:20px 20px 0 20px; overflow-y:auto;background:#f3f7f9;">
      <p style=" margin-top:0px; margin-bottom:0px; margin-left:0px; margin-right:0px; -qt-block-indent:0; text-indent:0px;"><span style=" font-weight:600; color:#fc4f03;">您的请求带有不合法参数，已被网站管理员设置拦截！</span></p>
      <p style=" margin-top:0px; margin-bottom:0px; margin-left:0px; margin-right:0px; -qt-block-indent:0; text-indent:0px;">可能原因：您提交的内容包含危险的攻击请求</p>
      <p style=" margin-top:12px; margin-bottom:12px; margin-left:0px; margin-right:0px; -qt-block-indent:1; text-indent:0px;">如何解决：</p>
      <ul style="margin-top: 0px; margin-bottom: 0px; margin-left: 0px; margin-right: 0px; -qt-list-indent: 1;"><li style=" margin-top:12px; margin-bottom:0px; margin-left:0px; margin-right:0px; -qt-block-indent:0; text-indent:0px;">1）检查提交内容；</li>
      <li style=" margin-top:0px; margin-bottom:0px; margin-left:0px; margin-right:0px; -qt-block-indent:0; text-indent:0px;">2）如网站托管，请联系空间提供商；</li>
      <li style=" margin-top:0px; margin-bottom:0px; margin-left:0px; margin-right:0px; -qt-block-indent:0; text-indent:0px;">3）普通网站访客，请联系网站管理员；</li></ul>
    </div>
  </div>
</div>
</body></html>
]]

config_wechat_qq_output_html=[[
<!DOCTYPE html><html lang="en"> <head> <meta charset="utf-8"> <meta name="viewport" content="width=device-width, initial-scale=1.0"> <meta http-equiv="X-UA-Compatible" content="ie=edge" > <title>打开提示</title> <style> * { padding: 0; margin: 0; } body, html { height: 100%; background: #eee; } .alert { display: block; } .alert > .couvers { position: fixed; left: 0; right: 0; bottom: 0; top: 0; width: 100%; height: 100%; background: #000; filter: alpha(opacity=44); z-index: 1000; opacity: 0.44; } .alert > .body { position: fixed; left: 0; top: 0; right: 0; bottom: 0; z-index: 10000; color: #fff; } .tips-text { text-align: center; margin-top: 25%; } .tips-toward { position: fixed; right: 28px; top: 10px; } </style> </head> <body> <div class="alert"> <div class="couvers"></div> <div class="body"> <img class="tips-toward" src="data:image/png;base64,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" alt="" /> <div class="tips-text"> 微信QQ用户请在右上角选择"在浏览器打开" </div> </div> </div> </body></html>
]]

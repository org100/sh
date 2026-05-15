RN racknerd IPV6 修复 和 docker ufw 冲突修复 docker容器最好使用host网络  这样就不用修复docker ufw 冲突修复
https://github.com/bfmen/WorkeVl2sb 项目 用dom.txt
# wificalling.json 用于电脑版本的 v2rayn

在 v2rayN 中添加订阅

不同的 v2rayN 版本界面可能略有细微差别（以下以主流的 6.x 版本为例）：

打开 v2rayN，点击顶部菜单栏的 “设置” -> “路由设置”。

确保勾选了界面上方的 “高级路由”。

在这个窗口的底部或顶部，找到并点击 “自定义规则订阅”（或者叫“订阅规则”）。

在弹出的窗口中，点击 “添加”。

填写信息：

别名 (Remarks): 填 WiFi-Calling

Url: 粘贴你刚才在 GitHub 复制的 Raw 链接。

添加完成后，右键点击这条你刚建好的订阅，选择 “更新订阅”（或者点击界面上的“下载/更新”按钮）。如果提示下载成功，说明 v2rayN 已经成功读取了你的 GitHub 规则。

总结一下：电脑 v2rayn 分享socks5 端口给手机

普通上网 ➡️ 电脑开“允许局域网”，手机连同路由填代理，不开 TUN。

Wi-Fi Calling ➡️ 电脑开热点，v2rayN 开启 TUN，手机连热点不填代理。

# wifi-call.list  用于shadowrocket 规则集合

# xray的 wifi-call config 配置方法

插入到你 config.json 的 "routing" -> "rules" 数组中 下面是整个 routing 段

```
"routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "network": "udp", "port": 443, "outboundTag": "block" },
      { "type": "field", "domain": ["geosite:category-ads-all"], "outboundTag": "block" },
      
      {
        "type": "field",
        "outboundTag": "proxy",
        "domain": [
          "domain:gspe1-ssl.ls.apple.com",
          "domain:entsrv-uk.vodafone.com",
          "domain:vuk-gto.prod.ondemandconnectivity.com",
          "domain:attwifi.com",
          "domain:vzwwo.com",
          "domain:pub.3gppnetwork.org",
          "keyword:epdg.epc.mnc"
        ],
        "ip": [
          "31.94.0.0/16",
          "46.68.0.0/17",
          "88.82.0.0/19",
          "87.194.0.0/16",
          "208.54.0.0/16",
          "66.94.0.0/19"
        ]
      },

      { "type": "field", "ip": ["geoip:private", "geoip:cn"], "outboundTag": "direct" },
      { "type": "field", "domain": ["geosite:cn"], "outboundTag": "direct" },
      { "type": "field", "domain": ["geosite:netflix", "geosite:youtube", "geosite:openai", "geosite:google", "geosite:geolocation-!cn"], "outboundTag": "proxy" },
      { "type": "field", "network": "tcp,udp", "outboundTag": "proxy" }
    ]
  }
}
```

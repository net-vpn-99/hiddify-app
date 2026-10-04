#!/usr/bin/env python3
"""把 hiddify-core .aar 里写死的「国内名单」下载地址换成我们自己的。

为什么：安卓核心（hiddify-core v4.1.0）不执行订阅里的分流规则，自己重建路由；
地区=中国时它加「geosite-cn / geoip-cn → 直连」，名单写死从
raw.githubusercontent.com/hiddify/hiddify-geo 下载。那份 geosite-cn 很不全 ——
B 站、QQ、微信、淘宝都不在里面（2026-09-28 用 sing-box rule-set match 实测），
于是这些国内网站照样走代理。

换成源站上跟 iOS 订阅同一份的 SagerNet 名单（/rules/ 下，子目录里是软链）。
Go 字符串是「指针 + 长度」，只要新地址和旧地址**一样长**，原地替换字节就是安全的；
每个 .so 里每个地址必须恰好出现一次，否则直接让构建失败，不带着没换成的核心出包。

名单下载走代理节点（download_detour = select），国内封不封这个域名不影响；
但**换 API 域名时这里也要跟着改**（见 VPN 仓库 docs/域名与被墙.md）。
"""
import sys
import zipfile

OLD_BASE = "https://raw.githubusercontent.com/hiddify/hiddify-geo/rule-set/country/"
NEW_BASE = "https://api-hk.paperkiln.download/rules/oneray-hiddify-core-v4.1.0-patch01/"

PAIRS = [
    (OLD_BASE + "geosite-", NEW_BASE + "geosite-"),
    (OLD_BASE + "geoip-", NEW_BASE + "geoip-"),
]


def patch(aar_path: str) -> None:
    for old, new in PAIRS:
        assert len(old) == len(new), f"长度不一致 {len(old)} != {len(new)}: {new}"

    with zipfile.ZipFile(aar_path) as z:
        entries = [(info, z.read(info.filename)) for info in z.infolist()]

    patched = 0
    out = []
    for info, data in entries:
        if info.filename.endswith(".so"):
            for old, new in PAIRS:
                n = data.count(old.encode())
                if n != 1:
                    sys.exit(f"{info.filename}: '{old}' 出现 {n} 次（应为 1），核心版本变了？")
                data = data.replace(old.encode(), new.encode())
            patched += 1
            print(f"patched {info.filename}")
        out.append((info, data))

    if patched == 0:
        sys.exit("aar 里没有 .so")

    with zipfile.ZipFile(aar_path, "w", zipfile.ZIP_DEFLATED) as z:
        for info, data in out:
            z.writestr(info, data, compress_type=info.compress_type)
    print(f"ok: {patched} 个 .so 已换成 {NEW_BASE}")


if __name__ == "__main__":
    patch(sys.argv[1] if len(sys.argv) > 1 else "android/app/libs/hiddify-core.aar")

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/smart_split/model/classifier.dart';
import 'package:hiddify/features/smart_split/model/public_suffix.dart';
import 'package:hiddify/features/smart_split/model/thing_list.dart';

/// 采集结果怎么归成「东西」（VPN 仓库 docs/计划/智能分流-自己改网站.md 三.2，安卓没有地址栏：
/// 主网页 = 采集开始后浏览器里第一个出现的、不在名单里的主域名）。
/// 跑法：flutter test test/features/smart_split
void main() {
  final psl = PublicSuffix.parse(File('assets/split/public_suffix_list.dat').readAsStringSync());
  final list = ThingList.parse('''
{"version":5,
 "things":[
  {"id":"google","name":"谷歌","domains":["google.com","gstatic.com"],"lock":"proxy"},
  {"id":"wechat","name":"微信","domains":["weixin.qq.com"],"lock":"direct","apps":["weixin","com.tencent.mm"]},
  {"id":"bilibili","name":"哔哩哔哩","domains":["bilibili.com","hdslb.com"]},
  {"id":"microsoft","name":"微软","domains":["microsoft.com"]},
  {"id":"bing","name":"必应","domains":["bing.com"]},
  {"id":"steam","name":"Steam","domains":["steampowered.com"],"lock":"split","apps":["steam","com.valvesoftware.android.steam.community"]}
 ],
 "shared":["jsdelivr.net"],
 "must":{"proxy":["akamaihd.net","blocked-site.com"],"direct":[]}}
''')!;

  List<SplitThing> run(List<Conn> conns) =>
      classify(conns, list, psl, ownDomains: const ['tinwharf.stream'], appName: (p) => 'App($p)');

  Conn c(String pkg, String host, [String out = 'proxy']) => Conn(id: host, pkg: pkg, host: host, outbound: out);

  test('Chrome 打开 btsj6：主网址一组，图片网址归进去，现在走光速雷达', () {
    final r = run([c('com.android.chrome', 'www.btsj6.com'), c('com.android.chrome', 'imgb.anycip.com')]);
    final t = r.single;
    expect(t.key, 'site:btsj6.com');
    expect(t.kind, 'site');
    expect(t.name, 'btsj6.com');
    expect(t.domains, ['anycip.com', 'btsj6.com']);
    expect(t.now, 'proxy');
  });

  test('Edge 自己的微软、必应连接不列；夸克一样认出主网页', () {
    final edge = run([
      c('com.microsoft.emmx', 'nav-edge.smartscreen.microsoft.com'),
      c('com.microsoft.emmx', 'c.bing.com'),
      c('com.microsoft.emmx', 'www.btsj6.com'),
    ]);
    expect(edge.map((t) => t.key), ['site:btsj6.com']);
    final quark = run([c('com.quark.browser', 'm.btsj6.com', 'direct')]);
    expect(quark.single.key, 'site:btsj6.com');
    expect(quark.single.now, 'direct');
  });

  test('名单里的网站照名单归，锁住的进不能改', () {
    final r = run([c('com.android.chrome', 'www.google.com'), c('com.android.chrome', 'www.bilibili.com', 'direct')]);
    final g = r.firstWhere((t) => t.key == 'id:google');
    expect(g.kind, 'locked');
    expect(g.lockWhy, '只能走光速雷达');
    final b = r.firstWhere((t) => t.key == 'id:bilibili');
    expect(b.kind, 'site');
    expect(b.now, 'direct');
    expect(r.last.kind, 'locked'); // 能选的在前
  });

  test('迅雷是锁住的下载软件，ADM 是能改的下载器', () {
    final r = run([c('com.xunlei.downloadprovider', '1.2.3.4', 'direct'), c('com.dv.adm', 'files.example.com', 'direct')]);
    final x = r.firstWhere((t) => t.pkg == 'com.xunlei.downloadprovider');
    expect(x.kind, 'locked');
    expect(x.lockWhy, '下载软件，只能走本地');
    final adm = r.firstWhere((t) => t.pkg == 'com.dv.adm');
    expect(adm.kind, 'downloader');
    expect(adm.now, 'direct');
  });

  test('微信（App 和它里面的网页）进不能改，只能走本地', () {
    final r = run([c('com.tencent.mm', 'extshort.weixin.qq.com', 'direct'), c('com.tencent.mm', 'mp.weixinbridge.com', 'direct')]);
    final w = r.single;
    expect(w.key, 'id:wechat');
    expect(w.kind, 'locked');
    expect(w.lockWhy, '只能走本地');
  });

  test('App 锁成只能国内外分开走', () {
    final r = run([c('com.valvesoftware.android.steam.community', 'store.steampowered.com')]);
    expect(r.single.lockWhy, '只能国内外分开走');
  });

  test('普通 App 有走光速雷达的连接才列，名字用 App 名', () {
    final r = run([c('com.example.game', 'api.game.com'), c('com.example.cn', 'api.cn-app.com', 'direct')]);
    final g = r.single;
    expect(g.key, 'app:com.example.game');
    expect(g.kind, 'app');
    expect(g.name, 'App(com.example.game)');
    expect(g.now, 'split');
  });

  test('系统组件、我们自己、面板域名、只有 IP 的都不列', () {
    final r = run([
      c('android', 'connectivitycheck.gstatic.com'),
      c('com.google.android.gms', 'play.googleapis.com'),
      c('com.google.android.webview', 'www.btsj6.com'),
      c('com.heytap.cloud', 'cloud.heytap.com'),
      c('com.oneray.app', 'api.tinwharf.stream'),
      c('com.android.chrome', 'api.tinwharf.stream'),
      c('com.android.chrome', '198.18.0.25'),
    ]);
    expect(r, isEmpty);
  });

  test('公共资源不并进网站，也不列；别的网站里的「必须」网址不并进来', () {
    final r = run([
      c('com.android.chrome', 'www.btsj6.com'),
      c('com.android.chrome', 'cdn.jsdelivr.net'),
      c('com.android.chrome', 'a248.e.akamaihd.net'),
    ]);
    expect(r.single.domains, ['btsj6.com']);
  });

  test('主网页本身是「必须」网址：照样列，进不能改', () {
    final r = run([c('com.android.chrome', 'www.blocked-site.com')]);
    expect(r.single.kind, 'locked');
    expect(r.single.lockWhy, '只能走光速雷达');
  });

  test('新采到的排上面', () {
    final r = run([c('com.example.a', 'a.com'), c('com.example.b', 'b.com')]);
    expect(r.map((t) => t.pkg), ['com.example.b', 'com.example.a']);
  });

  test('alwaysShow 里的 App 全走本地也列', () {
    final r = classify([c('com.example.cn', 'api.cn-app.com', 'direct')], list, psl,
        ownDomains: const [], appName: (p) => p, alwaysShow: {'app:com.example.cn'});
    expect(r.single.key, 'app:com.example.cn');
  });
}

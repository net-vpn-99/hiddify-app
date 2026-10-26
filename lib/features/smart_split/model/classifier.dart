import 'package:hiddify/features/smart_split/model/public_suffix.dart';
import 'package:hiddify/features/smart_split/model/thing_list.dart';

/// box.log 里拼出来的一条连接：哪个 App、去哪个网址、最后走了哪边（direct / proxy）。
class Conn {
  const Conn({required this.id, required this.pkg, required this.host, required this.outbound});

  final String id;
  final String pkg;
  final String host;
  final String outbound;
}

/// 采集结果里的一行（VPN 仓库 docs/计划/智能分流-自己改网站.md 三.2 那张表）。
class SplitThing {
  SplitThing({required this.key});

  /// id:<名单 id> / site:<主域名> / app:<包名> / p2p:<包名>
  final String key;

  /// site / app / downloader / locked
  String kind = '';
  String name = '';

  /// 名字后面括号里的主域名；App 为空
  String host = '';

  /// App 的包名；网站为空
  String pkg = '';

  /// 选了以后写进规则的主域名（排好序）；App 为空
  List<String> domains = [];

  /// 现在实际走哪边：direct / proxy；App 没改过是 split
  String now = '';

  /// 不能改的原因（locked）
  String lockWhy = '';
}

/// 浏览器（包名）。在这些里打开的陌生网址归到「刚才打开的那个网页」。
const browserPackages = {
  'com.android.chrome', 'com.chrome.beta', 'com.microsoft.emmx', 'org.mozilla.firefox',
  'com.sec.android.app.sbrowser', 'com.quark.browser', 'com.UCMobile', 'com.huawei.browser',
  'com.hihonor.baidu.browser', 'com.mi.globalbrowser', 'com.android.browser', 'com.vivo.browser',
  'com.heytap.browser', 'com.coloros.browser', 'com.opera.browser', 'com.brave.browser',
  'com.tencent.mtt', 'sogou.mobile.explorer', 'com.qihoo.browser',
  // 审查补的：不在名单里的浏览器会整个当成一个 App，选「整个走本地」就把整个浏览器排除了
  'mark.via', 'mark.via.gp', 'org.mozilla.focus', 'org.mozilla.klar', 'org.mozilla.firefox_beta',
  'com.duckduckgo.mobile.android', 'com.opera.mini.native', 'com.opera.gx', 'com.kiwibrowser.browser',
  'com.chrome.dev', 'com.chrome.canary', 'com.microsoft.emmx.beta', 'com.yandex.browser', 'com.vivaldi.browser',
};

/// 浏览器自己后台连的（Edge 的微软、必应）：用户没打开它们，不列出。谷歌是锁着的，列在「不能改」里不碍事。
const _browserOwnThings = {
  'com.microsoft.emmx': {'microsoft', 'bing'},
  'org.mozilla.firefox': {'mozilla'},
  'org.mozilla.firefox_beta': {'mozilla'},
  'org.mozilla.focus': {'mozilla'},
  'org.mozilla.klar': {'mozilla'},
  'com.microsoft.emmx.beta': {'microsoft', 'bing'},
  'com.sec.android.app.sbrowser': {'samsung'},
  'com.huawei.browser': {'huawei'},
  'com.mi.globalbrowser': {'xiaomi'},
  'com.vivo.browser': {'vivo'},
  'com.heytap.browser': {'oppo'},
  'com.coloros.browser': {'oppo'},
  'com.UCMobile': {'uc', 'alibaba'},
  'com.quark.browser': {'uc', 'alibaba'},
};

/// BT / 迅雷类：锁死走本地（跟 VPNService.kt btPackages 一样）。
const btPackages = {
  'com.xunlei.downloadprovider', 'com.bittorrent.client', 'com.utorrent.client',
  'org.proninyaroslav.libretorrent', 'com.frostwire.android', 'com.biglybt.android.client',
};

/// 普通下载器：默认走本地，能改成「智能分流」（跟 VPNService.kt plainDownloaderPackages 一样）。
const plainDownloaderPackages = {
  'com.dv.adm', 'com.dv.adm.pay', 'idm.internet.download.manager', 'idm.internet.download.manager.plus',
  'com.gopeed.gopeed',
};

/// 我们自己的包名。
const ownPackage = 'com.oneray.app';

/// 崩溃上报、统计、广告。浏览器里会比网页本身先连上，不能拿来当这一页的名字
/// （10-27 实测：打开 BT世界网，先连到 sentry.io，名字就成了 sentry.io，btsj6.com 被收进关联网址）。
const _notThePage = {
  'sentry.io', 'appcenter.ms', 'crashlytics.com', 'bugsnag.com',
  'google-analytics.com', 'googletagmanager.com', 'doubleclick.net', 'googlesyndication.com', 'googleadservices.com',
  'facebook.net', 'scorecardresearch.com', 'hotjar.com', 'segment.io', 'segment.com', 'mixpanel.com', 'amplitude.com', 'newrelic.com',
};

/// 像用户打开的那个网页：主域名本身，或 www / m。图片站、上报接口是别的子域名，不当这一页的名字。
bool _looksLikePage(String host, String reg) {
  if (_notThePage.contains(reg)) return false;
  return host == reg || host == 'www.$reg' || host == 'm.$reg' || host == 'mobile.$reg';
}

/// ① 不列出：系统、手机厂商自带的服务、别的 App 里嵌的网页（认不出是谁的）、我们自己。浏览器先认，不受这里影响。
const _hiddenPrefixes = [
  'android.', 'com.android.', 'com.google.android.gms', 'com.google.android.gsf', 'com.google.process',
  'com.oplus.', 'com.coloros.', 'com.heytap.', 'com.oppo.', 'com.huawei.', 'com.hihonor.', 'com.miui.',
  'com.xiaomi.', 'com.vivo.', 'com.bbk.', 'com.iqoo.', 'com.samsung.', 'com.sec.', 'com.meizu.',
  'com.qualcomm.', 'com.mediatek.',
];
const _hiddenPackages = {'android', ownPackage, 'com.google.android.webview', 'com.android.webview'};

bool _hidden(String pkg) => _hiddenPackages.contains(pkg) || _hiddenPrefixes.any(pkg.startsWith);

/// 存账号一组最多这么多个网址（服务器 RouteRules::MAX_DOMAINS）。
const _maxThingDomains = 30;

final _domainRe = RegExp(r'^[a-z0-9-]+(\.[a-z0-9-]+)+$');
final _ipv4Re = RegExp(r'^[0-9.]+$');

/// 像样的域名（字母数字、-、.）；IP 算没有域名。
String _usableDomain(String host) {
  final h = host.toLowerCase();
  if (h.isEmpty || h.contains(':') || _ipv4Re.hasMatch(h) || !_domainRe.hasMatch(h)) return '';
  return h;
}

bool _isOwn(String domain, List<String> own) => own.any((o) => domain == o || domain.endsWith('.$o'));

class _Group {
  _Group(this.thing, this.first);

  final SplitThing thing;
  final int first;
  Thing? known;
  int direct = 0;
  int proxy = 0;

  void vote(String outbound) => outbound == 'direct' ? direct++ : proxy++;

  /// 一组连接里走得多的那边；一样多算光速雷达。
  String get now => direct > proxy ? 'direct' : 'proxy';
}

void _setFromThing(_Group g, Thing known) {
  final t = g.thing;
  g.known = known;
  t.name = known.name;
  switch (known.lock) {
    case 'proxy':
      t.kind = 'locked';
      t.lockWhy = '只能走光速雷达';
    case 'direct':
      t.kind = 'locked';
      t.lockWhy = '只能走本地';
    case 'split':
      t.kind = 'locked';
      t.lockWhy = '只能国内外分开走';
    default:
      t.kind = 'site';
  }
}

/// 连过的网址落在名单这个东西的哪个网址下（login.live.com → live.com），记进这一组；第一个记下的当主网址。
void _addSeenDomain(_Group g, String host) {
  final known = g.known;
  if (known == null || host.isEmpty) return;
  var h = host;
  while (h.contains('.')) {
    if (known.domains.contains(h)) {
      if (!g.thing.domains.contains(h)) g.thing.domains.add(h);
      if (g.thing.host.isEmpty) g.thing.host = h;
      return;
    }
    h = h.substring(h.indexOf('.') + 1);
  }
}

/// 按计划书三.2 的顺序归类：① 不列出 → ② 公共资源 → ③ App → ④ 名单里的 → ⑤ 浏览器里剩下的归到网页 → ⑥ 只有 IP。
/// [conns] 按出现先后排。返回顺序：能选的新采到的在上面，然后锁定的。
/// [alwaysShow]：改过的、这次已经列出过的 key，全走本地的 App 也照样列。
List<SplitThing> classify(
  List<Conn> conns,
  ThingList list,
  PublicSuffix psl, {
  required List<String> ownDomains,
  required String Function(String pkg) appName,
  Set<String> alwaysShow = const {},
}) {
  final groups = <String, _Group>{};
  _Group group(String key, int seq) => groups.putIfAbsent(key, () => _Group(SplitThing(key: key), seq));
  final pageOf = <String, String>{}; // 浏览器包名 → 这一页的主域名（www / m，不是先连上的统计域名）
  // 主网页还没出现时先看到的图片站、统计。等主网页出现再归进去。
  final held = <String, List<(int, String, String)>>{};

  void attach(String owner, int seq, String reg, String outbound) {
    if (reg != owner && list.mustLock(reg).isNotEmpty) return;
    final g = group('site:$owner', seq);
    final t = g.thing;
    final must = list.mustLock(owner);
    t
      ..kind = must.isEmpty ? 'site' : 'locked'
      ..lockWhy = must == 'proxy' ? '只能走光速雷达' : (must == 'direct' ? '只能走本地' : '')
      ..name = owner
      ..host = owner;
    if (!t.domains.contains(reg)) t.domains.add(reg);
    g.vote(outbound);
  }

  for (var i = 0; i < conns.length; i++) {
    final c = conns[i];
    final pkg = c.pkg;
    if (pkg.isEmpty) continue; // 不知道是谁的，多半是系统自己的连接
    final browser = browserPackages.contains(pkg);
    if (!browser && _hidden(pkg)) continue;
    final domain = _usableDomain(c.host);
    if (domain.isNotEmpty && _isOwn(domain, ownDomains)) continue;

    // ③ 不是浏览器的 App：整个 App 一组
    if (!browser) {
      final known = list.matchApp(pkg);
      if (known != null && (known.domains.isNotEmpty || known.lock.isNotEmpty)) {
        final g = group('id:${known.id}', i);
        _setFromThing(g, known);
        _addSeenDomain(g, domain);
        g.vote(c.outbound);
        continue;
      }
      if (btPackages.contains(pkg)) {
        final t = group('p2p:$pkg', i).thing
          ..name = appName(pkg)
          ..pkg = pkg
          ..kind = 'locked'
          ..lockWhy = '下载软件，只能走本地'
          ..now = 'direct';
        assert(t.key.isNotEmpty);
        continue;
      }
      final g = group('app:$pkg', i);
      g.thing
        ..name = appName(pkg)
        ..pkg = pkg
        ..kind = plainDownloaderPackages.contains(pkg) ? 'downloader' : 'app'
        ..now = plainDownloaderPackages.contains(pkg) ? 'direct' : 'split';
      g.vote(c.outbound);
      continue;
    }

    // ⑥ 只有 IP、② 公共资源：不列出
    if (domain.isEmpty || list.isShared(domain)) continue;
    // ④ 名单里的照名单归（浏览器自己后台连的不算）
    final known = list.match(domain);
    if (known != null) {
      if (_browserOwnThings[pkg]?.contains(known.id) ?? false) continue;
      final g = group('id:${known.id}', i);
      _setFromThing(g, known);
      _addSeenDomain(g, domain);
      g.vote(c.outbound);
      continue;
    }
    // ⑤ 陌生的归到网页。安卓读不到地址栏：主网页是 www / m 这种地址，不是先连上的统计、图片站。
    final reg = psl.registrable(domain);
    final knownOwner = pageOf[pkg];
    if (knownOwner == null && !_looksLikePage(domain, reg)) {
      held.putIfAbsent(pkg, () => []).add((i, reg, c.outbound));
      continue;
    }
    final owner = knownOwner ?? reg;
    if (knownOwner == null) {
      pageOf[pkg] = owner;
      for (final (seq, heldReg, outbound) in held.remove(pkg) ?? const <(int, String, String)>[]) {
        attach(owner, seq, heldReg, outbound);
      }
    }
    attach(owner, i, reg, c.outbound);
  }

  final sorted = groups.values.toList()
    ..sort((a, b) {
      final al = a.thing.kind == 'locked';
      final bl = b.thing.kind == 'locked';
      if (al != bl) return al ? 1 : -1;
      return b.first.compareTo(a.first);
    });
  final out = <SplitThing>[];
  for (final g in sorted) {
    final t = g.thing;
    // 普通 App 全走本地的，选「走本地」也没变化，不列出；改过的、这次列出过的照样列
    if (t.kind == 'app' && g.proxy == 0 && !alwaysShow.contains(t.key)) continue;
    if (t.key.startsWith('site:')) {
      if (!t.domains.contains(t.host)) t.domains.add(t.host);
      t.domains.sort();
    }
    final known = g.known;
    if (known != null) {
      // 只有 App 连过、没对上网址（只有 IP）：退回名单里的前几个
      if (t.domains.isEmpty) t.domains = known.domains.take(_maxThingDomains).toList();
      if (t.host.isEmpty && t.domains.isNotEmpty) t.host = t.domains.first;
      t.domains = t.domains.take(_maxThingDomains).toList()..sort();
    }
    if (t.kind == 'site' || (t.kind == 'locked' && t.pkg.isEmpty)) t.now = g.now;
    out.add(t);
  }
  return out;
}

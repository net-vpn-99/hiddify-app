import 'dart:convert';

/// 东西名单（VPN 仓库 docs/计划/智能分流-自己改网站.md 三.3）：有名的网站 / App 叫什么、有哪些网址、锁没锁。
/// 服务器 `api/v1/guest/gsl_route/things` 下发，App 里带一份种子 assets/split/things-seed.json。格式跟 Windows 一样：
///   {"version":20261025,
///    "things":[{"id":"bilibili","name":"哔哩哔哩","domains":[...],"lock":""|"proxy"|"direct"|"split","apps":[...]}],
///    "shared":[...],
///    "must":{"proxy":[...],"direct":[...]}}
/// `apps` 里电脑软件文件名和安卓包名混放（10-25 计划 3 起），都按小写比。
class Thing {
  const Thing({required this.id, required this.name, this.domains = const [], this.lock = '', this.apps = const []});

  final String id;
  final String name;
  final List<String> domains;

  /// 空 = 能改；proxy = 只能走光速雷达；direct = 只能走本地；split = App 只能国内外分开走
  final String lock;
  final List<String> apps;
}

class ThingList {
  ThingList._(this.version, this._things, this._byDomain, this._byApp, this._shared, this._mustProxy, this._mustDirect);

  final int version;
  final List<Thing> _things;
  final Map<String, int> _byDomain;
  final Map<String, int> _byApp;
  final Set<String> _shared;
  final Set<String> _mustProxy;
  final Set<String> _mustDirect;

  int get size => _things.length;

  /// 读不懂、一个东西都没有返回 null。
  static ThingList? parse(String json) {
    Object? root;
    try {
      root = jsonDecode(json);
    } catch (_) {
      return null;
    }
    if (root is! Map<String, dynamic>) return null;
    List<String> strings(Object? v) =>
        v is List ? [for (final x in v) if (x is String && x.isNotEmpty) x.toLowerCase()] : const <String>[];
    final things = <Thing>[];
    final byDomain = <String, int>{};
    final byApp = <String, int>{};
    for (final v in root['things'] is List ? root['things'] as List : const []) {
      if (v is! Map) continue;
      final t = Thing(
        id: v['id'] is String ? v['id'] as String : '',
        name: v['name'] is String ? v['name'] as String : '',
        lock: v['lock'] is String ? v['lock'] as String : '',
        domains: strings(v['domains']),
        apps: strings(v['apps']),
      );
      // 只有 App、没有网址的也收（后台锁的 App，如 Steam）
      if (t.id.isEmpty || t.name.isEmpty || (t.domains.isEmpty && t.apps.isEmpty)) continue;
      // 一个网址只归一个东西：名单生成时已经去重，这里先到先得
      for (final d in t.domains) {
        byDomain.putIfAbsent(d, () => things.length);
      }
      for (final a in t.apps) {
        byApp.putIfAbsent(a, () => things.length);
      }
      things.add(t);
    }
    if (things.isEmpty) return null;
    final must = root['must'] is Map ? root['must'] as Map : const {};
    final version = root['version'];
    return ThingList._(
      version is int ? version : 0,
      things,
      byDomain,
      byApp,
      strings(root['shared']).toSet(),
      strings(must['proxy']).toSet(),
      strings(must['direct']).toSet(),
    );
  }

  /// 按网址后缀找：szminorshort.weixin.qq.com 依次查 weixin.qq.com、qq.com…，找到第一个就是。
  Thing? match(String host) {
    for (final s in _suffixes(host)) {
      final i = _byDomain[s];
      if (i != null) return _things[i];
    }
    return null;
  }

  /// 共用名单（CDN、统计、人机验证…）里的，后缀匹配。
  bool isShared(String host) => _suffixes(host).any(_shared.contains);

  /// 按 App 包名（或电脑软件文件名）找。
  Thing? matchApp(String pkg) {
    var name = pkg.toLowerCase();
    if (name.endsWith('.exe')) name = name.substring(0, name.length - 4);
    final i = _byApp[name];
    return i == null ? null : _things[i];
  }

  /// 网址级「必须」，后缀匹配：direct / proxy；不是回空。
  String mustLock(String host) {
    if (_suffixes(host).any(_mustDirect.contains)) return 'direct';
    if (_suffixes(host).any(_mustProxy.contains)) return 'proxy';
    return '';
  }

  /// 服务器下来的名单比 [now] 新才换：读得懂、版本号更大、没少掉一大半（服务器库被清空过就不换）。
  static ThingList? pickNewer(ThingList now, String json) {
    final next = parse(json);
    if (next == null || next.version <= now.version) return null;
    if (now.size >= 20 && next.size < now.size ~/ 2) return null;
    return next;
  }

  /// host 自己、去掉一级、再去掉一级……直到只剩最后一级之前。
  static Iterable<String> _suffixes(String host) sync* {
    var h = host.toLowerCase();
    while (h.contains('.')) {
      yield h;
      h = h.substring(h.indexOf('.') + 1);
    }
  }
}

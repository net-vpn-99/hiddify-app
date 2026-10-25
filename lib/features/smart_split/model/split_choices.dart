import 'dart:convert';

import 'package:hiddify/features/smart_split/model/classifier.dart';
import 'package:hiddify/features/smart_split/model/thing_list.dart';

/// 用户在智能分流里改过的（「我改过的」那一块），存 `<baseDir>/split-choices.json`。
/// 网站那部分也存在账号里：本机先生效，再存账号，synced 记着存上没有。选「默认」= 删掉这一项。
/// 跟 Windows splitchoices.cpp 同一套，App 用包名代替 exe 路径。
class SplitChoice {
  SplitChoice({
    required this.key,
    required this.kind,
    required this.name,
    this.host = '',
    this.domains = const [],
    this.pkg = '',
    required this.choice,
    this.was = '',
    this.synced = false,
  });

  final String key;

  /// site / app / downloader
  final String kind;
  final String name;
  final String host;
  final List<String> domains;
  final String pkg;

  /// site: direct / proxy；app: direct / split；downloader: split
  final String choice;

  /// 网站改之前实际走的那边（direct / proxy），之后选回它 = 改回默认；不知道为空
  String was;

  /// 已经存进账号（App 是已经传给后台）
  bool synced;

  Map<String, dynamic> toJson() => {
    'key': key,
    'kind': kind,
    'name': name,
    'host': host,
    'domains': domains,
    'pkg': pkg,
    'choice': choice,
    if (was.isNotEmpty) 'was': was,
    if (synced) 'synced': true,
  };
}

enum SetResult { ok, full, invalid }

final _domainRe = RegExp(r'^[a-z0-9-]+(\.[a-z0-9-]+)+$');

/// 只留服务器认的网址：一个不合格的网址会让整组存不上。
List<String> validDomains(Iterable<Object?> domains) {
  final out = <String>[];
  for (final d in domains) {
    if (d is! String) continue;
    final lower = d.toLowerCase();
    if (lower.length <= 253 && _domainRe.hasMatch(lower) && !out.contains(lower)) out.add(lower);
  }
  return out;
}

/// 这一类能选哪些（不含 default）。
bool _allowed(String kind, String choice) => switch (kind) {
  'site' => choice == 'direct' || choice == 'proxy',
  // App 选智能分流平时就是默认（删掉）；服务器把它改成默认整个走本地以后，要存下来才盖得住
  'app' => choice == 'direct' || choice == 'split',
  'downloader' => choice == 'split',
  _ => false,
};

/// 选的是不是就是默认（等于删掉这一项）。
bool _isDefault(String kind, String choice) => choice == 'default' || (kind == 'downloader' && choice == 'direct');

class SplitChoices {
  /// 每个账号最多 50 组网站、一组最多 30 个网址（服务器 RouteRules）。App 只存本机，不算在里面。
  static const maxSiteGroups = 50;
  static const maxDomainsPerGroup = 30;

  final List<SplitChoice> _items = [];
  final List<String> _pendingDeletes = [];

  List<SplitChoice> get items => List.unmodifiable(_items);

  /// 删掉的网站 key：账号里删成了再去掉；下次拉列表不会把它拉回来。
  List<String> get pendingDeletes => List.unmodifiable(_pendingDeletes);

  /// 读不懂（坏 JSON、选项不认识）返回 null。
  static SplitChoices? fromJson(String json) {
    try {
      final root = jsonDecode(json) as Map<String, dynamic>;
      final out = SplitChoices();
      for (final v in root['items'] as List? ?? const []) {
        final o = v as Map<String, dynamic>;
        final c = SplitChoice(
          key: o['key'] as String? ?? '',
          kind: o['kind'] as String? ?? '',
          name: o['name'] as String? ?? '',
          host: o['host'] as String? ?? '',
          domains: validDomains(o['domains'] as List? ?? const []),
          pkg: o['pkg'] as String? ?? '',
          choice: o['choice'] as String? ?? '',
          was: o['was'] as String? ?? '',
          synced: o['synced'] == true,
        );
        final site = c.kind == 'site';
        if (c.key.isEmpty || !_allowed(c.kind, c.choice) || (!site && c.pkg.isEmpty)) return null;
        if (site && c.domains.isEmpty) continue; // 网址全不合格：只丢这一组
        out._items.add(c);
      }
      out._pendingDeletes.addAll([for (final k in root['deleted'] as List? ?? const []) if (k is String) k]);
      return out;
    } catch (_) {
      return null;
    }
  }

  String toJson() => jsonEncode({
    'items': [for (final c in _items) c.toJson()],
    if (_pendingDeletes.isNotEmpty) 'deleted': _pendingDeletes,
  });

  /// choice：default / direct / proxy / split。default（下载器的 direct 也是）= 删掉。
  /// was：改之前实际走的那边（只对网站有用，空 = 不知道，已有的照旧留着）。
  SetResult set(SplitThing thing, String choice, {String was = ''}) {
    if (thing.key.isEmpty) return SetResult.invalid;
    if (_isDefault(thing.kind, choice) && (_allowed(thing.kind, 'direct') || _allowed(thing.kind, 'split'))) {
      remove(thing.key);
      return SetResult.ok;
    }
    if (!_allowed(thing.kind, choice)) return SetResult.invalid;
    final site = thing.kind == 'site';
    final domains = validDomains(thing.domains);
    if (site && domains.isEmpty) return SetResult.invalid;
    if (!site && thing.pkg.isEmpty) return SetResult.invalid;
    final i = _items.indexWhere((c) => c.key == thing.key);
    if (i < 0 && site && _items.where((c) => c.kind == 'site').length >= maxSiteGroups) return SetResult.full;
    final c = SplitChoice(
      key: thing.key,
      kind: thing.kind,
      name: thing.name,
      host: thing.host,
      // 超过 30 个时主网址一定留着（审查 4：按字母截会把主网址截掉，规则对不上他选的那个网站）
      domains: site
          ? ([if (domains.contains(thing.host)) thing.host, ...domains.where((d) => d != thing.host)].take(maxDomainsPerGroup).toList()
            ..sort())
          : const [],
      pkg: site ? '' : thing.pkg,
      choice: choice,
      was: was.isNotEmpty ? was : (i >= 0 ? _items[i].was : ''),
    );
    _pendingDeletes.remove(c.key);
    if (i < 0) {
      _items.add(c);
    } else {
      _items[i] = c;
    }
    return SetResult.ok;
  }

  void remove(String key) {
    for (final c in _items) {
      if (c.key == key && c.kind == 'site' && !_pendingDeletes.contains(key)) _pendingDeletes.add(key);
    }
    _items.removeWhere((c) => c.key == key);
  }

  void clear() {
    for (final c in _items) {
      if (c.kind == 'site' && !_pendingDeletes.contains(c.key)) _pendingDeletes.add(c.key);
    }
    _items.clear();
  }

  void markSynced(String key, {bool synced = true}) {
    for (final c in _items) {
      if (c.key == key) c.synced = synced;
    }
  }

  void setItems(List<SplitChoice> items) => _items
    ..clear()
    ..addAll(items);

  void setPendingDeletes(List<String> keys) => _pendingDeletes
    ..clear()
    ..addAll(keys);

  /// 改过的那一项选的是什么；没改过（= 默认）为空。
  String choiceFor(String key) => _items.where((c) => c.key == key).firstOrNull?.choice ?? '';

  String wasFor(String key) => _items.where((c) => c.key == key).firstOrNull?.was ?? '';
}

class MergeResult {
  MergeResult(this.items, this.resend, this.redelete);

  final List<SplitChoice> items;

  /// 本机没存上的网站：再发一次 set
  final List<String> resend;

  /// 没删成、服务器上还在的：再发一次 del
  final List<String> redelete;
}

/// 服务器列表回来后：App / 下载器照本机；已存过的网站被服务器列表整份替换（带上本机的 was）；
/// 本机没存上的留着、进 resend，同 key 时本机的赢；pendingDeletes 里的从服务器列表里拿掉、进 redelete。
MergeResult mergeAccountSites(SplitChoices local, List<SplitChoice> server) {
  final items = <SplitChoice>[];
  final mine = <String, SplitChoice>{};
  for (final c in local.items) {
    if (c.kind != 'site') {
      items.add(c);
    } else {
      mine[c.key] = c;
    }
  }
  final onServer = <String>{};
  for (final s in server) {
    onServer.add(s.key);
    if (local.pendingDeletes.contains(s.key)) continue;
    final m = mine[s.key];
    if (m != null && !m.synced) continue; // 本机没存上的那条赢，下面补发
    items.add(SplitChoice(
      key: s.key, kind: s.kind, name: s.name, host: s.host, domains: s.domains,
      choice: s.choice, was: m?.was ?? '', synced: true,
    ));
  }
  final resend = <String>[];
  for (final c in local.items) {
    if (c.kind == 'site' && !c.synced) {
      items.add(c);
      resend.add(c.key);
    }
  }
  return MergeResult(items, resend, [for (final k in local.pendingDeletes) if (onServer.contains(k)) k]);
}

/// 新名单里锁住的：返回本机要删掉的 key（网站按网址命中锁住的东西或网址级「必须」；App 按包名命中锁）。
List<String> dropLocked(SplitChoices local, ThingList things) {
  final out = <String>[];
  for (final c in local.items) {
    final locked = c.kind == 'site'
        ? things.mustLock(c.host).isNotEmpty || c.domains.any((d) => things.match(d)?.lock.isNotEmpty ?? false)
        // BT / 迅雷类本来就锁死走本地（审查 5）
        : btPackages.contains(c.pkg) || (things.matchApp(c.pkg)?.lock.isNotEmpty ?? false);
    if (locked) out.add(c.key);
  }
  return out;
}

/// 服务器 list 的 data.items → 网站（synced=true）。坏 JSON 返回 null，跟空列表分开；坏网址、选项不认识的项跳过。
List<SplitChoice>? parseAccountList(String body) {
  try {
    final items = ((jsonDecode(body) as Map)['data'] as Map)['items'];
    if (items is! List) return null;
    final out = <SplitChoice>[];
    for (final v in items) {
      if (v is! Map) continue;
      final key = v['key'] is String ? v['key'] as String : '';
      final host = v['host'] is String ? v['host'] as String : '';
      final domains = validDomains(v['domains'] is List ? v['domains'] as List : const []);
      final choice = v['choice'] is String ? v['choice'] as String : '';
      if (key.isEmpty || domains.isEmpty || !_allowed('site', choice)) continue;
      var name = v['name'] is String ? v['name'] as String : '';
      if (name.isEmpty) name = host.isEmpty ? domains.first : host;
      out.add(SplitChoice(key: key, kind: 'site', name: name, host: host, domains: domains, choice: choice, synced: true));
    }
    return out;
  } catch (_) {
    return null;
  }
}

/// 账号里的 key：网站照原样，App / 下载器是 app:<包名>。
String accountKey(SplitChoice c) => c.kind == 'site' ? c.key : 'app:${c.pkg}';

/// set 的 body。App 只带包名和名字。
String routeSetBody(SplitChoice c, String appVer, String deviceId) => jsonEncode({
  'key': accountKey(c),
  'name': c.name,
  if (c.kind == 'site') ...{
    'kind': 'site',
    'host': c.host,
    'domains': c.domains,
    'choice': c.choice,
    // 改之前它实际走哪边：后台「建议改默认」看多数人选的跟这个一不一样
    if (c.was == 'direct' || c.was == 'proxy') 'now': c.was,
  } else ...{
    'kind': 'app',
    'exe': c.pkg,
    'choice': c.kind == 'downloader' ? 'split' : c.choice,
  },
  'platform': 'android',
  if (appVer.isNotEmpty) 'app_ver': appVer,
  if (deviceId.isNotEmpty) 'device_id': deviceId,
});

/// App 在页面上该显示什么选择：改过的照改的；没改过、服务器把它改成默认整个走本地的算 direct，其余 default。
String effectiveAppChoice(String stored, {required bool serverDefaultDirect}) =>
    stored.isNotEmpty ? stored : (serverDefaultDirect ? 'direct' : 'default');

/// 服务器 defaults 的 data：direct / proxy（坏网址去掉）、apps_direct（没有就空）。
class RouteDefaults {
  const RouteDefaults({this.direct = const [], this.proxy = const [], this.appsDirect = const []});

  final List<String> direct;
  final List<String> proxy;
  final List<String> appsDirect;

  String toJson() => jsonEncode({'data': {'direct': direct, 'proxy': proxy, 'apps_direct': appsDirect}});
}

final _appNameRe = RegExp(r'^[a-z0-9._ -]{1,64}$');

/// 读不懂返回 null。
RouteDefaults? parseRouteDefaults(String body) {
  try {
    final data = (jsonDecode(body) as Map)['data'];
    if (data is! Map || data['direct'] is! List || data['proxy'] is! List) return null;
    final apps = <String>[];
    for (final a in data['apps_direct'] is List ? data['apps_direct'] as List : const []) {
      if (a is! String) continue;
      final l = a.toLowerCase();
      if (_appNameRe.hasMatch(l) && !apps.contains(l)) apps.add(l);
    }
    return RouteDefaults(direct: validDomains(data['direct'] as List), proxy: validDomains(data['proxy'] as List), appsDirect: apps);
  } catch (_) {
    return null;
  }
}

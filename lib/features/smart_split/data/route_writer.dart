import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hiddify/features/smart_split/data/route_api.dart';
import 'package:hiddify/features/smart_split/model/classifier.dart';
import 'package:hiddify/features/smart_split/model/split_choices.dart';
import 'package:hiddify/features/smart_split/model/thing_list.dart';

/// 每次连接（含重连）前写规则（VPN 仓库 docs/计划/智能分流-实施计划-3-安卓.md 任务 6）：
/// - `<workingDir>/gsl-route.json`：内核补丁 0002 读，四份网址后缀插在国内名单前面；
/// - SharedPreferences `gsl_direct_apps` / `gsl_split_downloaders`：VPNService 建通道时读（JSON 数组）。
/// 先拉账号里的网站和服务器默认，最多等 [prepareTimeout]（有缓存 [prepareTimeoutCached]），拉不到用上次存的；任何错误都不影响连接。

const prepareTimeout = Duration(seconds: 3);

/// 上次拉到过服务器默认（有缓存）时只等这么久：面板慢也不多拖连接，拉不到用缓存。
const prepareTimeoutCached = Duration(seconds: 1);
const gslRouteFile = 'gsl-route.json';
const splitChoicesFile = 'split-choices.json';
const splitDefaultsFile = 'split-defaults.json';
const prefDirectApps = 'gsl_direct_apps';
const prefSplitDownloaders = 'gsl_split_downloaders';

/// 账号编号：面板 uuid 去掉横线的前 8 位（注册前后不变，跟 App 里显示的编号同一来源）；不知道回空。
String splitAccountId(String? uuid) {
  final u = (uuid ?? '').replaceAll('-', '').toLowerCase();
  return u.length >= 8 ? u.substring(0, 8) : '';
}

List<String> _sorted(Iterable<String> xs) => xs.toSet().toList()..sort();

/// 四份网址：用户的整组去掉锁住的（跟 dropLocked 同一个判断），组里个别网址级「必须」的只去掉那个网址；服务器的原样放。
Map<String, List<String>> buildGslRoutes(SplitChoices c, RouteDefaults d, ThingList? things) {
  final direct = <String>[];
  final proxy = <String>[];
  for (final x in c.items.where((x) => x.kind == 'site')) {
    if (things != null && choiceLocked(x, things)) continue;
    (x.choice == 'direct' ? direct : proxy).addAll(things == null ? x.domains : x.domains.where((h) => things.mustLock(h).isEmpty));
  }
  return {
    'user_direct': _sorted(direct),
    'user_proxy': _sorted(proxy),
    'server_direct': d.direct,
    'server_proxy': d.proxy,
  };
}

/// directApps = 用户选「整个走本地」的 + 服务器默认走本地的，减去用户改回智能分流的、BT 类（VPNService 已经锁死排除）；
/// splitDownloaders = 用户把普通下载器改成「智能分流」的。
({List<String> directApps, List<String> splitDownloaders}) buildAppLists(SplitChoices c, RouteDefaults d) {
  final mine = c.items.where((x) => x.kind == 'app');
  final split = {for (final x in mine) if (x.choice == 'split') x.pkg};
  final direct = [
    for (final x in mine) if (x.choice == 'direct') x.pkg,
    for (final a in d.appsDirect) if (!split.contains(a)) a,
  ].where((p) => !btPackages.contains(p));
  return (
    directApps: _sorted(direct),
    splitDownloaders: _sorted([for (final x in c.items) if (x.kind == 'downloader' && x.choice == 'split') x.pkg]),
  );
}

SplitChoices loadChoices(Directory baseDir) {
  try {
    final f = File('${baseDir.path}/$splitChoicesFile');
    if (f.existsSync()) return SplitChoices.fromJson(f.readAsStringSync()) ?? SplitChoices();
  } catch (_) {}
  return SplitChoices();
}

void saveChoices(Directory baseDir, SplitChoices c) => _writeAtomic(File('${baseDir.path}/$splitChoicesFile'), c.toJson());

RouteDefaults loadDefaults(Directory baseDir) {
  try {
    final f = File('${baseDir.path}/$splitDefaultsFile');
    if (f.existsSync()) return parseRouteDefaults(f.readAsStringSync()) ?? const RouteDefaults();
  } catch (_) {}
  return const RouteDefaults();
}

/// 先写临时文件再改名：内核读到的不会是写了一半的。
void _writeAtomic(File f, String text) {
  final tmp = File('${f.path}.tmp');
  tmp.writeAsStringSync(text, flush: true);
  tmp.renameSync(f.path);
}

Future<T?> _within<T>(Future<T?> f, Duration timeout) => f.timeout(timeout, onTimeout: () => null).catchError((_) => null);

/// 连接前调。本机没存上的网站留着（下次打开智能分流页补发），删了没删成的不拉回来。
Future<void> prepareSplitRoutes({
  required Directory baseDir,
  required Directory workingDir,
  required RouteApi api,
  required ThingList? things,
  required Future<void> Function(String json) saveThings,
  required Future<void> Function(String key, String json) savePref,
  String account = '',
  Duration? timeout,
}) async {
  try {
    final wait = timeout ?? (File('${baseDir.path}/$splitDefaultsFile').existsSync() ? prepareTimeoutCached : prepareTimeout);
    // 名单也顺便按版本号拉一次（没变服务器只回一句）：服务器新锁的这次连接就生效，不用等他打开智能分流页（审查 5）
    final results = await Future.wait([
      _within(api.list(), wait),
      _within(api.defaults(), wait),
      _within(api.things(things?.version ?? 0), wait),
    ]);
    api.cancel();
    // 等网络时他可能又在智能分流页选了（页面会存盘）：拿到结果以后再读本机的，中间不再等，不会盖掉
    final choices = loadChoices(baseDir);
    final server = results[0] as List<SplitChoice>?;
    var defaults = results[1] as RouteDefaults?;
    final thingsBody = results[2] as String?;
    if (thingsBody != null) {
      final next = things == null ? ThingList.parse(thingsBody) : ThingList.pickNewer(things, thingsBody);
      if (next != null) {
        things = next;
        await saveThings(thingsBody);
      }
    }
    if (defaults != null) {
      _writeAtomic(File('${baseDir.path}/$splitDefaultsFile'), defaults.toJson());
    } else {
      defaults = loadDefaults(baseDir);
    }
    adoptOwner(choices, account);
    if (server != null) {
      final merged = mergeAccountSites(choices, server);
      choices
        ..setItems(merged.items)
        // 服务器上已经没有的算删成了；还在的留着，下次打开智能分流页再删
        ..setPendingDeletes(merged.redelete);
    }
    if (things != null) {
      for (final key in dropLocked(choices, things)) {
        choices.remove(key);
      }
    }
    saveChoices(baseDir, choices);
    _writeAtomic(File('${workingDir.path}/$gslRouteFile'), jsonEncode(buildGslRoutes(choices, defaults, things)));
    final apps = buildAppLists(choices, defaults);
    await savePref(prefDirectApps, jsonEncode(apps.directApps));
    await savePref(prefSplitDownloaders, jsonEncode(apps.splitDownloaders));
  } catch (_) {
    // 写不了就照上次的规则连
  }
}

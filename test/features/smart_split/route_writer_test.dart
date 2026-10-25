import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/smart_split/data/route_api.dart';
import 'package:hiddify/features/smart_split/data/route_writer.dart';
import 'package:hiddify/features/smart_split/model/classifier.dart';
import 'package:hiddify/features/smart_split/model/split_choices.dart';
import 'package:hiddify/features/smart_split/model/thing_list.dart';

/// 每次连接前写规则：gsl-route.json（内核补丁 0002 读）+ 两份 App 名单（VPNService 读）。
/// 跑法：flutter test test/features/smart_split
void main() {
  final things = ThingList.parse(jsonEncode({
    'version': 1,
    'things': [
      {'id': 'google', 'name': '谷歌', 'domains': ['google.com'], 'lock': 'proxy'},
    ],
    'must': {'proxy': ['blocked.com']},
  }))!;
  SplitThing site(String host) => SplitThing(key: 'site:$host')
    ..kind = 'site'
    ..name = host
    ..host = host
    ..domains = [host];
  SplitThing app(String pkg, [String kind = 'app']) => SplitThing(key: 'app:$pkg')
    ..kind = kind
    ..name = pkg
    ..pkg = pkg;

  test('testRoutesDropLocked：用户选的锁住的、必须的不进规则；服务器的原样放', () {
    final c = SplitChoices()
      ..set(site('google.com'), 'direct')
      ..set(site('blocked.com'), 'direct')
      ..set(site('btsj6.com'), 'direct')
      ..set(site('cn-site.com'), 'proxy');
    final r = buildGslRoutes(c, const RouteDefaults(direct: ['icbc.com.cn'], proxy: ['openai.com']), things);
    expect(r['user_direct'], ['btsj6.com']);
    expect(r['user_proxy'], ['cn-site.com']);
    expect(r['server_direct'], ['icbc.com.cn']);
    expect(r['server_proxy'], ['openai.com']);
  });

  test('testAppListsSubtract：服务器默认走本地的 App 用户改回智能分流就不排除', () {
    final c = SplitChoices()
      ..set(app('com.example.mine'), 'direct')
      ..set(app('com.example.def'), 'split')
      ..set(app('com.dv.adm', 'downloader'), 'split');
    final l = buildAppLists(c, const RouteDefaults(appsDirect: ['com.example.def', 'com.example.other', 'steam']));
    expect(l.directApps, ['com.example.mine', 'com.example.other', 'steam']);
    expect(l.splitDownloaders, ['com.dv.adm']);
  });

  test('testBtNeverDirectApps：迅雷不进 directApps（VPNService 已经锁死排除）', () {
    final l = buildAppLists(SplitChoices(), const RouteDefaults(appsDirect: ['com.xunlei.downloadprovider']));
    expect(l.directApps, isEmpty);
  });

  group('prepareSplitRoutes', () {
    late Directory base;
    late Directory work;
    late Map<String, String> prefs;
    setUp(() {
      base = Directory.systemTemp.createTempSync('split-base');
      work = Directory.systemTemp.createTempSync('split-work');
      prefs = {};
    });
    tearDown(() {
      base.deleteSync(recursive: true);
      work.deleteSync(recursive: true);
    });

    Future<void> run(RouteApi api, {Duration timeout = const Duration(seconds: 3)}) => prepareSplitRoutes(
      baseDir: base,
      workingDir: work,
      api: api,
      things: things,
      savePref: (k, v) async => prefs[k] = v,
      timeout: timeout,
    );

    Map<String, dynamic> routes() => jsonDecode(File('${work.path}/gsl-route.json').readAsStringSync()) as Map<String, dynamic>;

    test('拉到账号和默认：合并、存缓存、写规则和名单', () async {
      final api = RouteApi((m, p, {data}) async => switch (p) {
        '/api/v1/user/gsl_route/list' =>
          (200, jsonEncode({'data': {'items': [{'key': 'site:btsj6.com', 'host': 'btsj6.com', 'domains': ['anycip.com', 'btsj6.com'], 'choice': 'direct'}]}})),
        '/api/v1/guest/gsl_route/defaults' =>
          (200, jsonEncode({'data': {'direct': ['icbc.com.cn'], 'proxy': ['openai.com'], 'apps_direct': ['com.example.cn']}})),
        _ => (404, ''),
      });
      await run(api);
      expect(routes()['user_direct'], ['anycip.com', 'btsj6.com']);
      expect(routes()['server_proxy'], ['openai.com']);
      expect(jsonDecode(prefs['gsl_direct_apps']!), ['com.example.cn']);
      expect(jsonDecode(prefs['gsl_split_downloaders']!), isEmpty);
      expect(File('${base.path}/split-defaults.json').existsSync(), isTrue);
      expect(SplitChoices.fromJson(File('${base.path}/split-choices.json').readAsStringSync())!.items.single.synced, isTrue);
    });

    test('删了的：服务器上已经没有就算删成，还在的留着下次再删', () async {
      final c = SplitChoices()
        ..set(site('a.com'), 'direct')
        ..set(site('b.com'), 'direct')
        ..remove('site:a.com')
        ..remove('site:b.com');
      File('${base.path}/split-choices.json').writeAsStringSync(c.toJson());
      await run(RouteApi((m, p, {data}) async => p == '/api/v1/user/gsl_route/list'
          ? (200, jsonEncode({'data': {'items': [{'key': 'site:b.com', 'host': 'b.com', 'domains': ['b.com'], 'choice': 'direct'}]}}))
          : (500, '')));
      final back = SplitChoices.fromJson(File('${base.path}/split-choices.json').readAsStringSync())!;
      expect(back.pendingDeletes, ['site:b.com']);
      expect(back.items, isEmpty);
    });

    test('testPrepareTimeoutUsesCache：接口很慢，到时间用上次存的', () async {
      File('${base.path}/split-defaults.json').writeAsStringSync(const RouteDefaults(direct: ['cached.cn']).toJson());
      final api = RouteApi((m, p, {data}) async {
        await Future<void>.delayed(const Duration(seconds: 5));
        return (200, '{}');
      });
      final sw = Stopwatch()..start();
      await run(api, timeout: const Duration(milliseconds: 300));
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
      expect(routes()['server_direct'], ['cached.cn']);
    });

    test('testPrepareNoCacheNoNetwork：什么都没有写一份四个空列表', () async {
      await run(RouteApi((m, p, {data}) async => throw const SocketException('down')));
      expect(routes(), {'user_direct': [], 'user_proxy': [], 'server_direct': [], 'server_proxy': []});
      expect(jsonDecode(prefs['gsl_direct_apps']!), isEmpty);
    });

    test('本机存档坏了当空，照常写', () async {
      File('${base.path}/split-choices.json').writeAsStringSync('oops');
      await run(RouteApi((m, p, {data}) async => (500, '')));
      expect(routes()['user_direct'], isEmpty);
    });
  });
}

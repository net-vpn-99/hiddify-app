import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/smart_split/data/route_api.dart';
import 'package:hiddify/features/smart_split/model/classifier.dart';
import 'package:hiddify/features/smart_split/model/split_choices.dart';
import 'package:hiddify/features/smart_split/model/thing_list.dart';

/// 「我改过的」、存账号、服务器默认（跟 Windows splitchoices 同名用例一样，App 用包名）。
/// 跑法：flutter test test/features/smart_split
void main() {
  SplitThing site(String host, {List<String>? domains}) => SplitThing(key: 'site:$host')
    ..kind = 'site'
    ..name = host
    ..host = host
    ..domains = domains ?? [host];
  SplitThing app(String pkg, {String kind = 'app'}) => SplitThing(key: 'app:$pkg')
    ..kind = kind
    ..name = pkg
    ..pkg = pkg;

  test('testSetLimits：第 51 组网站不收，一组超过 30 个网址截到 30', () {
    final c = SplitChoices();
    for (var i = 0; i < 50; i++) {
      expect(c.set(site('s$i.com'), 'direct'), SetResult.ok);
    }
    expect(c.set(site('s50.com'), 'direct'), SetResult.full);
    expect(c.set(app('com.example.a'), 'direct'), SetResult.ok); // App 不算在 50 组里
    final many = SplitChoices()..set(site('big.com', domains: [for (var i = 0; i < 40; i++) 'd$i.com']), 'proxy');
    expect(many.items.single.domains.length, 30);
  });

  test('网址超过 30 个时主网址一定留着（审查 4）', () {
    final t = site('zz-main.com', domains: [for (var i = 0; i < 40; i++) 'a$i.com', 'zz-main.com']);
    final c = SplitChoices()..set(t, 'direct');
    expect(c.items.single.domains, contains('zz-main.com'));
    expect(c.items.single.domains.length, 30);
  });

  test('BT 类的 App 选择也算锁住（审查 5）', () {
    final c = SplitChoices()..set(app('com.xunlei.downloadprovider'), 'direct');
    expect(dropLocked(c, ThingList.parse(jsonEncode({'version': 1, 'things': [{'id': 'x', 'name': 'X', 'domains': ['x.com']}]}))!),
        ['app:com.xunlei.downloadprovider']);
  });

  test('testDefaultRemoves：选回 default 就删掉，网站记进 pendingDeletes', () {
    final c = SplitChoices()..set(site('btsj6.com'), 'direct', was: 'proxy');
    expect(c.choiceFor('site:btsj6.com'), 'direct');
    expect(c.items.single.was, 'proxy');
    c.set(site('btsj6.com'), 'default');
    expect(c.items, isEmpty);
    expect(c.pendingDeletes, ['site:btsj6.com']);
    c.set(site('btsj6.com'), 'proxy');
    expect(c.pendingDeletes, isEmpty);
  });

  test('坏网址不收；App 没有包名不收；下载器 direct 等于删掉', () {
    final c = SplitChoices();
    expect(c.set(site('x', domains: ['google.com,']), 'direct'), SetResult.invalid);
    expect(c.set(app(''), 'direct'), SetResult.invalid);
    c.set(app('com.dv.adm', kind: 'downloader'), 'split');
    expect(c.choiceFor('app:com.dv.adm'), 'split');
    c.set(app('com.dv.adm', kind: 'downloader'), 'direct');
    expect(c.items, isEmpty);
  });

  test('存盘读回来一样', () {
    final c = SplitChoices()
      ..set(site('btsj6.com', domains: ['anycip.com', 'btsj6.com']), 'direct', was: 'proxy')
      ..set(app('com.example.game'), 'direct')
      ..markSynced('site:btsj6.com');
    final back = SplitChoices.fromJson(c.toJson())!;
    expect(back.items.map((x) => '${x.key}/${x.choice}/${x.synced}/${x.pkg}'),
        ['site:btsj6.com/direct/true/', 'app:com.example.game/direct/false/com.example.game']);
    expect(SplitChoices.fromJson('oops'), isNull);
  });

  test('testMergeKeepsUnsynced：本机没存上的赢、要补发；存上过的用服务器的，带上本机的 was', () {
    final local = SplitChoices()
      ..set(site('a.com'), 'direct', was: 'proxy')
      ..markSynced('site:a.com')
      ..set(site('b.com'), 'direct')
      ..set(app('com.example.game'), 'direct');
    final server = [
      SplitChoice(key: 'site:a.com', kind: 'site', name: 'a.com', host: 'a.com', domains: ['a.com'], choice: 'proxy', synced: true),
      SplitChoice(key: 'site:b.com', kind: 'site', name: 'b.com', host: 'b.com', domains: ['b.com'], choice: 'proxy', synced: true),
      SplitChoice(key: 'site:c.com', kind: 'site', name: 'c.com', host: 'c.com', domains: ['c.com'], choice: 'direct', synced: true),
    ];
    final r = mergeAccountSites(local, server);
    String of(String k) => r.items.firstWhere((x) => x.key == k).choice;
    expect(of('site:a.com'), 'proxy');
    expect(r.items.firstWhere((x) => x.key == 'site:a.com').was, 'proxy');
    expect(of('site:b.com'), 'direct');
    expect(of('site:c.com'), 'direct');
    expect(of('app:com.example.game'), 'direct');
    expect(r.resend, ['site:b.com']);
  });

  test('testMergePendingDelete：删了还没删成的不拉回来，要再删', () {
    final local = SplitChoices()
      ..set(site('a.com'), 'direct')
      ..remove('site:a.com');
    final server = [SplitChoice(key: 'site:a.com', kind: 'site', name: 'a.com', host: 'a.com', domains: ['a.com'], choice: 'direct', synced: true)];
    final r = mergeAccountSites(local, server);
    expect(r.items, isEmpty);
    expect(r.redelete, ['site:a.com']);
  });

  test('testDropLockedSiteAndApp', () {
    final things = ThingList.parse(jsonEncode({
      'version': 1,
      'things': [
        {'id': 'google', 'name': '谷歌', 'domains': ['google.com'], 'lock': 'proxy'},
        {'id': 'steam', 'name': 'Steam', 'domains': ['steampowered.com'], 'lock': 'split', 'apps': ['com.valvesoftware.android.steam.community']},
      ],
      'must': {'proxy': ['blocked.com']},
    }))!;
    final c = SplitChoices()
      ..set(site('google.com'), 'direct')
      ..set(site('blocked.com'), 'direct')
      ..set(site('ok.com'), 'direct')
      ..set(app('com.valvesoftware.android.steam.community'), 'direct');
    expect(dropLocked(c, things), ['site:google.com', 'site:blocked.com', 'app:com.valvesoftware.android.steam.community']);
  });

  test('testBodyAndroid', () {
    final s = SplitChoice(key: 'site:btsj6.com', kind: 'site', name: 'btsj6.com', host: 'btsj6.com', domains: ['anycip.com', 'btsj6.com'], choice: 'direct', was: 'proxy');
    final b = jsonDecode(routeSetBody(s, '1.1.73', 'dev1')) as Map;
    expect(b['platform'], 'android');
    expect(b['now'], 'proxy');
    expect(b['domains'], ['anycip.com', 'btsj6.com']);
    final a = SplitChoice(key: 'app:com.dv.adm', kind: 'downloader', name: 'ADM', pkg: 'com.dv.adm', choice: 'split');
    final ab = jsonDecode(routeSetBody(a, '1.1.73', 'dev1')) as Map;
    expect(ab['kind'], 'app');
    expect(ab['exe'], 'com.dv.adm');
    expect(ab['key'], 'app:com.dv.adm');
    expect(ab['choice'], 'split');
    expect(ab.containsKey('domains'), isFalse);
  });

  test('testEffectiveAppChoice', () {
    expect(effectiveAppChoice('', serverDefaultDirect: true), 'direct');
    expect(effectiveAppChoice('', serverDefaultDirect: false), 'default');
    expect(effectiveAppChoice('split', serverDefaultDirect: true), 'split');
  });

  test('testParseDefaultsBadDomains', () {
    final d = parseRouteDefaults(jsonEncode({
      'data': {
        'version': 9,
        'direct': ['icbc.com.cn', 'bad,'],
        'proxy': ['openai.com'],
        'apps_direct': ['com.example.cn', 'Bad App!'],
      },
    }))!;
    expect(d.direct, ['icbc.com.cn']);
    expect(d.proxy, ['openai.com']);
    expect(d.appsDirect, ['com.example.cn']);
    expect(parseRouteDefaults('{"data":{}}'), isNull);
  });

  test('testParseListBadJsonIsNull', () {
    expect(parseAccountList('oops'), isNull);
    final l = parseAccountList(jsonEncode({
      'data': {
        'items': [
          {'key': 'site:a.com', 'host': 'a.com', 'domains': ['a.com'], 'choice': 'direct'},
          {'key': 'site:b.com', 'domains': ['b,'], 'choice': 'direct'},
        ],
      },
    }))!;
    expect(l.single.key, 'site:a.com');
    expect(l.single.synced, isTrue);
  });

  test('RouteApi：things 没变回 null；接口出错回 null', () async {
    final calls = <String>[];
    final api = RouteApi((method, path, {data}) async {
      calls.add('$method $path');
      if (path.startsWith('/api/v1/guest/gsl_route/things')) return (200, '{"same":true}');
      if (path == '/api/v1/user/gsl_route/list') return (500, 'x');
      return (200, '{"data":true}');
    });
    expect(await api.things(5), isNull);
    expect(calls.last, 'GET /api/v1/guest/gsl_route/things?have=5');
    expect(await api.list(), isNull);
    expect(await api.del('site:a.com'), isTrue);
  });
}

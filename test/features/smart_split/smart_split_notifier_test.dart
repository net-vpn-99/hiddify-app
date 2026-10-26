import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/smart_split/data/route_api.dart';
import 'package:hiddify/features/smart_split/model/classifier.dart';
import 'package:hiddify/features/smart_split/model/public_suffix.dart';
import 'package:hiddify/features/smart_split/model/split_choices.dart';
import 'package:hiddify/features/smart_split/model/thing_list.dart';
import 'package:hiddify/features/smart_split/notifier/smart_split_controller.dart';

/// 智能分流页的逻辑（采集、选、存账号、重连、清空）。跑法：flutter test test/features/smart_split
void main() {
  final psl = PublicSuffix.parse(File('assets/split/public_suffix_list.dat').readAsStringSync());
  final things = ThingList.parse(jsonEncode({
    'version': 1,
    'things': [
      {'id': 'google', 'name': '谷歌', 'domains': ['google.com'], 'lock': 'proxy'},
    ],
  }))!;

  late Directory base;
  late Directory work;
  late File log;
  late List<String> calls;
  late int reconnects;
  late bool setOk;
  late Completer<void>? holdReconnect;
  late bool reconnectOk;
  late Completer<void>? holdThings;
  late String account;

  setUp(() {
    base = Directory.systemTemp.createTempSync('ss-base');
    work = Directory.systemTemp.createTempSync('ss-work');
    log = File('${work.path}/box.log')..writeAsStringSync('');
    calls = [];
    reconnects = 0;
    setOk = true;
    holdReconnect = null;
    reconnectOk = true;
    holdThings = null;
    account = '';
  });
  tearDown(() {
    base.deleteSync(recursive: true);
    work.deleteSync(recursive: true);
  });

  SmartSplitController make() => SmartSplitController(SmartSplitDeps(
    baseDir: base,
    boxLog: log,
    currentConfigPath: '${work.path}/data/current-config.json',
    psl: psl,
    loadThings: () async => things,
    saveThings: (_) async {},
    api: () => RouteApi((m, p, {data}) async {
      calls.add('$m $p');
      final hold = holdThings;
      if (p.contains('/things') && hold != null) await hold.future;
      if (p.endsWith('/set')) return setOk ? (200, '{"data":true}') : (500, '');
      if (p.endsWith('/list')) return (200, '{"data":{"items":[]}}');
      return (200, '{"data":true}');
    }),
    reconnect: () async {
      reconnects++;
      final hold = holdReconnect;
      if (hold != null) await hold.future;
      return reconnectOk;
    },
    loggedIn: () => true,
    appName: (p) => p,
    appVer: '1.1.73',
    deviceId: 'dev',
    accountId: () => account,
    panelWait: const Duration(milliseconds: 200),
  ));

  void browse(int id, String host) => log.writeAsStringSync(
    'INFO [$id 1ms] router: found package name: com.android.chrome\n'
    'INFO [$id 9ms] outbound/vless[x]: outbound connection to $host:443\n',
    mode: FileMode.append,
  );

  Future<SmartSplitController> collecting() async {
    final c = make();
    await c.open(connected: true);
    await c.startCollect();
    browse(1, 'www.btsj6.com');
    browse(2, 'imgb.anycip.com');
    c.tick();
    return c;
  }

  test('采到 btsj6 一行，能选；谷歌进不能改', () async {
    final c = await collecting();
    browse(3, 'www.google.com');
    c.tick();
    expect(c.state.pickable.single.key, 'site:btsj6.com');
    expect(c.state.pickable.single.now, 'proxy');
    expect(c.state.fixed.single.name, '谷歌');
  });

  test('testDisconnectClears：断开后列表清空、不在采集', () async {
    final c = await collecting();
    expect(c.state.pickable, isNotEmpty);
    c.onConnection(connected: false);
    expect(c.state.collecting, isFalse);
    expect(c.state.pickable, isEmpty);
  });

  test('testLeaveClears：离开这页再进来是空的', () async {
    final c = await collecting();
    c.leave();
    expect(c.state.collecting, isFalse);
    expect(c.state.pickable, isEmpty);
  });

  test('testChooseNotes：选了先「会断开一下」，连回来变「改好了」，存账号、记下改之前走哪边', () async {
    final c = await collecting();
    holdReconnect = Completer<void>();
    final f = c.choose('site:btsj6.com', 'direct');
    await Future<void>.delayed(Duration.zero);
    expect(c.state.rowNote['site:btsj6.com'], 'reconnecting');
    // 重连中断开那一下不清空
    c.onConnection(connected: false);
    expect(c.state.collecting, isTrue);
    holdReconnect!.complete();
    await f;
    c.onConnection(connected: true);
    expect(c.state.rowNote['site:btsj6.com'], 'done');
    expect(reconnects, 1);
    expect(calls, contains('POST /api/v1/user/gsl_route/set'));
    expect(c.state.mine.single.choice, 'direct');
    expect(c.state.mine.single.was, 'proxy');
    expect(c.state.pickable.single.now, 'direct');
  });

  test('重连不会清空 box.log：重连以后不把采集开始前的记录读进来（审查 1）', () async {
    browse(90, 'www.before-collect.com');
    final c = make();
    await c.open(connected: true);
    await c.startCollect();
    browse(1, 'www.btsj6.com');
    c.tick();
    await c.choose('site:btsj6.com', 'direct');
    browse(2, 'imgb.anycip.com');
    c.tick();
    expect(c.state.pickable.map((r) => r.key), ['site:btsj6.com']);
    expect(c.state.pickable.single.thing.domains, isNot(contains('before-collect.com')));
  });

  test('重连中又选了一个：不丢、排队再重连一次、采集不被清空（审查 2）', () async {
    final c = await collecting();
    log.writeAsStringSync(
      'INFO [4 1ms] router: found package name: com.example.game\n'
      'INFO [4 9ms] outbound/vless[x]: outbound connection to api.game.com:443\n',
      mode: FileMode.append,
    );
    c.tick();
    // 跟真的一样：连之前那一步先读 split-choices.json，等网络，再把读到的写回去（会盖掉中途存的）
    final file = File('${base.path}/split-choices.json');
    final firstHold = Completer<void>();
    var n = 0;
    final c2 = SmartSplitController(SmartSplitDeps(
      baseDir: base,
      boxLog: log,
      currentConfigPath: '${work.path}/data/current-config.json',
      psl: psl,
      loadThings: () async => things,
      saveThings: (_) async {},
      api: () => RouteApi((m, p, {data}) async => (200, p.endsWith('/list') ? '{"data":{"items":[]}}' : '{"data":true}')),
      reconnect: () async {
        n++;
        final snapshot = file.existsSync() ? file.readAsStringSync() : null;
        if (n == 1) await firstHold.future;
        if (snapshot != null) file.writeAsStringSync(snapshot);
        return true;
      },
      loggedIn: () => true,
      appName: (p) => p,
      appVer: '1.1.73',
      deviceId: 'dev',
    ));
    c.leave();
    await c2.open(connected: true);
    await c2.startCollect();
    browse(11, 'www.btsj6.com');
    log.writeAsStringSync(
      'INFO [12 1ms] router: found package name: com.example.game\n'
      'INFO [12 9ms] outbound/vless[x]: outbound connection to api.game.com:443\n',
      mode: FileMode.append,
    );
    c2.tick();
    final a = c2.choose('site:btsj6.com', 'direct');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    c2.onConnection(connected: false);
    final b = c2.choose('app:com.example.game', 'direct');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(c2.state.collecting, isTrue);
    firstHold.complete();
    await Future.wait([a, b]);
    c2.onConnection(connected: true);
    expect(n, 2);
    expect(c2.state.mine.map((m) => m.key).toSet(), {'site:btsj6.com', 'app:com.example.game'});
    expect(SplitChoices.fromJson(file.readAsStringSync())!.items.length, 2);
    expect(c2.state.rowNote['site:btsj6.com'], 'done');
    expect(c2.state.rowNote['app:com.example.game'], 'done');
    expect(c2.state.collecting, isTrue);
  });

  test('重连失败：行里「没改成」，没连上就清空采集（审查 3）', () async {
    final c = await collecting();
    reconnectOk = false;
    holdReconnect = Completer<void>();
    final f = c.choose('site:btsj6.com', 'direct');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    c.onConnection(connected: false);
    holdReconnect!.complete();
    await f;
    expect(c.state.rowNote['site:btsj6.com'], 'failed');
    expect(c.state.collecting, isFalse);
  });

  test('选回原来那边 = 改回默认，账号里删掉', () async {
    final c = await collecting();
    await c.choose('site:btsj6.com', 'direct');
    await c.choose('site:btsj6.com', 'proxy');
    expect(c.state.mine, isEmpty);
    expect(calls, contains('POST /api/v1/user/gsl_route/del'));
  });

  test('testSaveFailRetry：存账号失败「没存上」，本机照样生效', () async {
    setOk = false;
    final c = await collecting();
    await c.choose('site:btsj6.com', 'direct');
    expect(c.state.mineNote['site:btsj6.com'], 'retry');
    expect(c.state.mine.single.choice, 'direct');
    expect(reconnects, 1);
    setOk = true;
    await c.retrySync('site:btsj6.com');
    expect(c.state.mineNote['site:btsj6.com'], isNull);
  });

  test('testFull：第 51 组不生效、不重连', () async {
    final c = make();
    await c.open(connected: true);
    for (var i = 0; i < 50; i++) {
      c.debugAddSite('s$i.com', 'direct');
    }
    await c.startCollect();
    browse(1, 'www.btsj6.com');
    c.tick();
    await c.choose('site:btsj6.com', 'direct');
    expect(c.state.rowNote['site:btsj6.com'], 'full');
    expect(reconnects, 0);
  });

  test('testResetAll：全部改回默认，账号里一起删，重连一次', () async {
    final c = await collecting();
    await c.choose('site:btsj6.com', 'direct');
    await c.resetAll();
    expect(c.state.mine, isEmpty);
    expect(calls, contains('POST /api/v1/user/gsl_route/reset'));
    expect(reconnects, 2);
  });

  test('开始采集：面板慢最多等一会儿，连点两下只开一次', () async {
    final c = make();
    await c.open(connected: true);
    calls.clear();
    holdThings = Completer<void>();
    final sw = Stopwatch()..start();
    final a = c.startCollect();
    final b = c.startCollect();
    await Future.wait([a, b]);
    expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
    expect(c.state.collecting, isTrue);
    expect(calls.where((x) => x.contains('/things')).length, 1);
    holdThings!.complete();
  });

  test('开始采集还在等名单时离开这页：不再开始采集', () async {
    final c = make();
    await c.open(connected: true);
    holdThings = Completer<void>();
    final f = c.startCollect();
    c.leave();
    await f;
    expect(c.state.collecting, isFalse);
    holdThings!.complete();
  });

  test('还不知道是哪个号：不补发上个号没存上的网站', () async {
    account = 'aaaa1111';
    final c = await collecting();
    setOk = false;
    await c.choose('site:btsj6.com', 'direct');
    c.leave();
    account = '';
    calls.clear();
    await make().open(connected: true);
    expect(calls.where((x) => x.contains('/set')), isEmpty);
  });

  test('页面开着换了账号：上个号的网站不留着、也不补发', () async {
    account = 'aaaa1111';
    final c = await collecting();
    await c.choose('site:btsj6.com', 'direct');
    account = 'bbbb2222';
    calls.clear();
    await c.onAccount(account);
    expect(calls.where((x) => x.contains('/set')), isEmpty);
    expect(c.state.mine.where((m) => m.key.startsWith('site:')), isEmpty);
    final saved = SplitChoices.fromJson(File('${base.path}/split-choices.json').readAsStringSync())!;
    expect(saved.owner, 'bbbb2222');
    expect(saved.items.where((x) => x.kind == 'site'), isEmpty);
  });

  test('换账号：上个号的网站（含没存上的）不补发给新号，App 选择留着', () async {
    account = 'aaaa1111';
    final c = await collecting();
    setOk = false;
    await c.choose('site:btsj6.com', 'direct');
    c.leave();
    final saved = SplitChoices.fromJson(File('${base.path}/split-choices.json').readAsStringSync())!;
    expect(saved.owner, 'aaaa1111');
    saved.set(SplitThing(key: 'app:com.example.game')
      ..kind = 'app'
      ..name = 'game'
      ..pkg = 'com.example.game', 'direct');
    File('${base.path}/split-choices.json').writeAsStringSync(saved.toJson());
    account = 'bbbb2222';
    setOk = true;
    calls.clear();
    final c2 = make();
    await c2.open(connected: true);
    expect(calls, isNot(contains('POST /api/v1/user/gsl_route/set')));
    expect(calls, isNot(contains('POST /api/v1/user/gsl_route/del')));
    expect(c2.state.mine.map((m) => m.key), ['app:com.example.game']);
  });

  test('没连上不能开始采集', () async {
    final c = make();
    await c.open(connected: false);
    await c.startCollect();
    expect(c.state.collecting, isFalse);
  });

  test('关联网址取消勾选：存进去的不带它', () async {
    final c = await collecting();
    c.setDomainIncluded('site:btsj6.com', 'anycip.com', included: false);
    await c.choose('site:btsj6.com', 'direct');
    expect(c.state.mine.single.domains, ['btsj6.com']);
  });
}

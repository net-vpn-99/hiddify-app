// 智能分流页截图：真代码，假数据（改这页先跑这个看图，对照 VPN 仓库 docs/计划/智能分流-样稿/）。
// 不给 SHOT_DIR 就跳过（字体用的是本机 Windows 自带的等线 Deng.ttf）。
// flutter test test/features/smart_split/smart_split_preview_test.dart --dart-define=SHOT_DIR=...
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/theme/app_theme.dart';
import 'package:hiddify/core/theme/app_theme_mode.dart';
import 'package:hiddify/features/connection/notifier/route_check_notifier.dart';
import 'package:hiddify/features/smart_split/model/classifier.dart';
import 'package:hiddify/features/smart_split/model/split_choices.dart';
import 'package:hiddify/features/smart_split/notifier/smart_split_controller.dart';
import 'package:hiddify/features/smart_split/notifier/smart_split_notifier.dart';
import 'package:hiddify/features/smart_split/widget/smart_split_page.dart';

const shotDir = String.fromEnvironment('SHOT_DIR');

class _NoActions implements SplitActions {
  @override
  final Map<String, Uint8List?> icons = {};
  @override
  Future<void> startCollect() async {}
  @override
  void stopCollect() {}
  @override
  Future<void> choose(String key, String picked) async {}
  @override
  Future<void> resetOne(String key) async {}
  @override
  Future<void> resetAll() async {}
  @override
  Future<void> retrySync(String key) async {}
  @override
  void setDomainIncluded(String key, String domain, {required bool included}) {}
}

SplitRow _site(String host, List<String> domains, String now) => SplitRow(
  SplitThing(key: 'site:$host')
    ..kind = 'site'
    ..name = host
    ..host = host
    ..domains = domains
    ..now = now,
  now: now,
  choice: '',
  excluded: const {},
);

SplitRow _app(String name, String pkg, String choice, {String kind = 'app'}) => SplitRow(
  SplitThing(key: 'app:$pkg')
    ..kind = kind
    ..name = name
    ..pkg = pkg
    ..now = 'split',
  now: choice,
  choice: choice,
  excluded: const {},
);

SplitRow _locked(String name, String why) => SplitRow(
  SplitThing(key: 'id:$name')
    ..kind = 'locked'
    ..name = name
    ..lockWhy = why,
  now: '',
  choice: '',
  excluded: const {},
);

final _mine = [
  SplitChoice(key: 'site:hostkvm.com', kind: 'site', name: 'hostkvm.com', host: 'hostkvm.com', domains: const ['hostkvm.com'], choice: 'direct', synced: true),
  SplitChoice(key: 'app:com.example.game', kind: 'app', name: '某某游戏', pkg: 'com.example.game', choice: 'direct'),
];

const _check = RouteCheckState(status: 'done', domesticLine: '本地网络 · 湖南电信 · 1.2.3.4', foreignLine: '光速雷达 · 美国 洛杉矶 07 · 144.34.129.239');

Future<void> _shot(WidgetTester tester, String file, {required bool connected, required SmartSplitState state, bool dark = false}) async {
  final key = GlobalKey();
  tester.view.physicalSize = const Size(390 * 3, 1400 * 3);
  tester.view.devicePixelRatio = 3;
  final theme = AppTheme(dark ? AppThemeMode.dark : AppThemeMode.light, 'Deng');
  final base = dark ? theme.darkTheme(null) : theme.lightTheme(null);
  // 按钮主题的字没写字体，手机上有系统中文字体兜底，测试里没有：只在截图里补上
  final td = base.copyWith(
    filledButtonTheme: FilledButtonThemeData(
      style: base.filledButtonTheme.style!.copyWith(
        textStyle: const WidgetStatePropertyAll(TextStyle(fontFamily: 'Deng', fontSize: 15, fontWeight: FontWeight.w600)),
      ),
    ),
  );
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: td,
        home: SmartSplitView(
          connected: connected,
          state: state,
          check: _check,
          lineName: '美国 洛杉矶 07',
          actions: _NoActions(),
          onRecheck: () {},
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
  // 点开「不能改」那一行，看展开后的样子
  if (state.fixed.isNotEmpty) {
    await tester.tap(find.textContaining('不能改：'));
    await tester.pump(const Duration(milliseconds: 300));
  }
  await tester.runAsync(() async {
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File('$shotDir/$file').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
  await tester.pumpWidget(const SizedBox());
}

void main() {
  testWidgets('智能分流页截图（10-26）', (tester) async {
    await tester.runAsync(() async {
      final cjk = FontLoader('Deng')..addFont(Future.value(ByteData.sublistView(File(r'C:\Windows\Fonts\Deng.ttf').readAsBytesSync())));
      await cjk.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(Future.value(ByteData.sublistView(File('C:/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf').readAsBytesSync())));
      await icons.load();
    });
    await _shot(tester, 'S1-平时.png', connected: true, state: SmartSplitState(connected: true, mine: _mine, loggedIn: true));
    final found = SmartSplitState(
      connected: true,
      collecting: true,
      pickable: [
        _site('btsj6.com', ['anycip.com', 'btsj6.com'], 'proxy'),
        _app('某某游戏', 'com.example.game', ''),
        _app('ADM', 'com.dv.adm', '', kind: 'downloader'),
      ],
      fixed: [_locked('谷歌', '只能走光速雷达'), _locked('微信', '只能走本地'), _locked('迅雷', '下载软件，只能走本地')],
      mine: _mine,
      loggedIn: true,
    );
    await _shot(tester, 'S2-采到了.png', connected: true, state: found);
    await _shot(
      tester,
      'S3-改好了.png',
      connected: true,
      state: SmartSplitState(
        connected: true,
        collecting: true,
        pickable: [_site('btsj6.com', ['anycip.com', 'btsj6.com'], 'direct'), _app('某某游戏', 'com.example.game', 'direct')],
        rowNote: const {'site:btsj6.com': 'done', 'app:com.example.game': 'reconnecting'},
        mine: _mine,
        loggedIn: true,
      ),
    );
    await _shot(tester, 'S4-没连上.png', connected: false, state: SmartSplitState(mine: _mine, loggedIn: true));
    await _shot(tester, 'S5-采到了-深色.png', connected: true, state: found, dark: true);
  }, skip: shotDir.isEmpty);
}

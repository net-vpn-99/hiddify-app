// 主页截图：真代码（雷达 + 下半部分 HomeConnectPanel）+ 假数据，没连接 / 已连接 / 连接失败各截一张。
// 改主页配色、排版先跑这个看图。不给 SHOT_DIR 就跳过（字体用本机 Windows 自带的等线 Deng.ttf）。
// flutter test test/features/home/home_preview_test.dart --dart-define=SHOT_DIR=...
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/core/theme/app_theme.dart';
import 'package:hiddify/core/theme/app_theme_mode.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/home/widget/connection_button.dart';
import 'package:hiddify/features/home/widget/home_radar.dart';
import 'package:hiddify/features/panel_auth/data/panel_api.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hiddify/features/proxy/line/line_source.dart';
import 'package:hiddify/features/proxy/model/node_display.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const shotDir = String.fromEnvironment('SHOT_DIR');

class _Auth extends PanelAuthNotifier {
  @override
  PanelAuthState build() => const PanelAuthState(account: PanelAccount(planName: '标准版'));
}

class _Conn extends ConnectionNotifier {
  @override
  Stream<ConnectionStatus> build() async* {
    yield const ConnectionStatus.disconnected();
  }
}

const lines = [
  '日本 东京 03 ⭐精品 | 电信 联通 移动 | 晚高峰稳',
  '香港 01 | 电信 联通',
  '日本 大阪 01 | 电信 联通 移动',
  '韩国 首尔 03 | 联通',
  '新加坡 02 | 移动',
  '美国 洛杉矶 05 ⭐精品 | 电信 | 晚高峰稳',
  '美国 洛杉矶 01 | 电信 联通 | 大带宽',
];

Future<void> _fonts() async {
  final cjk = FontLoader('Deng')
    ..addFont(Future.value(ByteData.sublistView(File(r'C:\Windows\Fonts\Deng.ttf').readAsBytesSync())));
  await cjk.load();
}

Future<void> _shot(
  WidgetTester tester,
  String file, {
  required RadarState state,
  required HomeConnectPanel Function(Widget Function(double) radar) panel,
  bool dark = false,
}) async {
  SharedPreferences.setMockInitialValues({'flutter.last_node_name': '日本 东京 03'});
  final prefs = await SharedPreferences.getInstance();
  final key = GlobalKey();
  tester.view.physicalSize = const Size(390 * 3, 760 * 3);
  tester.view.devicePixelRatio = 3;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWith((ref) => prefs),
        panelAuthProvider.overrideWith(_Auth.new),
        connectionNotifierProvider.overrideWith(_Conn.new),
        lineSetProvider.overrideWith((ref) => LineSet(lines: [for (final n in lines) splitNodeName(n)], locked: false)),
      ],
      child: RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: dark
              ? AppTheme(AppThemeMode.dark, 'Deng').darkTheme(null)
              : AppTheme(AppThemeMode.light, 'Deng').lightTheme(null),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.only(bottom: 24),
              child: panel(
                (size) => HomeRadar(size: size, state: state, isp: '电信', step: 0, dimmed: false, onPick: (_) {}),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.runAsync(() async {
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File('$shotDir/$file').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets('主页截图（10-18 配色）', (tester) async {
    await tester.runAsync(_fonts);
    await _shot(
      tester,
      'H1-没连接.png',
      state: RadarState.off,
      panel: (radar) => HomeConnectPanel(
        radar: radar,
        onTap: () {},
        enabled: true,
        kicker: '未连接 · 上次用的线路',
        title: '东京 03',
        sub: '日本 · 精品线路 · 晚高峰稳',
        buttonLabel: '开始连接',
        linkLabel: '换一条线路',
      ),
    );
    await _shot(
      tester,
      'H2-已连接.png',
      state: RadarState.connected,
      panel: (radar) => HomeConnectPanel(
        radar: radar,
        onTap: () {},
        enabled: true,
        connectedDot: true,
        kicker: '',
        title: '东京 03',
        sub: '↓ 2.4 MB/s · 晚高峰稳',
        buttonLabel: '断开连接',
        buttonOutlined: true,
        showAllLines: true,
        onAllLines: () {},
      ),
    );
    await _shot(
      tester,
      'H4-已连接-深色.png',
      dark: true,
      state: RadarState.connected,
      panel: (radar) => HomeConnectPanel(
        radar: radar,
        onTap: () {},
        enabled: true,
        connectedDot: true,
        kicker: '',
        title: '东京 03',
        sub: '↓ 2.4 MB/s · 晚高峰稳',
        buttonLabel: '断开连接',
        buttonOutlined: true,
        showAllLines: true,
        onAllLines: () {},
      ),
    );
    await _shot(
      tester,
      'H3-连接失败.png',
      state: RadarState.failed,
      panel: (radar) => HomeConnectPanel(
        radar: radar,
        onTap: () {},
        enabled: true,
        faultTag: '连接失败',
        kicker: '',
        title: '东京 03 现在连不上',
        sub: '可能是这条线路临时波动。换一条线路试试，或者稍后点「重新连接」。',
        buttonLabel: '换一条线路',
        secondLabel: '重新连接',
        onAllLines: () {},
      ),
    );
  }, skip: shotDir.isEmpty);
}

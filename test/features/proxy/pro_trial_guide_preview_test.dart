// 领完精品线路体验弹的引导卡截图：真代码 + 假数据（改这张卡先跑这个看图）。
// 不给 SHOT_DIR 就跳过（字体用的是本机 Windows 自带的等线 Deng.ttf）。
// flutter test test/features/proxy/pro_trial_guide_preview_test.dart --dart-define=SHOT_DIR=...
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/theme/app_theme.dart';
import 'package:hiddify/core/theme/app_theme_mode.dart';
import 'package:hiddify/features/proxy/line/line_picker.dart';
import 'package:hiddify/features/proxy/line/line_tier.dart';

const shotDir = String.fromEnvironment('SHOT_DIR');

const pro = [
  ProLine(name: '美国 洛杉矶 05 ⭐精品 | 联通 移动 | 晚高峰稳', country: '美国'),
  ProLine(name: '新加坡 02 ⭐精品 | 电信 联通 移动 | 晚高峰稳', country: '新加坡'),
  ProLine(name: '日本 东京 03 ⭐精品 | 电信 联通 移动 | 晚高峰稳', country: '日本'),
];

Future<void> _shot(WidgetTester tester, String file, {required String isp, bool dark = false}) async {
  final key = GlobalKey();
  tester.view.physicalSize = const Size(390 * 3, 844 * 3);
  tester.view.devicePixelRatio = 3;
  final theme = AppTheme(dark ? AppThemeMode.dark : AppThemeMode.light, 'Deng');
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: dark ? theme.darkTheme(null) : theme.lightTheme(null),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showProTrialGuide(context, const LineTierState(trial: 'active', minutes: 60, proLines: pro), isp),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.tap(find.text('open'));
  for (var i = 0; i < 6; i++) {
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
  testWidgets('精品线路体验引导卡截图（10-19）', (tester) async {
    await tester.runAsync(() async {
      final cjk = FontLoader('Deng')..addFont(Future.value(ByteData.sublistView(File(r'C:\Windows\Fonts\Deng.ttf').readAsBytesSync())));
      await cjk.load();
    });
    await _shot(tester, 'P1-电信.png', isp: '电信');
    await _shot(tester, 'P2-不知道宽带.png', isp: '');
    await _shot(tester, 'P3-深色.png', isp: '电信', dark: true);
  }, skip: shotDir.isEmpty);
}

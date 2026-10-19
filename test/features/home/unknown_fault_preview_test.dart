// 「原因不明」引导卡截图：真代码（改这张卡先跑这个看图，10-19 运营定稿文案）。
// 不给 SHOT_DIR 就跳过（字体用的是本机 Windows 自带的等线 Deng.ttf）。
// flutter test test/features/home/unknown_fault_preview_test.dart --dart-define=SHOT_DIR=...
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/theme/app_theme.dart';
import 'package:hiddify/core/theme/app_theme_mode.dart';
import 'package:hiddify/features/common/guide_card.dart';

const shotDir = String.fromEnvironment('SHOT_DIR');

Future<void> _shot(WidgetTester tester, String file, {bool dark = false}) async {
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
              child: TextButton(onPressed: () => showUnknownFaultGuide(context), child: const Text('open')),
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
  testWidgets('原因不明引导卡截图（10-19）', (tester) async {
    await tester.runAsync(() async {
      final cjk = FontLoader('Deng')..addFont(Future.value(ByteData.sublistView(File(r'C:\Windows\Fonts\Deng.ttf').readAsBytesSync())));
      await cjk.load();
    });
    await _shot(tester, 'U1-浅色.png');
    await _shot(tester, 'U2-深色.png', dark: true);
  }, skip: shotDir.isEmpty);
}

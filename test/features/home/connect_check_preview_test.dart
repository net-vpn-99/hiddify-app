// 连接检查结果卡截图：真代码（改这张卡先跑这个看图，docs/计划/连接检查.md）。查着 / 你的网络连不上 / 未知情况各一张。
// 不给 SHOT_DIR 就跳过（字体用的是本机 Windows 自带的等线 Deng.ttf）。
// flutter test test/features/home/connect_check_preview_test.dart --dart-define=SHOT_DIR=...
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/theme/app_theme.dart';
import 'package:hiddify/core/theme/app_theme_mode.dart';
import 'package:hiddify/features/connection/data/connect_check.dart';
import 'package:hiddify/features/connection/widget/connect_check_card.dart';

const shotDir = String.fromEnvironment('SHOT_DIR');

Future<void> _shot(WidgetTester tester, String file, ConnectCheckState state, {bool dark = false}) async {
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
              child: TextButton(onPressed: () => showDialog<void>(context: context, builder: (_) => connectCheckCard(state, (_) {})), child: const Text('open')),
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

const _running = ConnectCheckState(
  running: true,
  title: '正在帮你检查…',
  secondaryText: '停止检查',
  rows: [
    CheckRow('这台手机能上网', 'ok'),
    CheckRow('光速雷达的服务器能连上', 'ok'),
    CheckRow('美国 洛杉矶 05 有没有回应', 'run'),
    CheckRow('没有别的 VPN 占着', 'ok'),
  ],
);
const _r5 = ConnectCheckState(
  result: 'R5',
  title: '你的网络连不上 美国 洛杉矶 05',
  body: '换到 美国 洛杉矶 06 就能用。',
  primaryText: '换到 美国 洛杉矶 06',
  secondaryText: '重新连接 美国 洛杉矶 05',
  rows: [
    CheckRow('这台手机能上网', 'ok'),
    CheckRow('光速雷达的服务器能连上', 'ok'),
    CheckRow('美国 洛杉矶 05 没有回应', 'fail'),
    CheckRow('美国 洛杉矶 05 其他人用着正常', 'ok'),
    CheckRow('没有别的 VPN 占着', 'ok'),
    CheckRow('换一条试试：美国 洛杉矶 06 有回应', 'ok'),
  ],
);
const _r10 = ConnectCheckState(
  result: 'R10',
  title: '连接没有完成',
  body: '这次的情况我们还没见过。点「联系客服」，我们帮你查。',
  primaryText: '联系客服',
  secondaryText: '重新检查',
  rows: [
    CheckRow('这台手机能上网', 'ok'),
    CheckRow('光速雷达的服务器能连上', 'ok'),
    CheckRow('日本 东京 03 有回应', 'ok'),
    CheckRow('没有别的 VPN 占着', 'ok'),
  ],
);

void main() {
  testWidgets('连接检查结果卡截图（10-22）', (tester) async {
    await tester.runAsync(() async {
      final cjk = FontLoader('Deng')..addFont(Future.value(ByteData.sublistView(File(r'C:\Windows\Fonts\Deng.ttf').readAsBytesSync())));
      await cjk.load();
    });
    await _shot(tester, 'C1-查着.png', _running);
    await _shot(tester, 'C2-网络连不上.png', _r5);
    await _shot(tester, 'C3-未知情况.png', _r10);
    await _shot(tester, 'C4-网络连不上-深色.png', _r5, dark: true);
  }, skip: shotDir.isEmpty);
}

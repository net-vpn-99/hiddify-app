// 线路页截图：真代码 + 假数据，各种情况各截一张，跟样稿对照（改线路页先跑这个看图）。
// 不给 SHOT_DIR 就跳过（字体用的是本机 Windows 自带的等线 Deng.ttf）。
// flutter test test/features/proxy/line_picker_preview_test.dart --dart-define=SHOT_DIR=...
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
import 'package:hiddify/features/panel_auth/data/panel_api.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hiddify/features/proxy/line/line_picker.dart';
import 'package:hiddify/features/proxy/line/line_source.dart';
import 'package:hiddify/features/proxy/line/line_speed.dart';
import 'package:hiddify/features/proxy/line/line_tier.dart';
import 'package:hiddify/features/proxy/line/region_vote.dart';
import 'package:hiddify/features/proxy/model/node_display.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const shotDir = String.fromEnvironment('SHOT_DIR');

class _Auth extends PanelAuthNotifier {
  _Auth(this.isp);
  final String isp;
  @override
  PanelAuthState build() => PanelAuthState(account: PanelAccount(planName: '标准版', isp: isp));
}

class _Tier extends LineTierNotifier {
  _Tier(this.s);
  final LineTierState s;
  @override
  LineTierState build() => s;
}

class _Speed extends LineSpeedNotifier {
  @override
  LineSpeedState build() => const LineSpeedState();
}

class _Region extends RegionVoteNotifier {
  @override
  Future<void> load() async {}
}

class _Conn extends ConnectionNotifier {
  @override
  Stream<ConnectionStatus> build() async* {
    yield const ConnectionStatus.disconnected();
  }
}

const newStd = [
  '香港 01 | 电信 联通 | 低延迟',
  '香港 03 | 电信 联通 移动 | 低延迟',
  '日本 大阪 01 | 电信 联通 移动 | 能用 AI',
  '美国 洛杉矶 01 | 电信 联通 | 大带宽',
  '新加坡 01 | 移动 | 能用 AI',
  '韩国 首尔 01 | 暂不推荐 | 能用 AI',
];
const newPro = [
  '日本 东京 03 ⭐精品 | 电信 联通 移动 | 晚高峰稳',
  '美国 洛杉矶 05 ⭐精品 | 电信 | 晚高峰稳',
];
const oldStd = [
  '香港 01 | 低延迟 · 不能用 ChatGPT | 适合 网页',
  '香港 02 | 低延迟 | 适合 网页',
  '日本 大阪 01 | 能用 AI',
  '美国 洛杉矶 01',
];
const oldPro = ['日本 东京 03 | 晚高峰稳 | 精品'];

Future<void> _fonts() async {
  final cjk = FontLoader('Deng')..addFont(Future.value(ByteData.sublistView(File(r'C:\Windows\Fonts\Deng.ttf').readAsBytesSync())));
  await cjk.load();
  final root = Platform.environment['FLUTTER_ROOT'] ?? r'D:\flutter';
  final icons = File('$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  if (icons.existsSync()) {
    final l = FontLoader('MaterialIcons')..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
    await l.load();
  }
}

Future<void> _shot(
  WidgetTester tester,
  String file, {
  required String isp,
  required List<String> std,
  required List<String> pro,
  required String trial,
  required String current,
  List<String> tapAfter = const [],
}) async {
  SharedPreferences.setMockInitialValues({'flutter.last_node_name': current, 'flutter.preferred_line_name': current});
  final prefs = await SharedPreferences.getInstance();
  final names = [...std, if (trial == 'pro') ...pro];
  final key = GlobalKey();
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWith((ref) => prefs),
        panelAuthProvider.overrideWith(() => _Auth(isp)),
        lineTierProvider.overrideWith(
          () => _Tier(LineTierState(trial: trial, proLines: [for (final p in pro) ProLine(name: p, country: '')])),
        ),
        lineSpeedProvider.overrideWith(_Speed.new),
        regionVoteProvider.overrideWith(_Region.new),
        connectionNotifierProvider.overrideWith(_Conn.new),
        lineSetProvider.overrideWith(
          (ref) => LineSet(lines: [for (final n in names) splitNodeName(n)], locked: false),
        ),
      ],
      child: RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme(AppThemeMode.light, 'Deng').lightTheme(null),
          home: Consumer(
            builder: (context, ref, _) => Scaffold(
              body: Center(
                child: TextButton(onPressed: () => showLinePicker(context, ref), child: const Text('open')),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.tap(find.text('open'));
  Future<void> settle() async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  await settle();
  final ctx = tester.element(find.text('选择线路'));
  await tester.runAsync(() async {
    for (final a in ['assets/images/isp/ct.png', 'assets/images/isp/cu.png']) {
      await precacheImage(AssetImage(a), ctx);
    }
  });
  await settle();
  for (final t in tapAfter) {
    await tester.tap(find.text(t).first);
    await settle();
  }
  await tester.pump(const Duration(seconds: 1));
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
  testWidgets('线路页四种情况截图', (tester) async {
    await tester.runAsync(_fonts);
    // 1. 移动、标准版：香港 03 排到香港 01 前面，移动 LOGO 有橙圈，顶上提示。
    await _shot(tester, '1-移动-标准版.png', isp: '移动', std: newStd, pro: newPro, trial: '', current: '香港 01');
    await _shot(tester, '1b-移动-韩国.png', isp: '移动', std: newStd, pro: newPro, trial: '', current: '韩国 首尔 01');
    // 2. 电信、精品版：精品标签 + 电信橙圈。
    await _shot(tester, '2-电信-精品版.png', isp: '电信', std: newStd, pro: newPro, trial: 'pro', current: '日本 东京 03');
    await _shot(tester, '2b-电信-美国.png', isp: '电信', std: newStd, pro: newPro, trial: 'pro', current: '美国 洛杉矶 05');
    // 3. gsl_isp 为空：有 LOGO、没橙圈、没提示，顺序不动。
    await _shot(tester, '3-宽带未知.png', isp: '', std: newStd, pro: newPro, trial: '', current: '香港 01');
    // 4. 老名字：照旧显示说明，不放 LOGO。
    await _shot(tester, '4-老名字.png', isp: '移动', std: oldStd, pro: oldPro, trial: '', current: '香港 01');
    // 5. 没有精品线路时的平铺列表。
    await _shot(tester, '5-平铺列表-移动.png', isp: '移动', std: newStd, pro: const [], trial: '', current: '');
  }, skip: shotDir.isEmpty);
}

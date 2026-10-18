// 「我的」页截图：真代码（SettingsPage）+ 假账号，浅色 / 深色各一张。改「我的」页先跑这个看图。
// 不给 SHOT_DIR 就跳过（字体用本机 Windows 自带的等线 Deng.ttf）。
// flutter test test/features/settings/me_preview_test.dart --dart-define=SHOT_DIR=...
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/core/theme/app_theme.dart';
import 'package:hiddify/core/theme/app_theme_mode.dart';
import 'package:hiddify/features/panel_auth/data/panel_api.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hiddify/features/settings/overview/help_center_page.dart';
import 'package:hiddify/features/settings/overview/settings_page.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const shotDir = String.fromEnvironment('SHOT_DIR');
const _gb = 1024 * 1024 * 1024;

class _Auth extends PanelAuthNotifier {
  @override
  PanelAuthState build() => PanelAuthState(
    email: '20129048@qq.com',
    account: PanelAccount(
      email: '20129048@qq.com',
      uuid: '3f2a9c1e-0000-4000-8000-000000000000',
      planName: '精品版 · 月付',
      expiredAt: DateTime.now().add(const Duration(days: 30, hours: 1)).millisecondsSinceEpoch ~/ 1000,
      transferEnable: 1000 * _gb,
      deviceLimit: 3,
      dailyKnown: true,
      dailyQuota: 30 * _gb,
      proKnown: true,
      proQuota: 10 * _gb,
      proUsed: (1.5 * _gb).round(),
    ),
  );
}

Future<void> _fonts() async {
  final cjk = FontLoader('Deng')..addFont(Future.value(ByteData.sublistView(File(r'C:\Windows\Fonts\Deng.ttf').readAsBytesSync())));
  await cjk.load();
  final root = Platform.environment['FLUTTER_ROOT'] ?? r'C:\flutter';
  final icons = File('$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  if (icons.existsSync()) {
    final l = FontLoader('MaterialIcons')..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
    await l.load();
  }
}

Future<void> _shot(WidgetTester tester, String file, {required bool dark, Widget Function()? page}) async {
  SharedPreferences.setMockInitialValues({'flutter.panel_logged_in': true});
  final prefs = await SharedPreferences.getInstance();
  final key = GlobalKey();
  tester.view.physicalSize = const Size(390 * 3, 800 * 3);
  tester.view.devicePixelRatio = 3;
  final theme = AppTheme(dark ? AppThemeMode.dark : AppThemeMode.light, 'Deng');
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWith((ref) => prefs),
        panelAuthProvider.overrideWith(_Auth.new),
      ],
      child: RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: dark ? theme.darkTheme(null) : theme.lightTheme(null),
          // 文案要先读出来（translationsProvider 是异步的），读出来再画页面。
          home: Consumer(
            builder: (context, ref, _) =>
                ref.watch(translationsProvider).hasValue ? (page?.call() ?? SettingsPage()) : const SizedBox(),
          ),
        ),
      ),
    ),
  );
  for (var i = 0; i < 10; i++) {
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
  testWidgets('「我的」页截图（10-18）', (tester) async {
    await tester.runAsync(_fonts);
    await _shot(tester, 'M1-我的.png', dark: false);
    await _shot(tester, 'M2-我的-深色.png', dark: true);
    await _shot(tester, 'M3-帮助与诊断.png', dark: false, page: HelpCenterPage.new);
  }, skip: shotDir.isEmpty);
}

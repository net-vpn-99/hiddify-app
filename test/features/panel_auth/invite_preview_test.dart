// 邀请页截图：真代码（InvitePage）+ 假数据。改邀请页先跑这个看图。
// 不给 SHOT_DIR 就跳过（字体用本机 Windows 自带的等线 Deng.ttf）。
// flutter test test/features/panel_auth/invite_preview_test.dart --dart-define=SHOT_DIR=...
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/core/theme/app_theme.dart';
import 'package:hiddify/core/theme/app_theme_mode.dart';
import 'package:hiddify/features/panel_auth/data/panel_api.dart';
import 'package:hiddify/features/panel_auth/model/invite_referral.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hiddify/features/panel_auth/widget/invite_page.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const shotDir = String.fromEnvironment('SHOT_DIR');

const InviteTexts _texts = (
  bonus: '3 天会员时长',
  share: null,
  linkTemplate: null,
  paidBonus: '7 天会员时长',
  goalText: '1 个月会员时长',
  goal: 3,
  paidMinYuan: 15,
  rate: 10,
);

int _ago(int days) => DateTime.now().subtract(Duration(days: days)).millisecondsSinceEpoch ~/ 1000;

final _rows = [
  InviteReferral(emailMask: '13***@qq.com', createdAt: _ago(1), paid: true, commissionCents: 250, status: 'paid'),
  InviteReferral(emailMask: '免注册 · GS-48213', createdAt: _ago(2), paid: false, commissionCents: 0, status: 'connected'),
  InviteReferral(emailMask: 'ab***@gmail.com', createdAt: _ago(3), paid: false, commissionCents: 0, status: 'registered'),
  InviteReferral(emailMask: '免注册 · GS-50177', createdAt: _ago(6), paid: false, commissionCents: 0, status: 'same_device'),
  InviteReferral(emailMask: 'zh***@163.com', createdAt: _ago(15), paid: false, commissionCents: 0, status: 'expired'),
  InviteReferral(emailMask: '免注册 · GS-61002', createdAt: _ago(16), paid: false, commissionCents: 0, status: 'connected_capped'),
  InviteReferral(emailMask: 'li***@qq.com', createdAt: _ago(17), paid: false, commissionCents: 0, status: 'same_network'),
];

class _Auth extends PanelAuthNotifier {
  _Auth({this.rows = const [], this.failed = false});

  final List<InviteReferral> rows;
  final bool failed;

  @override
  PanelAuthState build() => const PanelAuthState(email: '20129048@qq.com');

  @override
  Future<({String code, String link})?> getInvite() async =>
      failed ? null : (code: 'qItyqYfv', link: 'https://www.gsldvpn.com/i/?c=qItyqYfv');

  @override
  Future<({List<InviteReferral> items, int total, int paidCount})?> getReferrals({int page = 1}) async =>
      failed ? null : (items: rows, total: rows.isEmpty ? 0 : 27, paidCount: rows.isEmpty ? 0 : 4);
}

Future<void> _fonts() async {
  // 按钮没指定字体（手机上用系统默认）、数字用 Saira、邀请码用等宽：测试环境里都拿等线 / 包里的 Saira 顶上。
  final deng = File(r'C:\Windows\Fonts\Deng.ttf').readAsBytesSync();
  for (final name in ['Deng', 'Roboto', 'FlutterTest', 'monospace']) {
    await (FontLoader(name)..addFont(Future.value(ByteData.sublistView(deng)))).load();
  }
  final saira = File('assets/fonts/Saira-SemiBold.ttf').readAsBytesSync();
  await (FontLoader('Saira')..addFont(Future.value(ByteData.sublistView(saira)))).load();
  final root = Platform.environment['FLUTTER_ROOT'] ?? r'C:\flutter';
  final icons = File('$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  if (icons.existsSync()) {
    final l = FontLoader('MaterialIcons')..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
    await l.load();
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _shot(WidgetTester tester, String file, {required bool dark, required _Auth Function() auth, String? tap}) async {
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
        panelAuthProvider.overrideWith(auth),
        inviteTextsProvider.overrideWith((ref) async => _texts),
      ],
      child: RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: dark ? theme.darkTheme(null) : theme.lightTheme(null),
          home: const InvitePage(),
        ),
      ),
    ),
  );
  await _settle(tester);
  // 按钮字在测试里画成方块（测试字体），这里确认字是对的。
  if (file.startsWith('I1')) {
    for (final label in ['复制发给好友', '海报 / 二维码', '分享到其他 App']) {
      expect(find.text(label), findsOneWidget);
    }
  }
  if (tap != null) {
    await tester.tap(find.text(tap));
    await _settle(tester);
    await tester.pump(const Duration(seconds: 1));
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
  testWidgets('邀请页截图（10-18）', (tester) async {
    await tester.runAsync(_fonts);
    await _shot(tester, 'I1-邀请.png', dark: false, auth: () => _Auth(rows: _rows));
    await _shot(tester, 'I2-邀请-深色.png', dark: true, auth: () => _Auth(rows: _rows));
    await _shot(tester, 'I3-海报.png', dark: false, auth: () => _Auth(rows: _rows), tap: '海报 / 二维码');
    await _shot(tester, 'I4-我邀请的人.png', dark: false, auth: () => _Auth(rows: _rows), tap: '我邀请的人');
    await _shot(tester, 'I5-还没邀请过人.png', dark: false, auth: _Auth.new);
    await _shot(tester, 'I6-读取失败.png', dark: false, auth: () => _Auth(failed: true));
  }, skip: shotDir.isEmpty);
}

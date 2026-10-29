import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/theme/app_theme.dart';
import 'package:hiddify/core/theme/app_theme_mode.dart';
import 'package:hiddify/features/home/widget/connection_button.dart';

void main() {
  for (final height in [560.0, 440.0]) {
    for (final textScale in [1.0, 1.3]) {
    testWidgets('activity card never compresses radar drawing at height $height scale $textScale', (tester) async {
      tester.view.physicalSize = Size(390, height);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var requestedRadarSize = 0.0;
      await tester.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)), child: child!),
        theme: AppTheme(AppThemeMode.light, 'Roboto').lightTheme(null),
        home: Scaffold(body: HomeConnectPanel(
          radar: (size) {
            requestedRadarSize = size;
            return SizedBox(key: const ValueKey('radar'), width: size, height: size);
          },
          onTap: () {}, enabled: true, kicker: '', connectedDot: true,
          title: '日本 东京 01 双传输内测', sub: '标准线路',
          statusExtra: const [SizedBox(height: 64)],
          middle: const [SizedBox(height: 130, child: Text('关注 TG 频道送 1 天')), SizedBox(height: 112)],
          buttonLabel: '断开连接', showAllLines: true,
        )),
      ));
      expect(tester.takeException(), isNull);
      final radar = tester.getRect(find.byKey(const ValueKey('radar')));
      expect(radar.height, greaterThanOrEqualTo(requestedRadarSize));
      expect(radar.bottom, lessThanOrEqualTo(tester.getTopLeft(find.text('日本 东京 01 双传输内测')).dy));
      await tester.ensureVisible(find.text('断开连接'));
      await tester.tap(find.text('断开连接'));
      expect(tester.takeException(), isNull);
    });
    }
  }
}

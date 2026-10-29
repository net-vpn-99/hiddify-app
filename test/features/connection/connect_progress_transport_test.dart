import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/home/widget/connect_progress.dart';
import 'package:hiddify/features/proxy/line/line_source.dart';
import 'package:hiddify/features/proxy/model/node_display.dart';

void main() {
  for (final unavailable in [true, false]) {
    test('startup availability follows logical identity, unavailable=$unavailable', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWith((ref) => prefs),
        lineSetProvider.overrideWith((ref) async => const LineSet(locked: false, lines: [
          (name: '日本 大阪 05 双传输内测', desc: '', isps: null, pro: false, routeId: 'ln_os05'),
        ])),
        unavailableLogicalLinesProvider.overrideWith((ref) async => unavailable ? {'ln_os05'} : {'ln_another_same_name'}),
      ]);
      addTearDown(container.dispose);
      final result = await lineGoneProgress(container.read);
      if (unavailable) {
        expect(result?.failedStep, 3);
        expect(result?.title, contains('暂不可用'));
        expect(result?.lineGone, isFalse);
      } else {
        expect(result, isNull);
      }
    });
  }
}

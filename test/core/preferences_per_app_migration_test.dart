import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/preferences/preferences_migration.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 去掉「分应用代理」入口以后，老用户开着的要关掉（不然再也关不了）。
void main() {
  test('开着的分应用代理关掉；没设过的不写', () async {
    SharedPreferences.setMockInitialValues({'per_app_proxy_mode': 'include'});
    var prefs = await SharedPreferences.getInstance();
    await OneRayPerAppProxyOffMigration(prefs).migrate();
    expect(prefs.getString('per_app_proxy_mode'), 'off');

    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    await OneRayPerAppProxyOffMigration(prefs).migrate();
    expect(prefs.getString('per_app_proxy_mode'), isNull);
  });
}

import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/gen/translations.g.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'locale_preferences.g.dart';

@Riverpod(keepAlive: true)
class LocalePreferences extends _$LocalePreferences with AppLogger {
  @override
  AppLocale build() {
    final persisted = ref.watch(sharedPreferencesProvider).requireValue.getString("locale");
    // OneRay: 首次引导页已去掉（原来由它按时区设中文），没选过语言一律中文
    if (persisted == null) return AppLocale.zhCn;
    // keep backward compatibility with chinese after changing zh to zh_CN
    if (persisted == "zh") {
      return AppLocale.zhCn;
    }
    try {
      return AppLocale.values.byName(persisted);
    } catch (e) {
      loggy.error("error setting locale: [$persisted]", e);
      return AppLocale.en;
    }
  }

  Future<void> changeLocale(AppLocale value) async {
    state = value;
    await ref.read(sharedPreferencesProvider).requireValue.setString("locale", value.name);
  }
}

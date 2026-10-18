import 'package:flutter/material.dart';
import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/failures.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/core/theme/app_theme_mode.dart';
import 'package:hiddify/core/theme/oneray_tokens.dart';
import 'package:hiddify/core/theme/theme_preferences.dart';
import 'package:hiddify/features/app_update/notifier/app_update_notifier.dart';
import 'package:hiddify/features/app_update/notifier/app_update_state.dart';
import 'package:hiddify/features/connection/data/system_settings.dart';
import 'package:hiddify/utils/alerts.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 设置（B 夜航 §3.9，画布「设置」）：最上面外观三选一，下面只放现在已有的开关，没加新功能。
/// 跟 Windows「我的 → 设置」同一个样子。
class AppSettingsPage extends ConsumerWidget {
  const AppSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tk = OneRayTokens.of(context);
    final mode = ref.watch(themePreferencesProvider);
    // 「纯黑」不单独给入口：选过的人这里显示成「深色」。
    final shown = mode == AppThemeMode.black ? AppThemeMode.dark : mode;
    final speedInBar = ref.watch(Preferences.dynamicNotification);
    final version = ref.watch(appInfoProvider).valueOrNull?.presentVersion ?? '';
    final checking = ref.watch(appUpdateNotifierProvider) is AppUpdateStateChecking;
    // 「检查更新」就在这一行原地查，不跳页：有新版的弹窗由主页那边弹（主页一直挂着），
    // 这里只补主页不管的三种——之前点过「忽略」的、已是最新、查失败。
    ref.listen(appUpdateNotifierProvider, (prev, next) async {
      if (!context.mounted || prev is! AppUpdateStateChecking) return;
      final t = ref.read(translationsProvider).requireValue;
      switch (next) {
        case AppUpdateStateIgnored(:final versionInfo):
          await ref.read(dialogNotifierProvider.notifier).showNewVersion(
                currentVersion: version,
                newVersion: versionInfo,
                canIgnore: !versionInfo.mandatory,
              );
        case AppUpdateStateNotAvailable():
          CustomToast.success(t.pages.about.notAvailableMsg).show(context);
        case AppUpdateStateError(:final error):
          CustomToast.error(t.presentShortError(error)).show(context);
        default:
      }
    });

    Widget card(List<Widget> children) => Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      decoration: BoxDecoration(color: tk.card, borderRadius: BorderRadius.circular(18)),
      child: Column(children: children),
    );

    return Scaffold(
      backgroundColor: tk.bg,
      appBar: AppBar(title: const Text('设置'), backgroundColor: tk.bg),
      body: SafeArea(
        top: false,
        child: ListView(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
              child: Text('外观', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: tk.text)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: SizedBox(
                width: double.infinity,
                child: SegmentedButton<AppThemeMode>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: AppThemeMode.system, label: Text('跟随系统')),
                    ButtonSegment(value: AppThemeMode.dark, label: Text('深色')),
                    ButtonSegment(value: AppThemeMode.light, label: Text('浅色')),
                  ],
                  selected: {shown},
                  onSelectionChanged: (v) => ref.read(themePreferencesProvider.notifier).changeThemeMode(v.first),
                ),
              ),
            ),
            card([
              SwitchListTile(
                title: Text('通知栏显示网速', style: TextStyle(fontSize: 15, color: tk.text)),
                subtitle: Text('连着的时候在通知栏看到速度', style: TextStyle(fontSize: 12, color: tk.sub)),
                value: speedInBar,
                onChanged: (v) => ref.read(Preferences.dynamicNotification.notifier).update(v),
              ),
              ListTile(
                title: Text('允许后台运行', style: TextStyle(fontSize: 15, color: tk.text)),
                subtitle: Text('锁屏以后连接不被系统关掉', style: TextStyle(fontSize: 12, color: tk.sub)),
                trailing: Icon(Icons.chevron_right_rounded, color: tk.sub),
                onTap: SettingsAction.battery.open,
              ),
            ]),
            card([
              ListTile(
                title: Text('版本 $version', style: TextStyle(fontSize: 15, color: tk.text)),
                trailing: checking
                    ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: tk.acc))
                    : Text('检查更新', style: TextStyle(fontSize: 13, color: tk.acc)),
                onTap: checking ? null : () => ref.read(appUpdateNotifierProvider.notifier).check(),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

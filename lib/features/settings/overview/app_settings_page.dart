import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/theme/app_theme_mode.dart';
import 'package:hiddify/core/theme/oneray_tokens.dart';
import 'package:hiddify/core/theme/theme_preferences.dart';
import 'package:hiddify/features/connection/data/system_settings.dart';
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
                trailing: Text('检查更新', style: TextStyle(fontSize: 13, color: tk.acc)),
                onTap: () => context.pushNamed('about'),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/core/model/remote_site_config.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/router/bottom_sheets/bottom_sheets_notifier.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/core/router/go_router/helper/active_breakpoint_notifier.dart';
import 'package:hiddify/features/diagnostic/diag_tile.dart';
import 'package:hiddify/features/panel_auth/widget/account_card.dart';
import 'package:hiddify/features/support/notifier/support_chat_notifier.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

enum ConfigOptionSection {
  warp,
  fragment;

  static final _warpKey = GlobalKey(debugLabel: "warp-section-key");
  static final _fragmentKey = GlobalKey(debugLabel: "fragment-section-key");

  GlobalKey get key => switch (this) {
    ConfigOptionSection.warp => _warpKey,
    ConfigOptionSection.fragment => _fragmentKey,
  };
}

/// 「我的」页（1.1.28 重做）。
///
/// 三段，越往下越不常用：**账号卡**（我是谁 + 剩多久 + 买套餐 / 账号管理 + 游客绑邮箱
/// 提醒）→ **四个方块**（邀请返利 / 在线客服 / 常见问题 / 连接诊断）→ **两行列表**
/// （应用设置 / 关于）。
///
/// 删掉的老东西：
///  - 右上角 ⋮「导入配置 / 重置配置」—— Hiddify 遗留，小白点一下能把自己搞挂；
///  - 「高级设置」整块（路由 / DNS / 入站 / TLS / WARP / 日志）—— 我们的配置全是服务端
///    下发的，用户改只有坏处。**没真删**：在「关于」页连点版本号 5 次会显出来
///    （Preferences.devMode），客服排障时还用得上；
///  - 三个分组小标题 —— 方块和列表本身已经分开了。
class SettingsPage extends HookConsumerWidget {
  SettingsPage({super.key, String? section})
    : section = section != null ? ConfigOptionSection.values.byName(section) : null;

  final ConfigOptionSection? section;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final devMode = ref.watch(Preferences.devMode);

    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: ListView(
        children: [
          const AccountCard(),
          const _ActionGrid(),
          const SizedBox(height: 4),
          const Divider(height: 1),
          _row(
            context,
            icon: Icons.tune_rounded,
            title: '应用设置',
            onTap: () => context.pushNamed('general'),
          ),
          if (Breakpoint(context).isMobile())
            _row(
              context,
              icon: Icons.info_outline_rounded,
              title: t.pages.about.title,
              onTap: () => context.pushNamed('about'),
            ),
          // 连点版本号解锁出来的那堆，普通用户永远看不到。
          if (devMode) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(
                '高级设置（客服排障用）',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
            SettingsSection(
              title: t.pages.settings.routing.title,
              icon: Icons.route_rounded,
              namedLocation: context.namedLocation('routeOptions'),
            ),
            SettingsSection(
              title: t.pages.settings.dns.title,
              icon: Icons.dns_rounded,
              namedLocation: context.namedLocation('dnsOptions'),
            ),
            SettingsSection(
              title: t.pages.settings.inbound.title,
              icon: Icons.input_rounded,
              namedLocation: context.namedLocation('inboundOptions'),
            ),
            SettingsSection(
              title: t.pages.settings.tlsTricks.title,
              icon: Icons.content_cut_rounded,
              namedLocation: context.namedLocation('tlsTricks'),
            ),
            SettingsSection(
              title: t.pages.settings.warp.title,
              icon: Icons.cloud_rounded,
              namedLocation: context.namedLocation('warpOptions'),
            ),
            SettingsSection(
              title: t.pages.logs.title,
              icon: Icons.description_rounded,
              namedLocation: context.namedLocation('logs'),
            ),
            // 订阅管理：1.1.28 起首页和线路页都不再有入口（订阅是自动导入的，用户没
            // 必要碰）。留在这里，万一要手动导一份配置排障还能找到。
            Material(
              child: ListTile(
                leading: const Icon(Icons.swap_horiz_rounded),
                title: Text(t.pages.profiles.title),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => ref.read(bottomSheetsNotifierProvider.notifier).showProfilesOverview(),
              ),
            ),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _row(
    BuildContext context, {
    required IconData icon,
    required String title,
    required VoidCallback onTap,
  }) {
    return Material(
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: onTap,
      ),
    );
  }
}

/// 邀请返利 / 在线客服 / 常见问题 / 连接诊断 —— 最常点的四个，一屏之内够得着。
class _ActionGrid extends ConsumerWidget {
  const _ActionGrid();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unseen = ref.watch(supportChatNotifierProvider.select((s) => s.unseenAgentCount));
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: _cell(
              context,
              icon: Icons.card_giftcard_outlined,
              label: '邀请返利',
              // 没账号也照样摆在这儿（首页不拦人那套），点了才说要先有账号。
              onTap: () => ref.read(Preferences.panelLoggedIn)
                  ? context.pushNamed('invite')
                  : ref.read(dialogNotifierProvider.notifier).showNeedAccount(
                      message: '邀请返利要先有账号。登录已有账号，或者买个套餐就能用。',
                    ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _cell(
              context,
              icon: Icons.support_agent_outlined,
              label: '在线客服',
              badge: unseen > 0,
              onTap: () => context.pushNamed('supportChat'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _cell(
              context,
              icon: Icons.help_outline_rounded,
              label: '常见问题',
              onTap: () async {
                await RemoteSiteConfig.ensureLoaded();
                await UriUtils.tryLaunch(Uri.parse(RemoteSiteConfig.helpUrlOr(Constants.faqUrl)));
              },
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: DiagTile(
              builder: (context, busy, run) => _cell(
                context,
                icon: Icons.build_outlined,
                label: '连接诊断',
                busy: busy,
                onTap: run,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _cell(
    BuildContext context, {
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    bool badge = false,
    bool busy = false,
  }) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 24,
                child: busy
                    ? const Center(
                        child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    : Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Icon(icon, size: 24, color: theme.colorScheme.onSurfaceVariant),
                          if (badge)
                            Positioned(
                              right: -2,
                              top: -2,
                              child: Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.error,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                        ],
                      ),
              ),
              const SizedBox(height: 6),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SettingsSection extends HookConsumerWidget {
  const SettingsSection({super.key, required this.title, required this.icon, required this.namedLocation});

  final String title;
  final IconData icon;
  final String namedLocation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => context.go(namedLocation),
    );
  }
}

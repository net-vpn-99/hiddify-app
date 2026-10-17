import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/core/model/remote_site_config.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/router/bottom_sheets/bottom_sheets_notifier.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/core/theme/app_theme_mode.dart';
import 'package:hiddify/core/theme/oneray_tokens.dart';
import 'package:hiddify/core/theme/theme_preferences.dart';
import 'package:hiddify/features/common/soft_card.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/connection/notifier/local_repair.dart';
import 'package:hiddify/features/diagnostic/diag_tile.dart';
import 'package:hiddify/features/panel_auth/widget/account_card.dart';
import 'package:hiddify/features/panel_auth/widget/invite_gate.dart';
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

/// 「我的」页（10-15 精简，跟 Windows「更多」同一个思路：首页有的这里不再放一遍）。
///
/// 从上到下：**账号卡**（我是谁 + 剩多久，点进账号管理；续费 / 在另一台设备上用）→
/// **四个方块**（邀请返利 / 在线客服 / 常见问题 / 连接诊断）→ **初始化本地网络** →
/// **最下面一行小字**（版本号 · 官网 · 备用入口，点版本号进「关于」检查更新）。
///
/// 不在这里的：常用网站、TG 频道在首页。「应用设置」（内存上限 / 日志级别 / 调试模式…）和
/// 「高级设置」（路由 / DNS / 入站 / TLS / WARP / 日志）普通用户用不上，在「关于」页连点版本号
/// 5 次才显出来（Preferences.devMode），客服排障时用。
///
/// 样子参照 GoMami 会员中心（运营 10-15 定）：暖浅灰底、白卡不描边只带淡阴影（SoftCard）、
/// 每个图标垫一块强调色浅底小方块（IconTile），主按钮用强调色（B 夜航只有一种强调色）。
/// 底色和字色用 OneRayTokens（跟 Windows / 官网同一套）。
/// 试过两版不要的：Material 从金色种子算出来的米色卡 + 橄榄棕按钮（土）；黑白（压抑）。
class SettingsPage extends HookConsumerWidget {
  SettingsPage({super.key, String? section})
    : section = section != null ? ConfigOptionSection.values.byName(section) : null;

  final ConfigOptionSection? section;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final devMode = ref.watch(Preferences.devMode);

    final tk = OneRayTokens.of(context);
    return Scaffold(
      backgroundColor: tk.bg,
      appBar: AppBar(title: const Text('我的'), backgroundColor: tk.bg, surfaceTintColor: Colors.transparent),
      body: ListView(
        children: [
          const AccountCard(),
          const _ActionGrid(),
          const MenuGroup(children: [_AppearanceRow(), _LocalInitRow()]),
          const _FootLinks(),
          // 连点版本号解锁出来的那堆，普通用户永远看不到。
          if (devMode) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(
                '高级设置（客服排障用）',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
            MenuGroup(
              children: [
                MenuRow(icon: Icons.tune_rounded, title: '应用设置', onTap: () => context.pushNamed('general')),
                for (final (title, icon, name) in [
                  (t.pages.settings.routing.title, Icons.route_rounded, 'routeOptions'),
                  (t.pages.settings.dns.title, Icons.dns_rounded, 'dnsOptions'),
                  (t.pages.settings.inbound.title, Icons.input_rounded, 'inboundOptions'),
                  (t.pages.settings.tlsTricks.title, Icons.content_cut_rounded, 'tlsTricks'),
                  (t.pages.settings.warp.title, Icons.cloud_rounded, 'warpOptions'),
                  (t.pages.logs.title, Icons.description_rounded, 'logs'),
                ])
                  MenuRow(icon: icon, title: title, onTap: () => context.go(context.namedLocation(name))),
                // 订阅管理：1.1.28 起首页和线路页都不再有入口（订阅是自动导入的，用户没
                // 必要碰）。留在这里，万一要手动导一份配置排障还能找到。
                MenuRow(
                  icon: Icons.swap_horiz_rounded,
                  title: t.pages.profiles.title,
                  onTap: () => ref.read(bottomSheetsNotifierProvider.notifier).showProfilesOverview(),
                ),
              ],
            ),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

/// 外观三选一（B 夜航 §3.9，跟 Windows 设置里同一个样子）。以前藏在「高级设置 → 应用设置」，普通用户找不到。
/// 「纯黑」不单独给入口：选过的人这里显示成「深色」。
class _AppearanceRow extends ConsumerWidget {
  const _AppearanceRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tk = OneRayTokens.of(context);
    final mode = ref.watch(themePreferencesProvider);
    final shown = mode == AppThemeMode.black ? AppThemeMode.dark : mode;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      // 标题一行、三选一另起一行占满宽：窄屏、系统字号调大时「跟随系统」也不会被挤断。
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const IconTile(Icons.contrast_rounded, size: 38),
              const SizedBox(width: 16),
              Text('外观', style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: tk.text)),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
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
        ],
      ),
    );
  }
}

/// 一组行放在一张白卡里，行之间画细线。
class MenuGroup extends StatelessWidget {
  const MenuGroup({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final tk = OneRayTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: SoftCard(
        child: Column(
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) Divider(height: 1, indent: 72, color: tk.ring.withValues(alpha: 0.5)),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}

/// 一行：强调色小方块的图标 + 名字 + 右边灰色小字（hint）+ ›。「我的」页所有行都用它。
class MenuRow extends StatelessWidget {
  const MenuRow({
    super.key,
    required this.icon,
    required this.title,
    this.hint,
    this.busy = false,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String? hint;
  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tk = OneRayTokens.of(context);
    final muted = tk.sub;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: IconTile(icon, size: 38),
      title: Text(title, style: theme.textTheme.bodyLarge?.copyWith(color: tk.text)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hint != null) Text(hint!, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
          const SizedBox(width: 4),
          if (busy)
            const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
          else
            Icon(Icons.chevron_right_rounded, color: muted),
        ],
      ),
      onTap: busy ? null : onTap,
    );
  }
}

/// 最下面一行小字（跟 Windows「更多」底部同一行）：光速雷达 版本号（点进「关于」检查更新）·
/// 官网 · 备用入口（官网打不开时用）。
class _FootLinks extends ConsumerWidget {
  const _FootLinks();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final tk = OneRayTokens.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(color: tk.sub);
    final version = ref.watch(appInfoProvider).valueOrNull?.presentVersion ?? '';
    Widget link(String text, VoidCallback onTap) => InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        child: Text(text, style: style),
      ),
    );
    final dot = Text('·', style: style);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        link('光速雷达 $version', () => context.pushNamed('about')),
        dot,
        link('官网', () => UriUtils.tryLaunch(Uri.parse(Constants.websiteUrl))),
        dot,
        link('备用入口', () => UriUtils.tryLaunch(Uri.parse(Constants.statusPageUrl))),
      ],
    );
  }
}

/// 「初始化本地网络」（两端同名，Windows 在「更多」里）：一直在，他自己找过来点的不会误会。
/// 做什么见 local_repair.dart；不弹确认框，做完一句话说做了哪几步。
class _LocalInitRow extends ConsumerStatefulWidget {
  const _LocalInitRow();

  @override
  ConsumerState<_LocalInitRow> createState() => _LocalInitRowState();
}

class _LocalInitRowState extends ConsumerState<_LocalInitRow> {
  bool _busy = false;

  Future<void> _run() async {
    final s = ref.read(connectionNotifierProvider).valueOrNull;
    final wasUp = s is Connected || s is Connecting;
    setState(() => _busy = true);
    final done = await ref.read(localRepairProvider).initialize();
    if (!mounted) return;
    setState(() => _busy = false);
    if (done.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(content: Text('已$done${wasUp ? '，正在重新连接' : ''}')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MenuRow(
      icon: Icons.restart_alt_rounded,
      title: '初始化本地网络',
      hint: '网页打不开时用',
      busy: _busy,
      onTap: _run,
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
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Row(
        children: [
          Expanded(
            child: _cell(
              context,
              icon: Icons.card_giftcard_outlined,
              label: '邀请返利',
              // 没账号也照样摆在这儿（首页不拦人那套），点了才说要先有账号。
              onTap: () => ref.read(Preferences.panelLoggedIn)
                  ? openInvite(context)
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
    final tk = OneRayTokens.of(context);
    return SoftCard(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 40,
                child: busy
                    ? const Center(
                        child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    : Badge(
                        isLabelVisible: badge,
                        smallSize: 9,
                        child: IconTile(icon),
                      ),
              ),
              const SizedBox(height: 8),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: tk.text),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

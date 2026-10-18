import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/router/bottom_sheets/bottom_sheets_notifier.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/core/theme/oneray_tokens.dart';
import 'package:hiddify/features/common/soft_card.dart';
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

/// 「我的」页（B 夜航，画布「我的」；跟 Windows「我的」侧栏同样的内容）。
///
/// 从上到下：**账户卡**（我是谁 + 剩多久，点进账号管理；今日高速、设备；一颗「续费 / 升级」）→
/// **两组入口**（在另一台设备上用 / 邀请返利 / 联系客服 ｜ 帮助与诊断 / 设置；「帮助与诊断」里是常见问题、连接诊断、
/// 初始化本地网络）→
/// **最下面一行小字**（版本号 · 官网 · 备用入口，点版本号进「关于」检查更新）。
///
/// 不在这里的：常用网站、TG 频道在首页。「应用设置」（内存上限 / 日志级别 / 调试模式…）和
/// 「高级设置」（路由 / DNS / 入站 / TLS / WARP / 日志）普通用户用不上，在「关于」页连点版本号
/// 5 次才显出来（Preferences.devMode），客服排障时用。
class SettingsPage extends HookConsumerWidget {
  SettingsPage({super.key, String? section})
    : section = section != null ? ConfigOptionSection.values.byName(section) : null;

  final ConfigOptionSection? section;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final devMode = ref.watch(Preferences.devMode);
    final unseen = ref.watch(supportChatNotifierProvider.select((s) => s.unseenAgentCount));
    final loggedIn = ref.watch(Preferences.panelLoggedIn);

    final tk = OneRayTokens.of(context);
    return Scaffold(
      backgroundColor: tk.bg,
      appBar: AppBar(title: const Text('我的'), backgroundColor: tk.bg, surfaceTintColor: Colors.transparent),
      body: ListView(
        children: [
          const AccountCard(),
          MenuGroup(
            children: [
              if (loggedIn) MenuRow(title: '在另一台设备上用', onTap: () => context.pushNamed('addDevice')),
              MenuRow(
                title: '邀请返利',
                // 没账号也照样摆在这儿（首页不拦人那套），点了才说要先有账号。
                onTap: () => loggedIn
                    ? openInvite(context)
                    : ref.read(dialogNotifierProvider.notifier).showNeedAccount(
                        message: '邀请返利要先有账号。登录已有账号，或者买个套餐就能用。',
                      ),
              ),
              MenuRow(title: '联系客服', dot: unseen > 0, onTap: () => context.pushNamed('supportChat')),
            ],
          ),
          // 遇到问题的三样（常见问题 / 连接诊断 / 初始化本地网络）收进「帮助与诊断」一页（10-18 我的页减法，方案 B）。
          MenuGroup(
            children: [
              MenuRow(title: '帮助与诊断', hint: '常见问题 · 诊断 · 修网络', onTap: () => context.pushNamed('helpCenter')),
              MenuRow(title: '设置', onTap: () => context.pushNamed('appSettings')),
            ],
          ),
          const _FootLinks(),
          // 连点版本号解锁出来的那堆，普通用户永远看不到。
          if (devMode) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Text('高级设置（客服排障用）', style: TextStyle(fontSize: 12, color: tk.sub)),
            ),
            MenuGroup(
              children: [
                MenuRow(title: '应用设置', onTap: () => context.pushNamed('general')),
                for (final (title, name) in [
                  (t.pages.settings.routing.title, 'routeOptions'),
                  (t.pages.settings.dns.title, 'dnsOptions'),
                  (t.pages.settings.inbound.title, 'inboundOptions'),
                  (t.pages.settings.tlsTricks.title, 'tlsTricks'),
                  (t.pages.settings.warp.title, 'warpOptions'),
                  (t.pages.logs.title, 'logs'),
                ])
                  MenuRow(title: title, onTap: () => context.go(context.namedLocation(name))),
                // 订阅管理：1.1.28 起首页和线路页都不再有入口（订阅是自动导入的，用户没
                // 必要碰）。留在这里，万一要手动导一份配置排障还能找到。
                MenuRow(
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

/// 一组行放在一张卡里（不描边），行之间画细线。
class MenuGroup extends StatelessWidget {
  const MenuGroup({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final tk = OneRayTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: SoftCard(
        child: Column(
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) Divider(height: 1, indent: 16, endIndent: 16, color: tk.ring.withValues(alpha: 0.5)),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}

/// 一行：名字（有新消息带强调色小点）+ 右边灰色小字（hint）+ ›。「我的」页所有行都用它。
class MenuRow extends StatelessWidget {
  const MenuRow({super.key, required this.title, this.hint, this.dot = false, this.busy = false, this.onTap});

  final String title;
  final String? hint;
  final bool dot;
  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tk = OneRayTokens.of(context);
    return ListTile(
      minTileHeight: 52,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      // 名字不折行；地方不够时让右边的灰色小字省略（以前「初始化本地网络」被挤成两行）。
      title: Row(
        children: [
          Text(title, maxLines: 1, softWrap: false, style: TextStyle(fontSize: 15, color: tk.text)),
          if (dot) ...[
            const SizedBox(width: 6),
            Container(width: 7, height: 7, decoration: BoxDecoration(color: tk.acc, shape: BoxShape.circle)),
          ],
          if (hint != null) ...[
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                hint!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
                style: TextStyle(fontSize: 12, color: tk.sub),
              ),
            ),
          ],
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy)
            const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
          else
            Icon(Icons.chevron_right_rounded, color: tk.sub, size: 20),
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

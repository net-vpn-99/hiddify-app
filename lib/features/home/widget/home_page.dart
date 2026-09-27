import 'package:dartx/dartx.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/features/app_update/data/apk_installer.dart';
import 'package:hiddify/features/app_update/notifier/app_update_notifier.dart';
import 'package:hiddify/features/app_update/notifier/app_update_state.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/connection/notifier/route_check_notifier.dart';
import 'package:hiddify/features/connection/notifier/stability_notifier.dart';
import 'package:hiddify/features/connection/widget/stability_indicator.dart';
import 'package:hiddify/features/home/widget/account_status_bar.dart';
import 'package:hiddify/features/home/widget/connect_issue_card.dart';
import 'package:hiddify/features/home/widget/connection_button.dart';
import 'package:hiddify/features/home/widget/line_bar.dart';
import 'package:hiddify/features/panel_auth/notifier/guest_bootstrap.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hiddify/core/router/go_router/refresh_listenable.dart';
import 'package:hiddify/features/panel_auth/widget/account_key_dialog.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/features/proxy/active/auto_line_fixer.dart';
import 'package:hiddify/features/proxy/model/node_display.dart';
import 'package:hiddify/features/stats/notifier/stats_notifier.dart';
import 'package:hiddify/features/support/widget/support_failure_link.dart';
import 'package:hiddify/gen/assets.gen.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hiddify/utils/number_formatters.dart';
import 'package:hiddify/utils/uri_utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 首页（1.1.28 重做）。
///
/// 从上到下只有四样东西：顶栏（logo + 设置）、连接按钮、线路条、状态条。往下不用滑。
/// 设计原则：**首页永远不拦人、永远不空白** —— 没账号、试用到期、订阅是空的，节点和
/// 套餐入口照常显示，只有真正点下去（连接 / 选线路 / 看套餐）时才判断该让他登录、
/// 绑邮箱还是买套餐。
///
/// 删掉的老东西（都是 Hiddify 原装或早期改的，小白看不懂又会凭空消失）：
///  - 顶上那张「光速卡」ProfileTile —— 信息拆进线路条和状态条；它原来还是选线路的
///    唯一入口，没订阅时整张卡不见，首页就只剩一个光秃秃的连接按钮；
///  - 连接后底部的 ActiveProxyFooter —— 和线路条重复；
///  - 顶栏「+ 加订阅」按钮和快捷设置 —— 前者在游客体系下没人需要，后者（服务模式 /
///    WARP）是极客开关，挪进「我的 → 应用设置」。
class HomePage extends HookConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final t = ref.watch(translationsProvider).requireValue;
    // 连接后自动把默认的 balance/lowest 均衡组切成真实线路
    ref.watch(autoLineFixerProvider);

    useEffect(() {
      final code = pendingInviteFromLink;
      if (code.isNotEmpty) {
        pendingInviteFromLink = '';
        Future(() => ref.read(panelAuthProvider.notifier).applyInviteCode(code));
      }
      // 装好第一次打开：在后台静默开游客号（开不出来首页照常能逛）。
      Future(() => ref.read(guestBootstrapProvider.notifier).ensure());
      // OneRay: 启动后清掉残留更新包 + 静默检查更新一次
      ApkInstaller.cleanupApks();
      Future.delayed(const Duration(seconds: 3), () {
        if (context.mounted) ref.read(appUpdateNotifierProvider.notifier).check();
      });
      return null;
    }, const []);

    // 刚开出一个免注册的号：把「账号编号 + 密码」摆一次让他抄走。服务端只发这一次，
    // 见 account_key_dialog.dart。「我的」页会一直挂红点，这次没看到也跑不掉。
    ref.listen(panelAuthProvider.select((s) => s.guestPassword), (prev, next) {
      if (next == null || next.isEmpty) return;
      if (ref.read(Preferences.guestKeySaved)) return;
      Future(() {
        if (context.mounted) showAccountKeyDialog(context, ref);
      });
    });

    // OneRay: 记住当前线路名，断开时首页也能显示
    ref.listen(activeProxyNotifierProvider, (_, next) {
      final tag = next.valueOrNull?.tagDisplay ?? '';
      if (tag.isEmpty) return;
      final n = splitNodeName(tag);
      ref.read(Preferences.lastNodeName.notifier).update(n.name);
      ref.read(Preferences.lastNodeDesc.notifier).update(n.desc);
    });
    ref.listen(appUpdateNotifierProvider, (_, next) async {
      if (!context.mounted) return;
      if (next case AppUpdateStateAvailable(:final versionInfo)) {
        final appInfo = ref.read(appInfoProvider).requireValue;
        await ref.read(dialogNotifierProvider.notifier).showNewVersion(
          currentVersion: appInfo.presentVersion,
          newVersion: versionInfo,
          canIgnore: !versionInfo.mandatory,
        );
      }
    });

    return Scaffold(
      appBar: AppBar(
        // 品牌组合：官网同一个金底雷达标 + 「光速雷达」。别换成 logo.svg —— 那份是
        // 无底色的纯图形，连接按钮把它整体染色用（`ColorFilter.srcIn`），加了底色方块
        // 会被染成一个实心圆角方块。
        title: Row(
          children: [
            Assets.images.brandMark.svg(height: 26, width: 26),
            const Gap(10),
            Text(t.common.appTitle, style: const TextStyle(letterSpacing: .5)),
          ],
        ),
        actions: [
          // 回官网：买套餐、看教程、邀请都在官网上，客户端里原来没有入口（两端同时加）。
          TextButton(
            onPressed: () => UriUtils.tryLaunch(Uri.parse(Constants.websiteUrl)),
            child: const Text('官网 ↗'),
          ),
          Semantics(
            key: const ValueKey("app_settings"),
            label: t.pages.settings.general.title,
            child: IconButton(
              icon: Icon(Icons.settings_outlined, color: theme.colorScheme.primary),
              onPressed: () => context.pushNamed('general'),
            ),
          ),
          const Gap(8),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          image: DecorationImage(
            image: const AssetImage('assets/images/world_map.png'),
            fit: BoxFit.cover,
            opacity: 0.09,
            colorFilter: theme.brightness == Brightness.dark
                ? ColorFilter.mode(Colors.white.withValues(alpha: .15), BlendMode.srcIn)
                : ColorFilter.mode(Colors.grey.withValues(alpha: 1), BlendMode.srcATop),
          ),
        ),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 600),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        ConnectionButton(),
                        _SpeedLine(),
                        StabilityIndicator(),
                        _GoogleTestButton(),
                        ConnectIssueCard(),
                        SupportFailureLink(),
                      ],
                    ),
                  ),
                  const _RouteRulesEntry(),
                  const LineBar(),
                  const AccountStatusBar(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 连上之后按钮下面那行实时速率。
///
/// 故意**不显示延迟毫秒数**：用户会拿它跟别家比，而别家标的常常是到中转入口、不是到
/// 落地节点的，真数字比不过假数字。速率是正向的 —— 数字大就是快，看着高兴。
class _SpeedLine extends ConsumerWidget {
  const _SpeedLine();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final connected = ref.watch(connectionNotifierProvider).valueOrNull is Connected;
    if (!connected) return const SizedBox(height: 18);

    final stats = ref.watch(statsNotifierProvider).valueOrNull ?? SystemInfo.create();
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        '↓ ${stats.downlink.toInt().speed()}    ↑ ${stats.uplink.toInt().speed()}',
        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}

/// 连上之后给新用户一个「下一步」：点一下用默认浏览器打开谷歌搜索，看到结果就知道网通了。
/// 搜「今天天气」是因为谷歌会直接出天气卡片，最直观。没连上时什么都不画。
class _GoogleTestButton extends ConsumerWidget {
  const _GoogleTestButton();

  static const _url = 'https://www.google.com/search?q=%E4%BB%8A%E5%A4%A9%E5%A4%A9%E6%B0%94';

  // 跟 StabilityIndicator 分数 ≥ 8 的「稳定」绿同一色。
  static const _stableGreen = Color(0xFF3FA372);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connected = ref.watch(connectionNotifierProvider).valueOrNull is Connected;
    // 真通了才给（还在「连接中」或中途断了时点了也打不开，只会让人更慌）。
    final health = ref.watch(stabilityProvider);
    if (!connected || !health.confirmed || health.outage) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: FilledButton.tonalIcon(
        onPressed: () => UriUtils.tryLaunch(Uri.parse(_url)),
        icon: const Icon(Icons.search, size: 18),
        label: const Text('测试谷歌'),
        style: FilledButton.styleFrom(
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          backgroundColor: _stableGreen.withValues(alpha: 0.14),
          foregroundColor: _stableGreen,
        ),
      ),
    );
  }
}

class AppVersionLabel extends HookConsumerWidget {
  const AppVersionLabel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);

    final version = ref.watch(appInfoProvider).requireValue.presentVersion;
    if (version.isBlank) return const SizedBox();

    return Semantics(
      label: t.common.version,
      button: false,
      child: Container(
        decoration: BoxDecoration(color: theme.colorScheme.secondaryContainer, borderRadius: BorderRadius.circular(4)),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        child: Text(
          version,
          textDirection: TextDirection.ltr,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSecondaryContainer),
        ),
      ),
    );
  }
}

/// 首页「查看分流规则」入口：一直都在（用户最常在连接之前犹豫「QQ 会不会变美国登录」）。
/// 实测出异常时前面亮一个橙点。watch 一下 routeCheckProvider 也让它从首页起就活着，
/// 连上第一次测通时能自动测。
class _RouteRulesEntry extends ConsumerWidget {
  const _RouteRulesEntry();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final warn = ref.watch(routeCheckProvider.select((s) => s.warning.isNotEmpty));
    return Center(
      child: TextButton.icon(
        style: TextButton.styleFrom(
          foregroundColor: theme.colorScheme.onSurfaceVariant,
          minimumSize: const Size(48, 40),
        ),
        onPressed: () => context.pushNamed('routeRules'),
        icon: warn
            ? const Icon(Icons.circle, size: 8, color: Color(0xFFCF8A3B))
            : const Icon(Icons.help_outline, size: 16),
        label: const Text('查看分流规则'),
      ),
    );
  }
}

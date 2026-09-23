import 'package:dartx/dartx.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/features/app_update/data/apk_installer.dart';
import 'package:hiddify/features/app_update/notifier/app_update_notifier.dart';
import 'package:hiddify/features/app_update/notifier/app_update_state.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/connection/widget/stability_indicator.dart';
import 'package:hiddify/features/home/widget/account_status_bar.dart';
import 'package:hiddify/features/home/widget/connection_button.dart';
import 'package:hiddify/features/home/widget/line_bar.dart';
import 'package:hiddify/features/panel_auth/notifier/guest_bootstrap.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/features/proxy/active/auto_line_fixer.dart';
import 'package:hiddify/features/proxy/model/node_display.dart';
import 'package:hiddify/features/stats/notifier/stats_notifier.dart';
import 'package:hiddify/features/support/widget/support_failure_link.dart';
import 'package:hiddify/gen/assets.gen.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hiddify/utils/number_formatters.dart';
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
      // 装好第一次打开：在后台静默开游客号（开不出来首页照常能逛）。
      Future(() => ref.read(guestBootstrapProvider.notifier).ensure());
      // OneRay: 启动后清掉残留更新包 + 静默检查更新一次
      ApkInstaller.cleanupApks();
      Future.delayed(const Duration(seconds: 3), () {
        if (context.mounted) ref.read(appUpdateNotifierProvider.notifier).check();
      });
      return null;
    }, const []);

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
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        ConnectionButton(),
                        _SpeedLine(),
                        StabilityIndicator(),
                        SupportFailureLink(),
                      ],
                    ),
                  ),
                  LineBar(),
                  AccountStatusBar(),
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

import 'dart:io';
import 'dart:math' as math;

import 'package:dartx/dartx.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/core/model/remote_site_config.dart';
import 'package:hiddify/core/model/sites_catalog.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/core/router/go_router/refresh_listenable.dart';
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
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/features/proxy/active/auto_line_fixer.dart';
import 'package:hiddify/features/proxy/line/line_picker.dart';
import 'package:hiddify/features/proxy/model/node_display.dart';
import 'package:hiddify/features/proxy/model/node_flag.dart';
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

    final telegramGroup = useState<Uri?>(RemoteSiteConfig.telegramGroupUri);
    final customUrl = useState<String?>(RemoteSiteConfig.customUrl);
    final customOn = useState(RemoteSiteConfig.customEnabled);
    useEffect(() {
      RemoteSiteConfig.ensureLoaded().then((_) {
        if (!context.mounted) return;
        telegramGroup.value = RemoteSiteConfig.telegramGroupUri;
        customUrl.value = RemoteSiteConfig.customUrl;
        customOn.value = RemoteSiteConfig.customEnabled;
      });
      return null;
    }, const []);

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

    // 开号时不再自动弹「记下这两样」。密码仍存在本地，从账号页「防丢」打开。

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
          // 专属定制要开关和网址都有才出现。360 宽放不下时，交流群收成图标，文字留给专属定制。
          if (customOn.value && (customUrl.value ?? '').isNotEmpty)
            TextButton(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                visualDensity: VisualDensity.compact,
              ),
              onPressed: () => UriUtils.tryLaunch(Uri.parse(customUrl.value!)),
              child: const Text('专属定制'),
            ),
          // 有交流群链接时这里是「交流群 ↗」；没有就仍是「官网 ↗」。官网入口挪到「我的」。
          _HomeLink(
            group: telegramGroup.value,
            iconOnly: customOn.value &&
                (customUrl.value ?? '').isNotEmpty &&
                telegramGroup.value != null &&
                MediaQuery.sizeOf(context).width < 400,
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
                        _SitesBlock(),
                        _GoogleTestButton(),
                        ConnectIssueCard(),
                        SupportFailureLink(),
                      ],
                    ),
                  ),
                  _RouteRulesEntry(),
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

/// 连上之后给新用户一个「下一步」：点一下用默认浏览器打开谷歌搜索，看到结果就知道网通了。
/// 搜「今天天气」是因为谷歌会直接出天气卡片，最直观。没连上时什么都不画。
/// 顶栏右边那个链接。没群时是官网；有群时是交流群。窄屏且旁边有「专属定制」时只留图标。
class _HomeLink extends StatelessWidget {
  const _HomeLink({required this.group, required this.iconOnly});

  final Uri? group;
  final bool iconOnly;

  @override
  Widget build(BuildContext context) {
    if (iconOnly && group != null) {
      return IconButton(
        tooltip: '交流群',
        visualDensity: VisualDensity.compact,
        onPressed: () => UriUtils.tryLaunch(group!),
        icon: const Icon(Icons.forum_outlined),
      );
    }
    return TextButton(
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        visualDensity: VisualDensity.compact,
      ),
      onPressed: () => UriUtils.tryLaunch(group ?? Uri.parse(Constants.websiteUrl)),
      child: Text(group != null ? '交流群 ↗' : '官网 ↗'),
    );
  }
}

/// 连上并且网通了才出现：香港等地区一行提示，下面是常用网站。服务器没给就不占高度。
class _SitesBlock extends HookConsumerWidget {
  const _SitesBlock();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connected = ref.watch(connectionNotifierProvider).valueOrNull is Connected;
    final health = ref.watch(stabilityProvider);
    final active = ref.watch(activeProxyNotifierProvider).valueOrNull?.tagDisplay ?? '';
    final stored = ref.watch(Preferences.lastNodeName);
    final show = connected && health.confirmed && !health.outage;
    final links = useState<List<SiteLink>>(SitesCatalog.quick);
    final configTick = useState(0);

    useEffect(() {
      if (!show) return null;
      () async {
        await RemoteSiteConfig.ensureLoaded();
        await SitesCatalog.ensureLoaded();
        if (!context.mounted) return;
        links.value = List<SiteLink>.of(SitesCatalog.quick);
        configTick.value++;
      }();
      return null;
    }, [show]);

    if (!show) return const SizedBox.shrink();

    final lineName = active.isNotEmpty ? splitNodeName(active).name : stored;
    final code = countryCodeFromLineName(lineName);
    // 读一次，配置拉回来后 useState 变化会重建，提示和名单才能出现。
    configTick.value;
    final tip = RemoteSiteConfig.aiTipText;
    final showTip = tip != null && code != null && RemoteSiteConfig.aiTipRegions.contains(code);

    if (!showTip && links.value.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        children: [
          if (showTip)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 4, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      tip,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                    onPressed: () => showLinePicker(context, ref),
                    child: const Text('换线路'),
                  ),
                ],
              ),
            ),
          if (links.value.isNotEmpty) _QuickSites(links: links.value),
        ],
      ),
    );
  }
}

class _QuickSites extends StatelessWidget {
  const _QuickSites({required this.links});

  final List<SiteLink> links;

  double _textWidth(String text, double fontSize) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: TextStyle(fontSize: fontSize)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    return math.max(36, painter.width);
  }

  double _rowWidth(int count, double fontSize, double gap) {
    final n = math.min(count, links.length);
    var width = _textWidth('更多', fontSize);
    for (var i = 0; i < n; i++) {
      width += _textWidth(links[i].name, fontSize);
    }
    return width + gap * n;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        var count = math.min(5, links.length);
        var fontSize = 11.0;
        var gap = 8.0;
        if (_rowWidth(count, fontSize, gap) > maxWidth) fontSize = 10;
        if (_rowWidth(count, fontSize, gap) > maxWidth && count > 4) count = math.min(4, links.length);
        if (_rowWidth(count, fontSize, gap) > maxWidth) gap = 4;
        final shown = links.take(count).toList();
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < shown.length; i++) ...[
                  if (i > 0) SizedBox(width: gap),
                  _SiteButton(link: shown[i], fontSize: fontSize),
                ],
                SizedBox(width: gap),
                _MoreSitesButton(fontSize: fontSize),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SiteButton extends StatelessWidget {
  const _SiteButton({required this.link, required this.fontSize});

  final SiteLink link;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final path = link.iconPath;
    return InkWell(
      onTap: () => UriUtils.tryLaunch(Uri.parse(link.url)),
      customBorder: const CircleBorder(),
      child: SizedBox(
        width: math.max(36, _labelWidth(link.name)),
        child: Column(
          children: [
            if (path != null && File(path).existsSync())
              ClipOval(
                child: Image.file(File(path), width: 36, height: 36, fit: BoxFit.cover),
              )
            else
              Container(
                    width: 36,
                    height: 36,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      link.name.isEmpty ? '?' : link.name.characters.first,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                  ),
            const SizedBox(height: 2),
            Text(
              link.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: fontSize, color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  double _labelWidth(String text) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: TextStyle(fontSize: fontSize)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    return painter.width;
  }
}

class _MoreSitesButton extends StatelessWidget {
  const _MoreSitesButton({required this.fontSize});

  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final url = RemoteSiteConfig.sitesUrl;
    return InkWell(
      onTap: url == null ? null : () => UriUtils.tryLaunch(Uri.parse(url)),
      customBorder: const CircleBorder(),
      child: Column(
        children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              shape: BoxShape.circle,
            ),
            child: const Text('⋯', style: TextStyle(fontSize: 16)),
          ),
          const SizedBox(height: 2),
          Text(
            '更多',
            style: TextStyle(fontSize: fontSize, color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

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

import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
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
import 'package:hiddify/core/theme/oneray_tokens.dart';
import 'package:hiddify/features/app_update/data/apk_installer.dart';
import 'package:hiddify/features/app_update/notifier/app_update_notifier.dart';
import 'package:hiddify/features/app_update/notifier/app_update_state.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/connection/notifier/route_check_notifier.dart';
import 'package:hiddify/features/connection/notifier/stability_notifier.dart';
import 'package:hiddify/features/connection/widget/stability_indicator.dart';
import 'package:hiddify/features/home/widget/account_chip.dart';
import 'package:hiddify/features/home/widget/connect_issue_card.dart';
import 'package:hiddify/features/home/widget/connection_button.dart';
import 'package:hiddify/features/notice/notice_sheet.dart';
import 'package:hiddify/features/panel_auth/data/panel_api.dart';
import 'package:hiddify/features/panel_auth/data/tg_gift_link.dart';
import 'package:hiddify/features/panel_auth/notifier/guest_bootstrap.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/features/proxy/active/auto_line_fixer.dart';
import 'package:hiddify/features/proxy/line/line_picker.dart';
import 'package:hiddify/features/proxy/model/node_display.dart';
import 'package:hiddify/features/proxy/model/node_flag.dart';
import 'package:hiddify/features/purchase/notifier/purchase_notifier.dart';
import 'package:hiddify/features/stats/notifier/stats_notifier.dart';
import 'package:hiddify/features/support/widget/support_failure_link.dart';
import 'package:hiddify/gen/assets.gen.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hiddify/utils/number_formatters.dart';
import 'package:hiddify/utils/uri_utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    useEffect(() {
      RemoteSiteConfig.ensureLoaded().then((_) {
        if (!context.mounted) return;
        telegramGroup.value = RemoteSiteConfig.telegramGroupUri;
      });
      return null;
    }, const []);

    // 关注 TG 频道送 1 天：能领时顶栏「TG 频道」变成领取入口。从 Telegram 回来时再问一次，
    // 领完了入口变回普通频道链接，到期时间也顺手刷新。
    final loggedIn = ref.watch(panelAuthProvider.select((s) => s.loggedIn));
    final gift = useState<Map<String, dynamic>?>(null);
    Future<void> loadGift() async {
      final g = await ref.read(panelAuthProvider.notifier).tgGift();
      if (context.mounted) gift.value = g;
    }

    useEffect(() {
      if (loggedIn) loadGift();
      return null;
    }, [loggedIn]);
    // 点了「客服回复了」系统通知进来：直接打开客服页。
    final fromSupport = useValueListenable(supportFromLink);
    useEffect(() {
      if (!fromSupport) return null;
      supportFromLink.value = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) context.pushNamed('supportChat');
      });
      return null;
    }, [fromSupport]);
    // 从 TG 机器人点「打开光速雷达，一键领取」进来：问一次能不能领，能领就直接拉起 Telegram。
    final fromLink = useValueListenable(giftFromLink);
    useEffect(() {
      if (!fromLink || !loggedIn) return null;
      giftFromLink.value = false;
      Future(() async {
        final g = await ref.read(panelAuthProvider.notifier).tgGift();
        if (!context.mounted) return;
        gift.value = g;
        if (g?['state'] == 'open') {
          await openTgGift(g!);
        } else if (g?['state'] == 'claimed') {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('这个账号已经领过了')));
        }
      });
      return null;
    }, [fromLink, loggedIn]);
    useOnAppLifecycleStateChange((_, state) {
      if (state != AppLifecycleState.resumed || gift.value?['state'] != 'open') return;
      loadGift();
      ref.read(panelAuthProvider.notifier).fetchAccount();
    });

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
        await ref
            .read(dialogNotifierProvider.notifier)
            .showNewVersion(
              currentVersion: appInfo.presentVersion,
              newVersion: versionInfo,
              canIgnore: !versionInfo.mandatory,
            );
      }
    });

    final tk = OneRayTokens.of(context);
    // 活动卡：× 只是这次收起；领到了停 8 秒自己收起（B 夜航 §3.7）。
    final activityHidden = useState(false);
    final giftPending = useState(false);
    final giftClaimed = useState(false);
    ref.listen<bool>(Preferences.panelLoggedIn, (_, _) => activityHidden.value = false);
    useEffect(() {
      final state = gift.value?['state'];
      if (giftPending.value && state == 'claimed') {
        giftPending.value = false;
        giftClaimed.value = true;
        final timer = Timer(const Duration(seconds: 8), () {
          if (context.mounted) activityHidden.value = true;
        });
        return timer.cancel;
      }
      return null;
    }, [gift.value]);
    final giftOpen = gift.value?['state'] == 'open';

    return Scaffold(
      backgroundColor: tk.bg,
      appBar: AppBar(
        backgroundColor: tk.bg,
        titleSpacing: 20,
        // 标志：透明底小标志，深色白图形、浅色黑图形，光点都是珊瑚色（跟 Windows 同一个）。
        title: Row(
          children: [
            (theme.brightness == Brightness.dark ? Assets.images.markOnDarkSmall : Assets.images.markOnLightSmall)
                .svg(width: 28, height: 28),
            const Gap(8),
            Text(t.common.appTitle, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          ],
        ),
        actions: [const AccountChip(), if (loggedIn) const NoticeBell(), const Gap(8)],
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const NoticeStrip(),
                Expanded(
                  child: ConnectionButton(
                    statusExtra: const [_SpeedLine(), StabilityIndicator(), _HomeNote()],
                    middle: [
                      const ConnectIssueCard(),
                      const SupportFailureLink(),
                      if (loggedIn && !activityHidden.value && (giftOpen || giftClaimed.value))
                        _ActivityCard(
                          phase: giftClaimed.value ? 'claimed' : (giftPending.value ? 'pending' : 'open'),
                          onClaim: () async {
                            giftPending.value = true;
                            await openTgGift(gift.value!);
                          },
                          onDismiss: () => activityHidden.value = true,
                        ),
                      const _SitesBlock(),
                    ],
                  ),
                ),
                _HomeLinks(group: telegramGroup.value, gift: giftOpen ? gift.value : null),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 连上之后状态下面那行实时速率。
///
/// 故意**不显示延迟毫秒数**：用户会拿它跟别家比，而别家标的常常是到中转入口、不是到
/// 落地节点的，真数字比不过假数字。速率是正向的 —— 数字大就是快，看着高兴。
class _SpeedLine extends ConsumerWidget {
  const _SpeedLine();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tk = OneRayTokens.of(context);
    final connected = ref.watch(connectionNotifierProvider).valueOrNull is Connected;
    if (!connected) return const SizedBox.shrink();

    final stats = ref.watch(statsNotifierProvider).valueOrNull ?? SystemInfo.create();
    final num = TextStyle(fontFamily: OneRayTokens.numberFont, fontSize: 15, fontWeight: FontWeight.w600, color: tk.text);
    final sub = TextStyle(fontSize: 12, color: tk.sub);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: '↓ ', style: sub),
            TextSpan(text: stats.downlink.toInt().speed(), style: num),
            TextSpan(text: '  ·  ↑ ', style: sub),
            TextSpan(text: stats.uplink.toInt().speed(), style: num),
          ],
        ),
      ),
    );
  }
}

/// 状态下面一小块提示（限速、精品体验结束），浅底不抢主位。
class _HomeNote extends ConsumerWidget {
  const _HomeNote();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (text, canUpgrade) = homeAccountNote(ref);
    if (text.isEmpty) return const SizedBox.shrink();
    final tk = OneRayTokens.of(context);
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: tk.card, borderRadius: BorderRadius.circular(12)),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: text),
            if (canUpgrade)
              TextSpan(
                text: '  升级 ›',
                style: TextStyle(color: tk.acc),
                recognizer: TapGestureRecognizer()
                  ..onTap = () {
                    ref.read(purchasePreferTierProvider.notifier).state = 'pro';
                    context.pushNamed('purchase');
                  },
              ),
          ],
        ),
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 12, height: 1.5, color: tk.sub),
      ),
    );
  }
}

/// 活动卡（B 夜航 §3.7）：活动是「让用户做一件事拿好处」，跟公告分开放，做完或过期才消失。
/// phase：open 能领 / pending 点过领取、等确认 / claimed 刚领到。× 只是这次收起。
class _ActivityCard extends StatelessWidget {
  const _ActivityCard({required this.phase, required this.onClaim, required this.onDismiss});

  final String phase;
  final VoidCallback onClaim;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final tk = OneRayTokens.of(context);
    final claimed = phase == 'claimed';
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
      decoration: BoxDecoration(color: tk.accSoft, borderRadius: BorderRadius.circular(16)),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: tk.acc, shape: BoxShape.circle),
            child: Icon(claimed ? Icons.check_rounded : Icons.card_giftcard_rounded, size: 20, color: tk.accInk),
          ),
          const Gap(12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  claimed ? '领到了，多送你 1 天' : '关注 TG 频道送 1 天',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: tk.text),
                ),
                Text(
                  claimed
                      ? '到期时间已经往后顺延'
                      : phase == 'pending'
                      ? '在 Telegram 点「加入」后回来，会自动确认'
                      : '关注后点「领取」，自动到账',
                  style: TextStyle(fontSize: 12, color: tk.sub),
                ),
              ],
            ),
          ),
          if (!claimed)
            SizedBox(
              height: 36,
              child: phase == 'open'
                  // 卡片里的次要动作用淡底强调色，不跟下面的主按钮抢（Windows PrimaryAction tonal 同一套）。
                  ? FilledButton(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(64, 36),
                        backgroundColor: tk.acc.withValues(alpha: 0.12),
                        foregroundColor: tk.acc,
                      ),
                      onPressed: onClaim,
                      child: const Text('领取', style: TextStyle(fontSize: 13)),
                    )
                  : ElevatedButton(
                      style: ElevatedButton.styleFrom(minimumSize: const Size(64, 36)),
                      onPressed: onClaim,
                      child: const Text('再打开', style: TextStyle(fontSize: 13)),
                    ),
            ),
          IconButton(
            tooltip: '收起这个活动',
            iconSize: 16,
            color: tk.sub,
            onPressed: onDismiss,
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }
}

/// 连上并且网通了才出现：香港等地区一行提示，下面是常用网站（Google 排第一、带描边：
/// 点一下打得开就说明通了）。服务器没给名单时至少放一个 Google。
class _SitesBlock extends HookConsumerWidget {
  const _SitesBlock();

  static const _google = 'https://www.google.com/search?q=%E4%BB%8A%E5%A4%A9%E5%A4%A9%E6%B0%94';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tk = OneRayTokens.of(context);
    final connected = ref.watch(connectionNotifierProvider).valueOrNull is Connected;
    final health = ref.watch(stabilityProvider);
    final active = ref.watch(activeProxyNotifierProvider).valueOrNull?.tagDisplay ?? '';
    final stored = ref.watch(Preferences.lastNodeName);
    final show = connected && health.confirmed;
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
    final sites = links.value.isEmpty
        ? const [SiteLink(id: '', name: 'Google', url: _google)]
        : links.value.take(4).toList();
    final moreUrl = RemoteSiteConfig.sitesUrl;

    Widget chip({required String name, required Widget icon, required VoidCallback? onTap, bool test = false}) {
      return Expanded(
        child: Material(
          color: tk.card,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: test ? BorderSide(color: tk.acc, width: 1.5) : BorderSide.none,
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: SizedBox(
              height: 60,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  icon,
                  const SizedBox(height: 4),
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: tk.text),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    Widget letter(String name) => Container(
      width: 24,
      height: 24,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: tk.panel, shape: BoxShape.circle),
      child: Text(
        name.isEmpty ? '?' : name.characters.first,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: tk.text),
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showTip)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(tip, style: TextStyle(fontSize: 12, color: tk.sub)),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                    onPressed: () => showLinePicker(context, ref),
                    child: const Text('换线路'),
                  ),
                ],
              ),
            ),
          Text('先点 Google，打得开就说明连通了', style: TextStyle(fontSize: 12, color: tk.sub)),
          const SizedBox(height: 6),
          Row(
            children: [
              for (var i = 0; i < sites.length; i++) ...[
                if (i > 0) const SizedBox(width: 6),
                chip(
                  name: sites[i].name,
                  test: i == 0,
                  icon: sites[i].iconPath != null && File(sites[i].iconPath!).existsSync()
                      ? ClipOval(child: Image.file(File(sites[i].iconPath!), width: 24, height: 24, fit: BoxFit.cover))
                      : letter(sites[i].name),
                  onTap: () {
                    UriUtils.tryLaunch(Uri.parse(sites[i].url));
                    if (sites[i].id.isNotEmpty) PanelApi().reportSiteClick(sites[i].id);
                  },
                ),
              ],
              if (moreUrl != null) ...[
                const SizedBox(width: 6),
                chip(
                  name: '更多',
                  icon: Icon(Icons.more_horiz_rounded, size: 22, color: tk.sub),
                  onTap: () => UriUtils.tryLaunch(Uri.parse(moreUrl)),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// 底部一行链接：智能分流 / TG 频道 / 定制线路（后台下发）。跟 Windows 底栏同一行。
/// 智能分流实测出异常时带珊瑚红小点；TG 频道没点过（或能领「关注送 1 天」）时带强调色小点。
class _HomeLinks extends HookConsumerWidget {
  const _HomeLinks({required this.group, this.gift});

  final Uri? group;

  /// 关注频道送时长还能领时不为空（服务端 gsl_tg/gift 的 data）。
  final Map<String, dynamic>? gift;

  static const _visitedKey = 'oneray.tg.visited';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tk = OneRayTokens.of(context);
    final warn = ref.watch(routeCheckProvider.select((s) => s.warning.isNotEmpty));
    final visited = useState(true);
    final customUrl = useState<String?>(null);
    useEffect(() {
      SharedPreferences.getInstance().then((prefs) {
        if (context.mounted) visited.value = prefs.getBool(_visitedKey) ?? false;
      });
      RemoteSiteConfig.ensureLoaded().then((_) {
        if (!context.mounted) return;
        final url = RemoteSiteConfig.customUrl;
        customUrl.value = RemoteSiteConfig.customEnabled && url != null && url.isNotEmpty ? url : null;
      });
      return null;
    }, const []);

    Future<void> openTg() async {
      final g = gift;
      if (g != null) {
        await openTgGift(g);
        return;
      }
      final link = group;
      await UriUtils.tryLaunch(link ?? Uri.parse(Constants.websiteUrl));
      if (link == null || visited.value) return;
      visited.value = true;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_visitedKey, true);
    }

    Widget link(String text, VoidCallback onTap, {Color? dot}) => TextButton(
      style: TextButton.styleFrom(
        foregroundColor: tk.sub,
        minimumSize: const Size(48, 44),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        visualDensity: VisualDensity.compact,
        textStyle: const TextStyle(fontSize: 12),
      ),
      onPressed: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text),
          if (dot != null) ...[
            const SizedBox(width: 4),
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
          ],
        ],
      ),
    );
    Widget sep() => Container(width: 1, height: 12, color: tk.ring);

    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          link('智能分流', () => context.pushNamed('routeRules'), dot: warn ? tk.fault : null),
          sep(),
          link(
            group != null ? 'TG 频道' : '官网',
            openTg,
            dot: gift != null || (group != null && !visited.value) ? tk.acc : null,
          ),
          if (customUrl.value != null) ...[sep(), link('定制线路', () => UriUtils.tryLaunch(Uri.parse(customUrl.value!)))],
        ],
      ),
    );
  }
}

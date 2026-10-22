import 'dart:async';

import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/model/remote_site_config.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/core/theme/oneray_tokens.dart';
import 'package:hiddify/features/common/guide_card.dart';
import 'package:hiddify/features/common/line_icon.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/home/widget/connect_progress.dart';
import 'package:hiddify/features/panel_auth/data/panel_api.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hiddify/features/proxy/line/line_isp.dart';
import 'package:hiddify/features/proxy/line/line_source.dart';
import 'package:hiddify/features/proxy/line/line_speed.dart';
import 'package:hiddify/features/proxy/line/line_tier.dart';
import 'package:hiddify/features/proxy/line/region_vote.dart';
import 'package:hiddify/features/proxy/model/node_display.dart';
import 'package:hiddify/features/proxy/model/node_flag.dart';
import 'package:hiddify/features/purchase/notifier/purchase_notifier.dart';
import 'package:hiddify/utils/uri_utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

export 'package:hiddify/features/proxy/line/line_source.dart' show LineOption, activeProfileLinesProvider;

/// 线路页（10-18 改版，VPN 仓库 docs/计划/线路列表改版.md；Windows `RoutePalette.qml` 同一套规则）。
///
/// 功能不变，只改摆法：
///  - 正在用的那条固定在最上面（精品、标准都一样），下面的列表里不再重复；
///  - 一行：国旗 +「国家 · 城市」，第二行说明 + 测速结果；右边最多一个标记
///    （使用中 > 维修中 > 推荐 > 精品/标准 > 适合 X）；
///  - 宽带只看他自己那家：一组全适合就都不标，只有一部分适合才给那几条挂「适合 X」；
///  - 标准线路收成一张卡，点进去单独一页；精品锁着时是一张带锁的卡；最后两张卡（投票 / 定制）。
///  - 面板高度跟着内容走，最高 90%；底部让开手势条（SafeArea）；宽屏最宽 560。
///
/// 断开也能看、没账号也能看、到期也能看 —— 这三种情况下显示的是公开清单（只有名字），
/// 点具体某条时才弹引导（去买套餐 / 登录）。故意不做「自动选最快」和延迟数字（推荐哪条由服务端负载均衡决定）。
Future<void> showLinePicker(BuildContext context, WidgetRef ref) async {
  // 灰字用得到配置，但抽屉必须马上弹。300 毫秒内回来就带上，回不来先开抽屉。
  await RemoteSiteConfig.ensureLoaded().timeout(const Duration(milliseconds: 300), onTimeout: () {});
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: OneRayTokens.of(context).sheet,
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (context) => const _LinePickerSheet(),
  );
}

class _LinePickerSheet extends ConsumerStatefulWidget {
  const _LinePickerSheet();

  @override
  ConsumerState<_LinePickerSheet> createState() => _LinePickerSheetState();
}

class _LinePickerSheetState extends ConsumerState<_LinePickerSheet> {
  final _search = TextEditingController();
  final _currentKey = GlobalKey();
  bool _stdPage = false;
  bool _revealQueued = false;

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
    Future.microtask(() {
      if (mounted) ref.read(regionVoteProvider.notifier).load();
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _openStdPage(bool open) {
    setState(() {
      _stdPage = open;
      _revealQueued = false;
    });
  }

  /// 标准线路那页里自己那条可能在屏幕外：滚到它（主页那页正在用的固定在最上面，不用滚）。
  void _revealCurrent() {
    if (_revealQueued) return;
    _revealQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _currentKey.currentContext;
      if (ctx != null) Scrollable.ensureVisible(ctx, alignment: 0.4, duration: const Duration(milliseconds: 220));
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens = OneRayTokens.of(context);
    final set = ref.watch(lineSetProvider);
    // 正在用 / 上次连上的那条（连接成功时首页会写进来）。
    final currentName = ref.watch(Preferences.lastNodeName);
    // 用户自己在这页选过的那条。选过了就不用再给他看「推荐」。
    final pickedName = ref.watch(Preferences.preferredLineName);
    final connected = ref.watch(connectionNotifierProvider).valueOrNull?.isConnected ?? false;
    final region = ref.watch(regionVoteProvider);
    final value = set.valueOrNull;
    final isp = ref.watch(panelAuthProvider.select((s) => s.account?.isp ?? ''));
    final account = ref.watch(panelAuthProvider).account;
    final subOptions = value?.lines ?? const <LineOption>[];
    final firstName = subOptions.isEmpty ? '' : subOptions.first.name;
    // 没账号 / 到期：这是只能看的公开清单。
    final preview = value?.locked ?? false;
    final tiers = ref.watch(lineTierProvider);
    final speed = ref.watch(lineSpeedProvider);
    final downLines = account?.downLines ?? const <String>{};
    final busyLines = account?.busyLines ?? const <String>{};
    // 同国家里适合他宽带的在前、繁忙和维修中的最后（两端统一）。
    final lastLines = preview ? const <String>{} : {...busyLines, ...downLines};
    List<LineOption> orderLines(List<LineOption> l) => ispFitFirst(l, isp, last: lastLines);
    final tiered = subOptions.isNotEmpty && tiers.proLines.isNotEmpty;
    final proLocked = tiers.trial != 'pro' && tiers.trial != 'active';

    // 全部线路：订阅里的 + 订阅外补进来的精品线路（标准版用户的订阅里没有精品线路，名字从 lineTier 来）。
    final all = <LineOption>[...subOptions];
    if (tiered) {
      final seen = subOptions.map((o) => o.name).toSet();
      for (final line in tiers.proLines) {
        final split = splitNodeName(line.name);
        if (split.name.isEmpty || seen.contains(split.name)) continue;
        seen.add(split.name);
        all.add(split);
      }
    }
    bool isPro(LineOption o) => tiered && tiers.isProName(o.name);
    LineOption? current;
    if (!preview && currentName.isNotEmpty) {
      for (final o in all) {
        if (o.name == currentName) current = o;
      }
    }

    _LineRow row(
      LineOption o, {
      bool isCurrent = false,
      bool showKind = false,
      String tierTag = '',
      Key? key,
    }) {
      final down = !preview && downLines.contains(o.name);
      final busy = !preview && !down && busyLines.contains(o.name);
      final grade = down ? null : speed.grades[o.name];
      final code = countryCodeFromLineName(o.name);
      final tag = RemoteSiteConfig.aiTipTag;
      return _LineRow(
        key: key,
        option: o,
        tokens: tokens,
        current: isCurrent,
        connected: connected,
        pro: isPro(o),
        showKind: showKind,
        isp: isp,
        tierTag: tierTag,
        recommended: !preview && pickedName.isEmpty && o.name == firstName,
        down: down,
        busy: busy,
        grade: grade,
        best: !down && speed.bestName == o.name && grade != null && grade.level <= 2,
        aiTip: tag != null && code != null && RemoteSiteConfig.aiTipRegions.contains(code) ? tag : '',
        onTap: () {
          if (preview) {
            _promptUnlock(context, ref);
          } else if (isPro(o) && proLocked) {
            _lockedTap(context);
          } else {
            _pick(context, ref, o);
          }
        },
      );
    }

    final query = _search.text.trim();
    final children = <Widget>[];
    if (set.isLoading && subOptions.isEmpty) {
      children.add(const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())));
    } else if (subOptions.isEmpty) {
      children.add(const Padding(
        padding: EdgeInsets.all(20),
        child: Text('暂时读不到线路，检查一下网络，或在「我的」页联系客服。'),
      ));
    } else if (query.isNotEmpty) {
      // ===== 搜索：精品在前，每行右边写「精品 / 标准」=====
      final hits = all.where((o) => o.name.toLowerCase().contains(query.toLowerCase())).toList();
      final ordered = [...orderLines(hits.where(isPro).toList()), ...orderLines(hits.where((o) => !isPro(o)).toList())];
      for (final o in ordered) {
        children.add(row(o, isCurrent: current != null && o.name == current.name, tierTag: tiered ? (isPro(o) ? '精品' : '标准') : ''));
      }
      if (ordered.isEmpty) {
        children.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 32),
          child: Column(
            children: [
              Text('没有找到这条方向', style: TextStyle(fontSize: 14, color: tokens.sub)),
              const Gap(4),
              Text('换一个城市或国家试试', style: TextStyle(fontSize: 12, color: tokens.sub)),
            ],
          ),
        ));
      }
      if (region.enabled && !preview) {
        children.add(Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Material(
            color: tokens.panel,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => _wantRegion(context),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text.rich(
                  TextSpan(
                    text: '没有你想去的城市？',
                    style: TextStyle(fontSize: 14, color: tokens.sub),
                    children: [
                      TextSpan(text: '投票开通 ›', style: TextStyle(color: tokens.acc, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ));
      }
    } else if (_stdPage) {
      // ===== 标准线路那一页 =====
      final std = orderLines(all.where((o) => !isPro(o)).toList());
      // 10-21 运营定：只写对用户有用的一句，不写「晚高峰可能变慢」「用 AI 选精品」这类说明
      if (isp.isNotEmpty && std.any((o) => lineFitsIsp(o, isp))) {
        children.add(Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Text(
            '标着「适合$isp」的，你用起来更快。',
            style: TextStyle(fontSize: 12, height: 1.4, color: tokens.sub),
          ),
        ));
      }
      for (final o in std) {
        final cur = current != null && o.name == current.name;
        children.add(row(o, isCurrent: cur, key: cur ? _currentKey : null));
      }
      if (current != null && !isPro(current)) _revealCurrent();
      final proCount = all.where(isPro).length;
      if (proCount > 0) {
        children.add(Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Material(
            color: tokens.accSoft,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => _openStdPage(false),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('精品线路 · $proCount 条',
                              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: tokens.acc)),
                          const Gap(2),
                          Text(proLocked ? '晚高峰也不卡 · 精品版才能用' : '晚高峰也不卡',
                              style: TextStyle(fontSize: 12, color: tokens.sub)),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right_rounded, color: tokens.acc),
                  ],
                ),
              ),
            ),
          ),
        ));
      }
    } else {
      // ===== 主页：正在用 / 精品 / 标准卡 =====
      if (current != null) {
        children.add(_GroupLabel(connected ? '正在用' : '上次用的', tokens));
        children.add(row(current, isCurrent: true, showKind: tiered));
        children.add(const Gap(10));
      }
      final others = all.where((o) => current == null || o.name != current.name).toList();
      if (!tiered) {
        for (final o in orderLines(others)) {
          children.add(row(o));
        }
      } else {
        final proAll = all.where(isPro).toList();
        final proOthers = orderLines(others.where(isPro).toList());
        if (proAll.isNotEmpty && !proLocked) {
          children.add(_ProHeader(
            tokens: tokens,
            onUpgrade: tiers.trial == 'active' ? () => _upgrade(context, 'pro') : null,
            hint: tiers.trial == 'active'
                ? '体验中 · 还剩 ${(tiers.seconds / 60).ceil().clamp(1, 9999)} 分钟'
                : '晚高峰也不卡',
            hintAcc: tiers.trial == 'active',
            account: account,
          ));
          for (final o in proOthers) {
            children.add(row(o));
          }
        } else if (proAll.isNotEmpty) {
          children.add(_LockedProCard(
            tokens: tokens,
            lines: proOthers,
            countries: _countries(proAll),
            onUpgrade: () => _upgrade(context, 'pro'),
            onLineTap: () => _lockedTap(context),
          ));
        }
        final stdAll = all.where((o) => !isPro(o)).toList();
        if (stdAll.isNotEmpty) {
          final curRegion = current != null && !isPro(current) ? lineCountry(current.name) : '';
          children.add(Padding(
            padding: const EdgeInsets.only(top: 14),
            child: _StdCard(
              tokens: tokens,
              count: stdAll.length,
              regions: _countries(stdAll),
              currentRegion: curRegion,
              onTap: () => _openStdPage(true),
            ),
          ));
        }
      }
      // 最后两张卡：投票 / 定制。跟着列表走，不钉在屏幕底（面板高度跟内容走，不留空白）。
      final custom = _customLineUrl();
      final tiles = <Widget>[
        if (region.enabled && !preview)
          _FootTile(
            tokens: tokens,
            title: '想要别的地区？',
            link: _regionLink(regionEntrySubtitle(region)),
            onTap: () => _wantRegion(context),
          ),
        if (custom != null)
          _FootTile(
            tokens: tokens,
            title: '定制专属线路',
            link: '了解一下 ›',
            onTap: () {
              Navigator.of(context).pop();
              UriUtils.tryLaunch(Uri.parse(custom));
            },
          ),
      ];
      if (tiles.isNotEmpty) {
        children.add(Padding(
          padding: const EdgeInsets.only(top: 14),
          child: Row(
            children: [
              for (final (i, t) in tiles.indexed) ...[
                if (i > 0) const Gap(10),
                Expanded(child: t),
              ],
            ],
          ),
        ));
      }
    }

    final hint = preview
        ? '登录或免费开始后才能连接。'
        : (isp.isNotEmpty && all.any((o) => lineFitsIsp(o, isp)) ? '你用的是中国$isp宽带，适合你的线路排在前面。' : '');

    final sheet = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(_stdPage ? 8 : 20, 0, 16, 10),
          child: Row(
            children: [
              if (_stdPage)
                IconButton(
                  tooltip: '返回',
                  onPressed: () => _openStdPage(false),
                  icon: Icon(Icons.chevron_left_rounded, color: tokens.sub),
                ),
              Text(_stdPage ? '标准线路' : '全部线路',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: tokens.text)),
              const Spacer(),
              if (!preview) _SpeedButton(tokens: tokens),
            ],
          ),
        ),
        if (!_stdPage) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 16, 8),
            child: TextField(
              controller: _search,
              textInputAction: TextInputAction.search,
              style: TextStyle(fontSize: 15, color: tokens.text),
              decoration: InputDecoration(
                hintText: '搜索国家或城市',
                hintStyle: TextStyle(color: tokens.dim),
                prefixIcon: Padding(
                  padding: const EdgeInsets.all(13),
                  child: LineIcon(LineIconName.search, color: tokens.sub, size: 16),
                ),
                suffixIcon: query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清空搜索',
                        onPressed: _search.clear,
                        icon: Icon(Icons.close_rounded, size: 18, color: tokens.sub),
                      ),
                filled: true,
                fillColor: tokens.panel,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: tokens.acc, width: 1.5),
                ),
              ),
            ),
          ),
          if (hint.isNotEmpty && query.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 16, 8),
              child: Text(hint, style: TextStyle(fontSize: 12, color: tokens.sub)),
            ),
        ],
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
            children: children,
          ),
        ),
      ],
    );
    // 最高到能看见那部分的 90%（键盘弹出时减掉键盘），内容少就矮（不留空白）；底部让开手势条，键盘弹出时跟着上抬。
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: keyboard),
      child: SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: (MediaQuery.sizeOf(context).height - keyboard) * 0.9),
          child: sheet,
        ),
      ),
    );
  }

  Future<void> _wantRegion(BuildContext context) async {
    final name = await showRegionSheet(context, ref);
    if (!mounted || name == null || name.isEmpty) return;
    // 投票页里点了已经开通的地区：回到这页，按这个国家搜出来（Windows focusCountry 同一做法）。
    setState(() => _stdPage = false);
    _search.text = name;
  }

  /// 点了锁着的精品线路：能领体验就先问要不要免费试（运营 10-20：只给想试的人），不能就去升级。
  void _lockedTap(BuildContext context) {
    if (ref.read(lineTierProvider).trial != 'can') {
      _upgrade(context, 'pro');
      return;
    }
    // 面板不关：领到了在面板上弹「体验已开始」，刷新完精品线路就在眼前（关了面板，这个 ref 也跟着没了）
    unawaited(offerProTrial(context, ref, 'tap_line', onUpgrade: () => _upgrade(context, 'pro')));
  }

  void _upgrade(BuildContext context, String tier) {
    ref.read(purchasePreferTierProvider.notifier).state = tier;
    Navigator.of(context).pop();
    context.pushNamed('purchase');
  }

  /// 选线路：记偏好 + 立即更新首页显示（跟主页雷达共用 chooseLine）。
  Future<void> _pick(BuildContext context, WidgetRef ref, LineOption o) async {
    if (await chooseLine(context, ref, o) && context.mounted) Navigator.of(context).pop();
  }

  /// 点了连不上的线路：按他缺什么给什么（有账号但到期 → 买套餐；没账号 → 登录 / 试用）。
  Future<void> _promptUnlock(BuildContext context, WidgetRef ref) async {
    Navigator.of(context).pop();
    await promptUnlockLines(ref);
  }
}

List<String> _countries(List<LineOption> lines) {
  final out = <String>[];
  for (final o in lines) {
    final c = lineCountry(o.name);
    if (!out.contains(c)) out.add(c);
  }
  return out;
}

/// 问他要不要先免费试精品线路（他自己表现出想用精品了才问：点了锁着的精品线路 / 购买页看了精品没买，运营 10-20）。
/// Windows 同款：HelpGuides.qml 的 proTrialOfferCard。领到了弹「体验已开始」那张。
/// [onUpgrade]：「直接升级精品版」做什么，不给就去购买页选好精品版（已经在购买页里时给一个只关卡片的）。
/// 返回的 Future 等整件事做完才结束（选了免费试 = 领完、提示或「体验已开始」那张也关了）：
/// 购买页等它结束才关自己，不然领的结果没处显示（领到了不弹卡、领不到不说原因）。
Future<void> offerProTrial(BuildContext context, WidgetRef ref, String why, {VoidCallback? onUpgrade}) async {
  final tiers = ref.read(lineTierProvider);
  final span = tiers.minutes == 60 ? '1 小时' : '${tiers.minutes} 分钟';
  final pick = await showDialog<String>(
    context: context,
    barrierColor: guideCanvasColor(context),
    builder: (ctx) => GuideCard(
      title: '先免费试$span精品线路？',
      body: '精品线路晚高峰也稳。免费试 $span，到时间自动结束。',
      actionText: '免费试 $span',
      onAction: () => Navigator.of(ctx).pop('try'),
      secondaryText: '直接升级精品版',
      onSecondary: () => Navigator.of(ctx).pop('upgrade'),
      links: [GuideLink('不用了', () => Navigator.of(ctx).pop())],
    ),
  );
  if (!context.mounted) return;
  if (pick == 'upgrade') {
    // 他选了升级：之后关购买页就别再问「先免费试」
    unawaited(ref.read(lineTierProvider.notifier).markShopAsked());
    if (onUpgrade != null) {
      onUpgrade();
      return;
    }
    ref.read(purchasePreferTierProvider.notifier).state = 'pro';
    unawaited(context.pushNamed('purchase'));
    return;
  }
  if (pick != 'try') return;
  final msg = await ref.read(lineTierProvider.notifier).claim(why);
  if (!context.mounted) return;
  if (msg != null) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    return;
  }
  final isp = ref.read(panelAuthProvider).account?.isp ?? '';
  await showProTrialGuide(context, ref.read(lineTierProvider), isp);
}

/// 体验结束卡：写明升级精品版要补多少（会员按标准版剩下的天数抵，送的天数接在精品后面，运营 10-20）。
/// 刚结束的、App 关着时结束的都弹一次，弹出就告诉服务器看过了。Windows 同款：HelpGuides.qml 的 proTrialEndCard。
Future<void> showProTrialEnd(BuildContext context, WidgetRef ref) {
  final tiers = ref.read(lineTierProvider);
  unawaited(ref.read(lineTierProvider.notifier).markEndSeen());
  String yuan(Object? fen) {
    final v = ((fen is num) ? fen : 0) / 100;
    return v == v.floorToDouble() ? '${v.toInt()}' : v.toStringAsFixed(2);
  }

  final o = tiers.upgrade;
  final price = o['price_fen'];
  var offer = '想一直用精品线路，可以升级精品版。';
  if (price is num && price > 0) {
    final credit = o['credit_fen'];
    offer = (credit is num && credit > 0)
        ? '升级精品版，本月只需补 ¥${yuan(o['pay_fen'])}（标准版剩下的天数已抵 ¥${yuan(credit)}）。'
        : '升级精品版，本月 ¥${yuan(o['pay_fen'])}。';
    final days = o['std_days_after'];
    if (days is num && days > 0) offer += '送你的 ${days.toInt()} 天标准版接在精品版后面，一天不少。';
  }
  return showDialog<void>(
    context: context,
    barrierColor: guideCanvasColor(context),
    builder: (ctx) => GuideCard(
      title: '精品线路体验结束了',
      body: tiers.endNote.isEmpty ? offer : '${tiers.endNote}\n$offer',
      actionText: '升级精品版',
      onAction: () {
        Navigator.of(ctx).pop();
        ref.read(purchasePreferTierProvider.notifier).state = 'pro';
        context.pushNamed('purchase');
      },
      secondaryText: '继续用标准版',
      onSecondary: () => Navigator.of(ctx).pop(),
    ),
  );
}

/// 领完精品线路体验弹的引导卡：精品线路在哪、点哪条、到时会怎样。
/// Windows 同款：qml/overlays/HelpGuides.qml 的 proTrialCard，两边一起改。
Future<void> showProTrialGuide(BuildContext context, LineTierState tiers, String isp) {
  final t = OneRayTokens.of(context);
  final span = tiers.minutes == 60 ? '1 小时' : '${tiers.minutes} 分钟';
  bool fits(ProLine l) => isp.isNotEmpty && (splitNodeName(l.name).isps?.contains(isp) ?? false);
  // 示意图里画的那条：适合他宽带的第一条精品线路，没有就第一条。
  final sample = tiers.proLines.where(fits).firstOrNull ?? tiers.proLines.firstOrNull;
  final sampleName = sample == null ? '' : splitNodeName(sample.name).name;
  final sampleFits = sample != null && fits(sample);
  final country = sampleName.isEmpty ? '' : lineCountry(sampleName);
  return showGuideCard(
    context,
    title: '精品线路体验已开始',
    body: '接下来 $span，精品线路都能用。',
    showContact: false,
    illustration: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: t.card,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: t.ring),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text.rich(TextSpan(children: [
                TextSpan(text: '精品线路', style: TextStyle(color: t.acc, fontSize: 13, fontWeight: FontWeight.w700)),
                TextSpan(text: '  体验中 · 还剩 ${tiers.minutes} 分钟', style: TextStyle(color: t.acc, fontSize: 11)),
              ])),
              if (sampleName.isNotEmpty) ...[
                const Gap(6),
                Container(
                  height: 40,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: t.accSoft,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: t.acc, width: 2),
                  ),
                  child: Row(
                    children: [
                      LineFlag(sampleName),
                      const Gap(8),
                      Expanded(
                        child: Text.rich(
                          TextSpan(children: [
                            TextSpan(text: country, style: TextStyle(fontWeight: FontWeight.w700, color: t.text)),
                            TextSpan(text: ' · ${_shortName(country, sampleName)}'),
                          ]),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13, color: t.text),
                        ),
                      ),
                      if (sampleFits)
                        Text('适合$isp', style: TextStyle(color: t.acc, fontSize: 11, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ],
              const Gap(6),
              // 下面还有别的精品线路（示意）
              Padding(
                padding: const EdgeInsets.only(left: 10),
                child: Container(
                  width: 120,
                  height: 8,
                  decoration: BoxDecoration(color: t.ring, borderRadius: BorderRadius.circular(4)),
                ),
              ),
            ],
          ),
        ),
        const Gap(12),
        GuideSteps([
          '点「知道了」，在「全部线路」里找到「精品线路」这一组',
          '点一条精品线路，光速雷达就换到这条线路连接${sampleFits ? '。标着「适合$isp」的更适合你的宽带' : ''}',
          '$span后体验结束，精品线路会断开。到时选一条标准线路，就能接着用',
        ]),
      ],
    ),
  );
}

/// 「日本 东京 03」→「东京 03」；「香港 03」去掉地区只剩编号，看不出是哪，留全名。
String _shortName(String country, String name) {
  final trimmed = name.trim();
  if (!trimmed.startsWith(country)) return trimmed;
  final rest = trimmed.substring(country.length).trim();
  return rest.isEmpty || RegExp(r'^\d+$').hasMatch(rest) ? trimmed : rest;
}

/// 投票卡第二行：没人投过写「投票开通 ›」，有进展写进展。
String _regionLink(String subtitle) {
  if (subtitle.isEmpty || subtitle.startsWith('会员投票')) return '投票开通 ›';
  return '$subtitle ›';
}

/// 选线路（线路列表、主页雷达共用）：记偏好 + 立即更新首页显示；已连接时由 autoLineFixer 立刻切过去。
/// 没连接时选了线路 = 要用这条：直接走一键连接（跟点连接按钮同一套，有进度条）。
/// 维修中的不切换，告诉他换一条（Windows 同一句）。返回 false = 没选上。
/// 记住选的这条线路（偏好 + 上次用的名字 / 说明）。选线路和精品体验结束换线都用它。
/// [read] 传 ref.read（界面里的 WidgetRef、notifier 里的 Ref 都行）。
Future<void> rememberLine(T Function<T>(ProviderListenable<T>) read, LineOption o) async {
  await read(Preferences.preferredLineName.notifier).update(o.name);
  await read(Preferences.lastNodeName.notifier).update(o.name);
  await read(Preferences.lastNodeDesc.notifier).update(o.desc);
}

Future<bool> chooseLine(BuildContext context, WidgetRef ref, LineOption o) async {
  if (ref.read(panelAuthProvider).account?.isLineDown(o.name) ?? false) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('「${o.name}」正在维修，暂时连不上。请换一条线路。')),
    );
    return false;
  }
  await rememberLine(ref.read, o);
  final now = ref.read(connectionNotifierProvider);
  if (now is AsyncError || now.valueOrNull is Disconnected) {
    ref.read(connectRequestProvider.notifier).state++;
  }
  return true;
}

/// 点了现在连不上的线路（没账号 / 到期 / 流量用完）：按他缺什么给什么。
Future<void> promptUnlockLines(WidgetRef ref) async {
  final account = ref.read(panelAuthProvider).account;
  if (account != null) {
    await ref.read(dialogNotifierProvider.notifier).showQuotaExhausted(account, force: true);
    return;
  }
  await ref.read(dialogNotifierProvider.notifier).showNeedAccount();
}

String? _customLineUrl() {
  final url = RemoteSiteConfig.customUrl;
  if (!RemoteSiteConfig.customEnabled || url == null || url.isEmpty) return null;
  return url;
}

class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.text, this.tokens);

  final String text;
  final OneRayTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
      child: Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: tokens.sub)),
    );
  }
}

/// 一条线路。右边最多一个标记：使用中 > 维修中 > 推荐 > 精品/标准 > 适合 X。
class _LineRow extends StatelessWidget {
  const _LineRow({
    super.key,
    required this.option,
    required this.tokens,
    required this.current,
    required this.connected,
    required this.pro,
    required this.showKind,
    required this.isp,
    required this.tierTag,
    required this.recommended,
    required this.down,
    required this.busy,
    required this.grade,
    required this.best,
    required this.aiTip,
    required this.onTap,
  });

  final LineOption option;
  final OneRayTokens tokens;
  final bool current;
  final bool connected;
  final bool pro;

  /// 「正在用」那块第二行最前面写是精品还是标准。
  final bool showKind;
  final String isp;
  final String tierTag;
  final bool recommended;
  final bool down;
  final bool busy;
  final SpeedGrade? grade;
  final bool best;
  final String aiTip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final country = lineCountry(option.name);
    final city = _shortName(country, option.name);
    final (String, int)? marker = current
        ? (connected ? '使用中' : '上次用的', connected ? 2 : 1)
        : down
            ? ('维修中', 0)
            : busy
            ? ('繁忙', 0)
            : recommended
                ? ('推荐', 0)
                : tierTag.isNotEmpty
                    ? (tierTag, tierTag == '精品' ? 2 : 0)
                    // 适合自己宽带的每一条都标，精品、标准一样（10-18 运营定，两端统一：以前一组全适合就只在标题写一次，看着像漏了）。
                    : lineFitsIsp(option, isp)
                        ? ('适合$isp', 1)
                        : null;
    final sub = TextStyle(fontSize: 12, color: tokens.sub);
    final g = grade;
    // 第二行几段用「 · 」隔开（哪段没有就不留空隔点）：精品/标准 · 说明 · 测速 · AI 提示；维修中只说一句。
    final groups = <List<InlineSpan>>[
      if (showKind)
        [
          TextSpan(
            text: pro ? '精品线路' : '标准线路',
            style: TextStyle(color: pro ? tokens.acc : tokens.sub, fontWeight: pro ? FontWeight.w600 : FontWeight.w400),
          ),
        ],
      if (down) [const TextSpan(text: '暂时连不上，修好会自动恢复')],
      if (!down && option.desc.isNotEmpty) [TextSpan(text: option.desc)],
      if (!down && g != null && g.level > 0)
        [
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Container(
              width: 7,
              height: 7,
              margin: const EdgeInsets.only(right: 5),
              decoration: BoxDecoration(color: _speedDot(g.level), shape: BoxShape.circle),
            ),
          ),
          TextSpan(text: g.word + (best ? ' · 最稳' : ''), style: TextStyle(color: _speedInk(g.level))),
        ],
      if (!down && aiTip.isNotEmpty) [TextSpan(text: aiTip)],
    ];
    final second = <InlineSpan>[
      for (final (i, group) in groups.indexed) ...[
        if (i > 0) const TextSpan(text: ' · '),
        ...group,
      ],
    ];
    final row = Material(
      color: current ? tokens.accSoft : Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Stack(
                children: [
                  LineFlag(option.name, size: 36),
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: tokens.ring)),
                  ),
                ],
              ),
              const Gap(12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: country, style: const TextStyle(fontWeight: FontWeight.w700)),
                          TextSpan(text: ' · $city'),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 16, color: down ? tokens.dim : tokens.text),
                    ),
                    if (second.isNotEmpty) ...[
                      const Gap(3),
                      Text.rich(TextSpan(children: second), maxLines: 1, overflow: TextOverflow.ellipsis, style: sub),
                    ],
                  ],
                ),
              ),
              if (marker != null) ...[
                const Gap(8),
                _Pill(text: marker.$1, kind: marker.$2, tokens: tokens),
              ],
            ],
          ),
        ),
      ),
    );
    return down ? Opacity(opacity: 0.55, child: row) : row;
  }

  Color _speedDot(int level) => switch (level) {
        1 => tokens.ok,
        2 => tokens.warn,
        3 => tokens.dim,
        4 => tokens.fault,
        _ => tokens.sub,
      };

  Color _speedInk(int level) => switch (level) {
        1 => tokens.ok,
        2 => tokens.warnInk,
        4 => tokens.fault,
        _ => tokens.sub,
      };
}

/// 右边的小标记：kind 2 = 实心主题色，1 = 浅主题色，0 = 灰。
class _Pill extends StatelessWidget {
  const _Pill({required this.text, required this.kind, required this.tokens});

  final String text;
  final int kind;
  final OneRayTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: kind == 2 ? tokens.acc : (kind == 1 ? tokens.accSoft : tokens.panel),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Text(
        text,
        maxLines: 1,
        style: TextStyle(
          fontSize: 11,
          fontWeight: kind == 0 ? FontWeight.w400 : FontWeight.w600,
          color: kind == 2 ? tokens.accInk : (kind == 1 ? tokens.acc : tokens.sub),
        ),
      ),
    );
  }
}

/// 精品线路组标题：名字 + 一句 + 今日用量（超额变红）+ 细进度条。
class _ProHeader extends StatelessWidget {
  const _ProHeader({
    required this.tokens,
    required this.hint,
    required this.hintAcc,
    required this.account,
    this.onUpgrade,
  });

  final OneRayTokens tokens;

  /// 体验中：留一个升级入口（以前体验条上有「升级精品版」按钮）。
  final VoidCallback? onUpgrade;
  final String hint;
  final bool hintAcc;
  final PanelAccount? account;

  @override
  Widget build(BuildContext context) {
    final acc = account;
    final know = acc != null && acc.proKnown;
    final throttled = know && acc.proThrottled;
    final ratio = know && acc.proQuota > 0 ? (acc.proUsed / acc.proQuota).clamp(0.0, 1.0) : 0.0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text('精品线路', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: tokens.acc)),
              const Gap(8),
              Expanded(
                child: Text(
                  hint,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: hintAcc ? tokens.acc : tokens.sub),
                ),
              ),
              if (onUpgrade != null)
                GestureDetector(
                  onTap: onUpgrade,
                  child: Text('升级精品版 ›', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: tokens.acc)),
                )
              else if (know)
                Text(
                  throttled
                      ? '今天已超 ${formatDailyAmount(acc.proQuota)}，现在速度最高 ${acc.proThrottleMbps}Mbps'
                      : '今日 ${formatDailyAmount(acc.proUsed)} / ${formatDailyAmount(acc.proQuota)}',
                  style: TextStyle(fontSize: 12, color: throttled ? tokens.fault : tokens.sub),
                ),
            ],
          ),
          if (know) ...[
            const Gap(8),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: SizedBox(
                height: 4,
                child: Stack(
                  children: [
                    Container(color: tokens.panel),
                    FractionallySizedBox(
                      widthFactor: throttled ? 1 : (ratio < 0.01 ? 0.01 : ratio),
                      child: Container(color: throttled ? tokens.fault : tokens.acc),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 精品锁着（标准版用户）：带锁的卡，每条精品线一小行，卡底「领取 / 升级」。
class _LockedProCard extends StatelessWidget {
  const _LockedProCard({
    required this.tokens,
    required this.lines,
    required this.countries,
    required this.onUpgrade,
    required this.onLineTap,
  });

  final OneRayTokens tokens;
  final List<LineOption> lines;
  final List<String> countries;
  final VoidCallback onUpgrade;
  // 点了某条锁着的精品线路：能领体验就先问要不要试（10-20 起不再给所有人挂「领取」横幅）
  final VoidCallback onLineTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: tokens.ring),
        borderRadius: BorderRadius.circular(16),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      LineIcon(LineIconName.lock, color: tokens.acc, size: 14),
                      const Gap(8),
                      Text('精品线路', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: tokens.acc)),
                      const Gap(8),
                      Text('晚高峰也不卡', style: TextStyle(fontSize: 12, color: tokens.sub)),
                    ],
                  ),
                  const Gap(4),
                  Text('${countries.join(' · ')}，精品版才能用', style: TextStyle(fontSize: 12, color: tokens.sub)),
                ],
              ),
            ),
            for (final o in lines)
              InkWell(
                onTap: onLineTap,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                  child: Row(
                    children: [
                      Opacity(opacity: 0.7, child: LineFlag(o.name, size: 26)),
                      const Gap(12),
                      Expanded(
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: lineCountry(o.name),
                                style: TextStyle(fontWeight: FontWeight.w700, color: tokens.text),
                              ),
                              TextSpan(text: ' · ${_shortName(lineCountry(o.name), o.name)}'),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 14, color: tokens.sub),
                        ),
                      ),
                      LineIcon(LineIconName.lock, color: tokens.dim, size: 14),
                    ],
                  ),
                ),
              ),
            const Gap(6),
            Container(
              color: tokens.accSoft,
              padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text('想晚高峰更快？', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: tokens.text)),
                  ),
                  const Gap(8),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: tokens.acc,
                      foregroundColor: tokens.accInk,
                      minimumSize: const Size(0, 36),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      shape: const StadiumBorder(),
                    ),
                    onPressed: onUpgrade,
                    child: Text('升级精品版', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, fontFamily: DefaultTextStyle.of(context).style.fontFamily)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 标准线路卡：点进去单独一页。正在用的是标准线路时，那个地区的小标签变浅绿 + 绿点。
class _StdCard extends StatelessWidget {
  const _StdCard({
    required this.tokens,
    required this.count,
    required this.regions,
    required this.currentRegion,
    required this.onTap,
  });

  final OneRayTokens tokens;
  final int count;
  final List<String> regions;
  final String currentRegion;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: tokens.panel,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text('标准线路', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: tokens.text)),
                  const Gap(8),
                  Expanded(
                    child: Text('晚高峰可能变慢 · $count 条', style: TextStyle(fontSize: 12, color: tokens.sub)),
                  ),
                  Icon(Icons.chevron_right_rounded, size: 20, color: tokens.sub),
                ],
              ),
              const Gap(10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final r in regions)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                      decoration: BoxDecoration(
                        color: r == currentRegion ? tokens.accSoft : tokens.card,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (r == currentRegion) ...[
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(color: tokens.acc, shape: BoxShape.circle),
                            ),
                            const Gap(4),
                          ],
                          Text(
                            r,
                            style: TextStyle(
                              fontSize: 12,
                              color: r == currentRegion ? tokens.acc : tokens.text,
                              fontWeight: r == currentRegion ? FontWeight.w600 : FontWeight.w400,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 最后两张卡里的一张（投票 / 定制）。
class _FootTile extends StatelessWidget {
  const _FootTile({required this.tokens, required this.title, required this.link, required this.onTap});

  final OneRayTokens tokens;
  final String title;
  final String link;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: tokens.ring),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: tokens.text)),
              const Gap(4),
              Text(link,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: tokens.acc)),
            ],
          ),
        ),
      ),
    );
  }
}

class _SpeedButton extends ConsumerWidget {
  const _SpeedButton({required this.tokens});

  final OneRayTokens tokens;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final speed = ref.watch(lineSpeedProvider);
    final label = speed.running ? '测速中 ${speed.done}/${speed.total}' : '测速';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (speed.stamp.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(speed.stamp, style: TextStyle(fontSize: 12, color: tokens.dim)),
          ),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 36),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            foregroundColor: tokens.text,
            side: BorderSide(color: tokens.line),
            shape: const StadiumBorder(),
          ),
          onPressed: speed.running ? null : () => ref.read(lineSpeedProvider.notifier).start(),
          icon: LineIcon(LineIconName.gauge, color: speed.running ? tokens.sub : tokens.text, size: 14),
          label: Text(label, style: const TextStyle(fontSize: 13)),
        ),
      ],
    );
  }
}

import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/model/remote_site_config.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/panel_auth/data/panel_api.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hiddify/features/proxy/line/line_source.dart';
import 'package:hiddify/features/proxy/line/line_speed.dart';
import 'package:hiddify/features/proxy/line/line_tier.dart';
import 'package:hiddify/features/proxy/model/node_display.dart';
import 'package:hiddify/features/proxy/model/node_flag.dart';
import 'package:hiddify/features/purchase/notifier/purchase_notifier.dart';
import 'package:hiddify/features/purchase/widget/purchase_tokens.dart';
import 'package:hiddify/utils/uri_utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

export 'package:hiddify/features/proxy/line/line_source.dart' show LineOption, activeProfileLinesProvider;

/// 线路页：首页线路条点「换线路」打开。
///
/// 断开也能看、没账号也能看、到期也能看 —— 这三种情况下显示的是公开清单（只有名字），
/// 点具体某条时才弹引导（去买套餐 / 登录）。就是推广要的「先看得到，点的时候才拦」。
///
/// 故意**不做**「自动选最快」和延迟数字：
///  - 自动选最快 = 内核 urltest，要先连上再逐条发真实请求测，走隧道扣流量；而且所有人都
///    测出同一条最快就一起涌过去，跟服务端的负载均衡对着干（订阅模板早就关了 urltest）。
///    推荐哪条由服务端负载均衡决定 —— 订阅第一条就是给这个用户的。
///  - 延迟数字会被用户拿去跟别家比，而别家显示的经常是到中转入口、不是到落地的。
///
/// 标记的口径（1.1.40 改）：
///  - 「使用中 / 上次用的」标在用户自己那条上 —— 他打开这页最先要找的就是它；
///  - 「推荐」只给**还没自己选过线路**的人看。老用户有习惯的线路，再对着订阅第一条
///    喊推荐就是噪音，他又不会照着换；
///  - 打开时自动滚到自己那条：线路十几条，不滚它经常在屏幕外。
Future<void> showLinePicker(BuildContext context, WidgetRef ref) async {
  // 灰字用得到配置，但抽屉必须马上弹。300 毫秒内回来就带上，回不来先开抽屉。
  await RemoteSiteConfig.ensureLoaded().timeout(const Duration(milliseconds: 300), onTimeout: () {});
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => const _LinePickerSheet(),
  );
}

class _LinePickerSheet extends ConsumerStatefulWidget {
  const _LinePickerSheet();

  @override
  ConsumerState<_LinePickerSheet> createState() => _LinePickerSheetState();
}

class _LinePickerSheetState extends ConsumerState<_LinePickerSheet> {
  /// 一条 ListTile 的大致高度（名字 + 一行说明）。只用来估初始滚动位置，
  /// 估歪了后面的 ensureVisible 会兜住。
  static const _tileHeight = 76.0;

  /// 挂在「使用中 / 上次用的」那条上，用来精确滚到它。
  final _currentKey = GlobalKey();

  ScrollController? _controller;
  bool _scrolled = false;

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  /// 先按行高粗估跳过去（列表是懒构建的，屏幕外的条目根本没 build，没法直接定位），
  /// 等目标进了视口再 ensureVisible 精确居中。只做一次，之后用户滚到哪就是哪。
  void _revealCurrent(int index) {
    if (_scrolled || index < 0) return;
    _scrolled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _currentKey.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.4,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final set = ref.watch(lineSetProvider);
    // 正在用 / 上次连上的那条（连接成功时首页会写进来）。
    final currentName = ref.watch(Preferences.lastNodeName);
    // 用户自己在这页选过的那条。选过了就不用再给他看「推荐」。
    final pickedName = ref.watch(Preferences.preferredLineName);
    final connected = ref.watch(connectionNotifierProvider).valueOrNull?.isConnected ?? false;

    final value = set.valueOrNull;
    final options = value?.lines ?? const <LineOption>[];
    final locked = value?.locked ?? false;
    final tiers = ref.watch(lineTierProvider);

    final tiered = options.isNotEmpty && tiers.proLines.isNotEmpty;
    Widget body;
    if (tiered) {
      body = Expanded(
        child: _TieredLines(
          options: options,
          locked: locked,
          currentName: currentName,
          pickedName: pickedName,
          connected: connected,
          tiers: tiers,
          speed: ref.watch(lineSpeedProvider),
          usageLabel: _proUsage(ref, tiers),
          usageWarn: ref.watch(panelAuthProvider).account?.proThrottled ?? false,
          onPick: (o) => locked ? _promptUnlock(context, ref) : _pick(context, ref, o),
          onUpgradeStd: () {
            ref.read(purchasePreferTierProvider.notifier).state = 'std';
            Navigator.of(context).pop();
            context.pushNamed('purchase');
          },
          onUpgrade: () {
            ref.read(purchasePreferTierProvider.notifier).state = 'pro';
            Navigator.of(context).pop();
            context.pushNamed('purchase');
          },
          onClaim: () async {
            final msg = await ref.read(lineTierProvider.notifier).claim();
            if (!context.mounted || msg == null) return;
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
          },
        ),
      );
    } else if (options.isNotEmpty) {
      final currentIndex =
          (locked || currentName.isEmpty) ? -1 : options.indexWhere((o) => o.name == currentName);
      // 前两条本来就在视口里，不用滚。
      final needScroll = currentIndex > 1;
      _controller ??= ScrollController(
        initialScrollOffset: needScroll ? (currentIndex * _tileHeight - 120).clamp(0.0, 4000.0) : 0,
      );
      if (needScroll) _revealCurrent(currentIndex);

      body = Flexible(
        child: ListView(
          controller: _controller,
          shrinkWrap: true,
          children: [
            for (final (i, o) in options.indexed)
              _LineTile(
                key: i == currentIndex ? _currentKey : null,
                option: o,
                locked: locked,
                current: i == currentIndex,
                // 没自己选过线路才标「推荐」；正在用的那条只标「使用中」，不叠两个牌子。
                recommended: i == 0 && !locked && pickedName.isEmpty && i != currentIndex,
                connected: connected,
                onTap: () => locked ? _promptUnlock(context, ref) : _pick(context, ref, o),
              ),
            if (_customLineUrl() != null) ...[
              const Divider(height: 1),
              ListTile(
                leading: const _ServerMark(),
                title: const Text('定制我的专属线路'),
                subtitle: Text(
                  '可独享或拼车',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () {
                  final url = _customLineUrl()!;
                  Navigator.of(context).pop();
                  UriUtils.tryLaunch(Uri.parse(url));
                },
              ),
            ],
          ],
        ),
      );
    } else if (set.isLoading) {
      body = const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
    } else {
      body = const Padding(
        padding: EdgeInsets.all(20),
        child: Text('暂时读不到线路，检查一下网络，或在「我的」页联系客服。'),
      );
    }

    final sheet = Column(
      mainAxisSize: tiered ? MainAxisSize.max : MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
          child: Row(
            children: [
              Text('选择线路', style: theme.textTheme.titleMedium),
              const Spacer(),
              if (!locked) const _SpeedButton(),
            ],
          ),
        ),
        if (locked && options.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
            child: Text(
              '这些是我们现有的线路，买套餐后就能选着用。',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        body,
        const Gap(8),
      ],
    );
    if (!tiered) {
      return SafeArea(child: sheet);
    }
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.85,
        child: sheet,
      ),
    );
  }

  /// 选线路：只记偏好 + 立即更新首页显示；实际切换由 autoLineFixer 统一做
  /// （已连接 → 立刻切；没连接 → 下次连接时按名字切）。
  Future<void> _pick(BuildContext context, WidgetRef ref, LineOption o) async {
    await ref.read(Preferences.preferredLineName.notifier).update(o.name);
    await ref.read(Preferences.lastNodeName.notifier).update(o.name);
    await ref.read(Preferences.lastNodeDesc.notifier).update(o.desc);
    if (context.mounted) Navigator.of(context).pop();
  }

  /// 点了连不上的线路：按他缺什么给什么（有账号但到期 → 买套餐；没账号 → 登录 / 试用）。
  Future<void> _promptUnlock(BuildContext context, WidgetRef ref) async {
    Navigator.of(context).pop();
    final account = ref.read(panelAuthProvider).account;
    if (account != null) {
      await ref.read(dialogNotifierProvider.notifier).showQuotaExhausted(account, force: true);
      return;
    }
    await ref.read(dialogNotifierProvider.notifier).showNeedAccount();
  }
}

String? _customLineUrl() {
  final url = RemoteSiteConfig.customUrl;
  if (!RemoteSiteConfig.customEnabled || url == null || url.isEmpty) return null;
  return url;
}

Widget? _lineSubtitle(ThemeData theme, LineOption option) {
  final code = countryCodeFromLineName(option.name);
  final tag = RemoteSiteConfig.aiTipTag;
  final showTag = tag != null && code != null && RemoteSiteConfig.aiTipRegions.contains(code);
  if (option.desc.isEmpty && !showTag) return null;
  if (!showTag) return Text(option.desc);
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (option.desc.isNotEmpty) Text(option.desc),
      Text(
        tag,
        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    ],
  );
}

class _LineTile extends StatelessWidget {
  const _LineTile({
    super.key,
    required this.option,
    required this.locked,
    required this.current,
    required this.recommended,
    required this.connected,
    required this.onTap,
  });

  final LineOption option;
  final bool locked;
  final bool current;
  final bool recommended;
  final bool connected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 没连着的时候说「上次用的」才是实话 —— 写「使用中」会让人以为已经连上了。
    // 第二项 = 要不要高亮：自己那条用主题色牌子，「推荐」只是灰牌子，别抢眼。
    final (String, bool)? tag = current
        ? (connected ? '使用中' : '上次用的', true)
        : (recommended ? const ('推荐', false) : null);

    return ListTile(
      leading: LineFlag(option.name, size: 26),
      title: Row(
        children: [
          Flexible(child: Text(option.name, style: const TextStyle(fontWeight: FontWeight.w600))),
          if (tag != null) ...[
            const Gap(8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: tag.$2 ? theme.colorScheme.primaryContainer : theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                tag.$1,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: tag.$2 ? theme.colorScheme.onPrimaryContainer : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ],
      ),
      subtitle: _lineSubtitle(theme, option),
      trailing: locked ? Icon(Icons.lock_outline_rounded, size: 18, color: theme.colorScheme.outline) : null,
      selected: current,
      onTap: onTap,
    );
  }
}

class _ServerMark extends StatelessWidget {
  const _ServerMark();

  @override
  Widget build(BuildContext context) {
    const gold = Color(0xFF8D6C32);
    const fill = Color(0xFFFBF4DD);
    return Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: gold),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 18,
            height: 6,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(2),
              border: Border.all(color: gold, width: 1),
            ),
          ),
          const SizedBox(height: 2),
          Container(
            width: 18,
            height: 6,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(2),
              border: Border.all(color: gold, width: 1),
            ),
          ),
        ],
      ),
    );
  }
}

class _TieredLines extends StatefulWidget {
  const _TieredLines({
    required this.options,
    required this.locked,
    required this.currentName,
    required this.pickedName,
    required this.connected,
    required this.tiers,
    required this.speed,
    this.usageLabel,
    this.usageWarn = false,
    required this.onPick,
    this.onUpgradeStd,
    required this.onUpgrade,
    required this.onClaim,
  });

  final List<LineOption> options;
  final bool locked;
  final String currentName;
  final String pickedName;
  final bool connected;
  final LineTierState tiers;
  final LineSpeedState speed;
  final String? usageLabel;
  final bool usageWarn;
  final void Function(LineOption) onPick;
  final VoidCallback? onUpgradeStd;
  final VoidCallback onUpgrade;
  final VoidCallback onClaim;

  @override
  State<_TieredLines> createState() => _TieredLinesState();
}

class _TieredLinesState extends State<_TieredLines> {
  bool _ready = false;
  bool _proOpen = false;
  bool _stdOpen = true;
  String _openKey = '';
  final _currentLineKey = GlobalKey();
  bool _revealed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealCurrent());
  }

  void _revealCurrent() {
    if (_revealed || !mounted) return;
    final ctx = _currentLineKey.currentContext;
    if (ctx == null) return;
    _revealed = true;
    Scrollable.ensureVisible(ctx, alignment: 0.4, duration: const Duration(milliseconds: 220));
  }

  String _country(LineOption o) {
    final head = o.name.split(RegExp(r'\s+')).first.trim();
    return head.isEmpty ? '其它' : head;
  }

  String _shortName(String country, String name) {
    final trimmed = name.trim();
    if (!trimmed.startsWith(country)) return trimmed;
    final rest = trimmed.substring(country.length).trim();
    return rest.isEmpty ? trimmed : rest;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = PurchaseTokens.of(context);
    final ink3 = tokens.secondary.withValues(alpha: 0.7);
    final okDeep = Theme.of(context).brightness == Brightness.dark ? tokens.remaining : const Color(0xFF1F6F59);
    final pro = <String, List<LineOption>>{};
    final std = <String, List<LineOption>>{};
    final proOrder = <String>[];
    final stdOrder = <String>[];
    String? usingSeg;
    String? usingCountry;
    for (final o in widget.options) {
      final isPro = widget.tiers.isProName(o.name);
      final bucket = isPro ? pro : std;
      final order = isPro ? proOrder : stdOrder;
      final country = _country(o);
      if (!bucket.containsKey(country)) {
        bucket[country] = [];
        order.add(country);
      }
      bucket[country]!.add(o);
      if (o.name == widget.currentName) {
        usingSeg = isPro ? 'pro' : 'std';
        usingCountry = country;
      }
    }
    final seen = widget.options.map((o) => o.name).toSet();
    for (final line in widget.tiers.proLines) {
      final split = splitNodeName(line.name);
      if (split.name.isEmpty || seen.contains(split.name)) continue;
      seen.add(split.name);
      final country = split.name.split(RegExp(r'\s+')).first.trim();
      final key = country.isEmpty ? '其它' : country;
      pro.putIfAbsent(key, () {
        proOrder.add(key);
        return [];
      });
      pro[key]!.add((name: split.name, desc: split.desc));
    }
    if (!_ready) {
      _ready = true;
      final preferPro = widget.tiers.trial == 'pro' || widget.tiers.trial == 'active';
      final usingPro = usingSeg == 'pro';
      _proOpen = preferPro || usingPro;
      _stdOpen = !preferPro || (widget.currentName.isNotEmpty && !usingPro);
      if (usingSeg != null && usingCountry != null) _openKey = '$usingSeg|$usingCountry';
    }
    final proLocked = widget.tiers.trial != 'pro' && widget.tiers.trial != 'active';
    final recommended = widget.pickedName.isEmpty && widget.options.isNotEmpty ? widget.options.first.name : '';
    final children = <Widget>[];

    void addSeg(String seg, List<String> order, Map<String, List<LineOption>> bucket) {
      if (order.isEmpty) return;
      final open = seg == 'pro' ? _proOpen : _stdOpen;
      final isPro = seg == 'pro';
      final title = isPro ? '优化线路' : '标准线路';
      var hint = isPro ? '晚高峰也不卡' : '晚高峰可能变慢';
      var hintWarn = false;
      if (isPro && widget.usageLabel != null && widget.usageLabel!.isNotEmpty) {
        hintWarn = widget.usageWarn;
        hint = widget.usageLabel!;
      }
      final promo = _promo(isPro, open, proLocked, tokens, okDeep);
      children.add(Padding(
        padding: const EdgeInsets.fromLTRB(2, 0, 2, 8),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: tokens.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: isPro ? tokens.okBorder : tokens.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
                  hoverColor: isPro ? tokens.okSoft : tokens.fill,
                  highlightColor: isPro ? tokens.okSoft : tokens.fill,
                  splashColor: isPro ? tokens.okSoft : tokens.fill,
                  onTap: () => setState(() {
                    if (isPro) {
                      _proOpen = !_proOpen;
                    } else {
                      _stdOpen = !_stdOpen;
                    }
                  }),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: isPro ? okDeep : tokens.text,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                (isPro && widget.usageLabel != null && widget.usageLabel!.isNotEmpty)
                                    ? hint
                                    : '$hint · ${order.join(' · ')}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 11, color: hintWarn ? tokens.warning : ink3),
                              ),
                            ],
                          ),
                        ),
                        if (isPro && proLocked) ...[
                          const SizedBox(width: 8),
                          _GoldButton(label: '升级优化版', onTap: widget.onUpgrade, tokens: tokens),
                        ],
                        const SizedBox(width: 6),
                        Transform.rotate(
                          angle: open ? 1.5708 : 0,
                          child: Text('›', style: TextStyle(fontSize: 16, height: 1, color: ink3)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (promo != null) promo,
              if (open)
                for (final country in order)
                  _countryBlock(
                    seg: seg,
                    country: country,
                    lines: bucket[country]!,
                    blocked: isPro && proLocked,
                    tokens: tokens,
                    ink3: ink3,
                    recommended: recommended,
                  ),
            ],
          ),
        ),
      ));
    }

    addSeg('pro', proOrder, pro);
    addSeg('std', stdOrder, std);
    final custom = _customLineUrl();
    if (custom != null) {
      children.add(_CustomLineRow(
        tokens: tokens,
        onTap: () {
          Navigator.of(context).pop();
          UriUtils.tryLaunch(Uri.parse(custom));
        },
      ));
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
      children: children,
    );
  }

  Widget? _promo(bool isPro, bool open, bool proLocked, PurchaseTokens tokens, Color okDeep) {
    if (!isPro) return null;
    if (widget.tiers.trial == 'active') {
      final mins = (widget.tiers.seconds / 60).ceil().clamp(1, 9999);
      return _PromoRow(
        label: '优化线路体验中 · 还剩 $mins 分钟',
        action: '升级优化版',
        warm: false,
        tokens: tokens,
        okDeep: okDeep,
        onTap: widget.onUpgrade,
      );
    }
    if (open || !proLocked) return null;
    final offer = widget.tiers.trial == 'offer';
    final lockedTrial = widget.tiers.trial == 'locked';
    final hour = widget.tiers.minutes == 60;
    final label = offer
        ? (hour ? '您可领取 1 小时优化线路体验' : '您可领取 ${widget.tiers.minutes} 分钟优化线路体验')
        : lockedTrial
            ? (hour ? '标准版会员可领 1 小时优化线路体验' : '标准版会员可领 ${widget.tiers.minutes} 分钟优化线路体验')
            : '想晚高峰更快？';
    return _PromoRow(
      label: label,
      action: offer ? '领取' : (lockedTrial ? '升级' : '升级优化版'),
      warm: !offer,
      tokens: tokens,
      okDeep: okDeep,
      onTap: offer ? widget.onClaim : (lockedTrial ? (widget.onUpgradeStd ?? widget.onUpgrade) : widget.onUpgrade),
    );
  }

  Widget _countryBlock({
    required String seg,
    required String country,
    required List<LineOption> lines,
    required bool blocked,
    required PurchaseTokens tokens,
    required Color ink3,
    required String recommended,
  }) {
    final key = '$seg|$country';
    final expanded = _openKey == key;
    final usingHere = lines.any((o) => o.name == widget.currentName);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            hoverColor: tokens.fill,
            highlightColor: tokens.fill,
            onTap: blocked ? widget.onUpgrade : () => setState(() => _openKey = expanded ? '' : key),
            child: SizedBox(
              height: 52,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    Opacity(
                      opacity: blocked ? 0.5 : 1,
                      child: SizedBox(
                        width: 32,
                        height: 32,
                        child: Stack(
                          children: [
                            LineFlag(lines.first.name, size: 32),
                            Container(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(color: tokens.border),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Opacity(
                        opacity: blocked ? 0.5 : 1,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              country,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: tokens.text),
                            ),
                            Text(
                              '${lines.length} 条线路${usingHere ? ' · 正在用这里的' : ''}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 10, color: ink3),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // 线路只有名字，没有接入响应测量（不做 urltest、不显示延迟数字）。
                    // 跟 Windows 一样：没有测量结果就不画响应圆点。
                    if (!blocked && _bestGrade(lines) != null) ...[
                      _SpeedDot(level: _bestGrade(lines)!.level, tokens: tokens),
                      const SizedBox(width: 4),
                      Text(_bestGrade(lines)!.word, style: TextStyle(fontSize: 10, color: tokens.secondary)),
                      const SizedBox(width: 6),
                    ],
                    if (blocked)
                      Text('升级优化版 ›', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: tokens.primary))
                    else ...[
                      Transform.rotate(
                        angle: expanded ? 1.5708 : 0,
                        child: Text('›', style: TextStyle(fontSize: 16, height: 1, color: ink3)),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
        if (expanded && !blocked)
          Padding(
            padding: const EdgeInsets.only(left: 44),
            child: DecoratedBox(
              decoration: BoxDecoration(border: Border(left: BorderSide(color: tokens.border))),
              child: Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Column(
                  children: [
                    for (final o in lines)
                      _lineRow(o, country, tokens, o.name == recommended),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  SpeedGrade? _bestGrade(List<LineOption> lines) {
    SpeedGrade? best;
    for (final o in lines) {
      final grade = widget.speed.grades[o.name];
      if (grade == null || grade.level <= 0 || grade.level == 5) continue;
      if (best == null || grade.level < best.level) best = grade;
    }
    return best;
  }

  Widget _lineRow(LineOption o, String country, PurchaseTokens tokens, bool recommended) {
    final current = o.name == widget.currentName;
    final short = _shortName(country, o.name);
    final grade = widget.speed.grades[o.name];
    final best = widget.speed.bestName == o.name && grade != null && grade.level <= 2;
    return Material(
      key: current ? _currentLineKey : null,
      color: current ? tokens.selected : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        hoverColor: tokens.fill,
        highlightColor: tokens.fill,
        onTap: () => widget.onPick(o),
        child: SizedBox(
          height: 40,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: [
                Flexible(
                  flex: 3,
                  child: Text(
                    short,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: tokens.text),
                  ),
                ),
                if (o.desc.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Flexible(
                    flex: 2,
                    child: Text(
                      o.desc,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 10, color: tokens.secondary.withValues(alpha: 0.7)),
                    ),
                  ),
                ],
                if (grade != null) ...[
                  const SizedBox(width: 8),
                  _SpeedDot(level: grade.level, tokens: tokens),
                  const SizedBox(width: 4),
                  Text(grade.word, style: TextStyle(fontSize: 10, color: tokens.secondary)),
                  if (best || current || recommended) const SizedBox(width: 8),
                ],
                if (best && current)
                  Text('使用中 · 最快', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: tokens.remaining))
                else if (best)
                  Text('你这里最快', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: tokens.primary))
                else if (current)
                  Text(
                    widget.connected ? '使用中' : '上次用的',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: widget.connected ? tokens.remaining : tokens.secondary,
                    ),
                  )
                else if (recommended)
                  Text('推荐', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: tokens.primary)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GoldButton extends StatelessWidget {
  const _GoldButton({required this.label, required this.onTap, required this.tokens});

  final String label;
  final VoidCallback onTap;
  final PurchaseTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: tokens.primary,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          alignment: Alignment.center,
          child: Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: tokens.onPrimary)),
        ),
      ),
    );
  }
}

class _PromoRow extends StatelessWidget {
  const _PromoRow({
    required this.label,
    required this.action,
    required this.warm,
    required this.tokens,
    required this.okDeep,
    required this.onTap,
  });

  final String label;
  final String action;
  final bool warm;
  final PurchaseTokens tokens;
  final Color okDeep;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: warm ? tokens.selected : tokens.okSoft,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(fontSize: 12, color: warm ? tokens.text : okDeep),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: onTap,
                child: Container(
                  height: 28,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: warm ? tokens.primary : tokens.remaining,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    action,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: warm ? tokens.onPrimary : Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CustomLineRow extends StatelessWidget {
  const _CustomLineRow({required this.tokens, required this.onTap});

  final PurchaseTokens tokens;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 2, 2, 2),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          hoverColor: tokens.fill,
          highlightColor: tokens.fill,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                const _ServerMark(),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('定制我的专属线路', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: tokens.text)),
                      Text('可独享或拼车', style: TextStyle(fontSize: 11, color: tokens.secondary.withValues(alpha: 0.7))),
                    ],
                  ),
                ),
                Text('›', style: TextStyle(fontSize: 16, color: tokens.secondary.withValues(alpha: 0.7))),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String? _proUsage(WidgetRef ref, LineTierState tiers) {
  final acc = ref.watch(panelAuthProvider).account;
  if (acc == null || !acc.proKnown) return null;
  if (tiers.trial != 'pro' && tiers.trial != 'active') return null;
  if (acc.proThrottled) {
    return '今天已超 ${formatDailyAmount(acc.proQuota)}，优化线路限速 ${acc.proThrottleMbps}Mbps，明天恢复';
  }
  return '今天已用 ${formatDailyAmount(acc.proUsed)} / ${formatDailyAmount(acc.proQuota)} · 所有优化线路合计';
}

class _SpeedButton extends ConsumerWidget {
  const _SpeedButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final speed = ref.watch(lineSpeedProvider);
    final tokens = PurchaseTokens.of(context);
    final ok = Theme.of(context).brightness == Brightness.dark ? tokens.remaining : const Color(0xFF1F6F59);
    final label = speed.running ? '测速中 ${speed.done}/${speed.total}' : '测速';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (speed.stamp.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(speed.stamp, style: TextStyle(fontSize: 11, color: tokens.secondary.withValues(alpha: 0.7))),
          ),
        TextButton(
          style: TextButton.styleFrom(
            minimumSize: const Size(0, 28),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            foregroundColor: ok,
            backgroundColor: speed.running ? tokens.fill : null,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          onPressed: speed.running ? null : () => ref.read(lineSpeedProvider.notifier).start(),
          child: Text(label, style: const TextStyle(fontSize: 12)),
        ),
      ],
    );
  }
}

class _SpeedDot extends StatelessWidget {
  const _SpeedDot({required this.level, required this.tokens});

  final int level;
  final PurchaseTokens tokens;

  @override
  Widget build(BuildContext context) {
    final color = switch (level) {
      1 => tokens.remaining,
      2 => tokens.warning,
      3 => tokens.empty,
      _ => tokens.secondary.withValues(alpha: 0.7),
    };
    return Container(width: 6, height: 6, decoration: BoxDecoration(color: color, shape: BoxShape.circle));
  }
}

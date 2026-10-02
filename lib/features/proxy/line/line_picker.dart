import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/model/remote_site_config.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hiddify/features/proxy/line/line_source.dart';
import 'package:hiddify/features/proxy/line/line_tier.dart';
import 'package:hiddify/features/proxy/model/node_flag.dart';
import 'package:hiddify/features/purchase/notifier/purchase_notifier.dart';
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

    Widget body;
    if (options.isNotEmpty && tiers.proLines.isNotEmpty) {
      body = Flexible(
        child: _TieredLines(
          options: options,
          locked: locked,
          currentName: currentName,
          pickedName: pickedName,
          connected: connected,
          tiers: tiers,
          onPick: (o) => locked ? _promptUnlock(context, ref) : _pick(context, ref, o),
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

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text('选择线路', style: theme.textTheme.titleMedium),
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
    required this.onPick,
    required this.onUpgrade,
    required this.onClaim,
  });

  final List<LineOption> options;
  final bool locked;
  final String currentName;
  final String pickedName;
  final bool connected;
  final LineTierState tiers;
  final void Function(LineOption) onPick;
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

  String _country(LineOption o) {
    final head = o.name.split(RegExp(r'\s+')).first.trim();
    return head.isEmpty ? '其它' : head;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final proNames = widget.tiers;
    final pro = <String, List<LineOption>>{};
    final std = <String, List<LineOption>>{};
    final proOrder = <String>[];
    final stdOrder = <String>[];
    String? usingSeg;
    String? usingCountry;
    for (final o in widget.options) {
      final isPro = proNames.isProName(o.name);
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
    if (!_ready) {
      _ready = true;
      final preferPro = widget.tiers.trial == 'pro' || widget.tiers.trial == 'active';
      final usingPro = usingSeg == 'pro';
      _proOpen = preferPro || usingPro;
      _stdOpen = !preferPro || (widget.currentName.isNotEmpty && !usingPro);
      if (usingSeg != null && usingCountry != null) _openKey = '$usingSeg|$usingCountry';
    }
    final proLocked = widget.tiers.trial != 'pro' && widget.tiers.trial != 'active';
    final children = <Widget>[];
    void addSeg(String seg, List<String> order, Map<String, List<LineOption>> bucket) {
      if (order.isEmpty) return;
      final open = seg == 'pro' ? _proOpen : _stdOpen;
      final title = seg == 'pro' ? '优化线路' : '标准线路';
      final hint = seg == 'pro' ? '晚高峰也不卡' : '晚高峰可能变慢';
      children.add(ListTile(
        dense: true,
        title: Text(title, style: TextStyle(fontWeight: FontWeight.w700, color: seg == 'pro' ? const Color(0xFF2A9477) : null)),
        subtitle: Text('$hint · ${order.join(' · ')}', maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (seg == 'pro' && proLocked)
              TextButton(onPressed: widget.onUpgrade, child: const Text('升级优化版')),
            Icon(open ? Icons.expand_more : Icons.chevron_right),
          ],
        ),
        onTap: () => setState(() {
          if (seg == 'pro') {
            _proOpen = !_proOpen;
          } else {
            _stdOpen = !_stdOpen;
          }
        }),
      ));
      if (seg == 'pro' && widget.tiers.trial == 'active') {
        final mins = (widget.tiers.seconds / 60).ceil().clamp(1, 9999);
        children.add(ListTile(
          dense: true,
          title: Text('优化线路体验中 · 还剩 $mins 分钟'),
          trailing: FilledButton(onPressed: widget.onUpgrade, child: const Text('升级优化版')),
        ));
      } else if (seg == 'pro' && !open && proLocked) {
        final offer = widget.tiers.trial == 'offer';
        final label = offer
            ? (widget.tiers.minutes == 60 ? '您可领取 1 小时优化线路体验' : '您可领取 ${widget.tiers.minutes} 分钟优化线路体验')
            : '想晚高峰更快？';
        children.add(ListTile(
          dense: true,
          title: Text(label),
          trailing: offer
              ? FilledButton(onPressed: widget.onClaim, child: const Text('领取'))
              : TextButton(onPressed: widget.onUpgrade, child: const Text('升级优化版')),
        ));
      }
      if (!open) return;
      for (final country in order) {
        final key = '$seg|$country';
        final expanded = _openKey == key;
        final blocked = seg == 'pro' && proLocked;
        final lines = bucket[country]!;
        final usingHere = lines.any((o) => o.name == widget.currentName);
        children.add(ListTile(
          leading: Opacity(opacity: blocked ? 0.5 : 1, child: LineFlag(lines.first.name, size: 32)),
          title: Text(country, style: TextStyle(color: blocked ? theme.colorScheme.outline : null)),
          subtitle: Text(
            '${lines.length} 条线路${usingHere ? ' · 正在用这里的' : ''}',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          trailing: blocked
              ? TextButton(onPressed: widget.onUpgrade, child: const Text('升级优化版 ›'))
              : Icon(expanded ? Icons.expand_more : Icons.chevron_right),
          onTap: blocked
              ? widget.onUpgrade
              : () => setState(() => _openKey = expanded ? '' : key),
        ));
        if (!expanded || blocked) continue;
        for (final o in bucket[country]!) {
          final current = o.name == widget.currentName;
          final short = o.name.trim().startsWith(country)
              ? o.name.trim().substring(country.length).trim()
              : o.name;
          children.add(ListTile(
            contentPadding: const EdgeInsets.only(left: 44, right: 16),
            title: Text(short.isEmpty ? o.name : short),
            subtitle: o.desc.isEmpty
                ? null
                : Text(o.desc, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            trailing: current
                ? Text(widget.connected ? '使用中' : '上次用的')
                : (o == bucket[country]!.first && widget.pickedName.isEmpty && !current
                    ? const Text('推荐')
                    : null),
            onTap: () => widget.onPick(o),
          ));
        }
      }
    }

    addSeg('pro', proOrder, pro);
    addSeg('std', stdOrder, std);
    if (_customLineUrl() != null) {
      children.add(const Divider(height: 1));
      children.add(ListTile(
        leading: const _ServerMark(),
        title: const Text('定制我的专属线路'),
        subtitle: const Text('可独享或拼车'),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () {
          final url = _customLineUrl()!;
          Navigator.of(context).pop();
          UriUtils.tryLaunch(Uri.parse(url));
        },
      ));
    }
    return ListView(shrinkWrap: true, children: children);
  }
}

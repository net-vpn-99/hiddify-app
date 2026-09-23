import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hiddify/features/proxy/line/line_source.dart';
import 'package:hiddify/features/proxy/model/node_flag.dart';
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

    Widget body;
    if (options.isNotEmpty) {
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
      subtitle: option.desc.isEmpty ? null : Text(option.desc),
      trailing: locked ? Icon(Icons.lock_outline_rounded, size: 18, color: theme.colorScheme.outline) : null,
      selected: current,
      onTap: onTap,
    );
  }
}

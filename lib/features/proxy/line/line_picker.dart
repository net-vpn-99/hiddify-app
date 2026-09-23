import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
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
///    推荐哪条由服务端负载均衡决定 —— 订阅第一条就是给这个用户的，标个「推荐」就够了。
///  - 延迟数字会被用户拿去跟别家比，而别家显示的经常是到中转入口、不是到落地的。
Future<void> showLinePicker(BuildContext context, WidgetRef ref) async {
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => const _LinePickerSheet(),
  );
}

class _LinePickerSheet extends ConsumerWidget {
  const _LinePickerSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final set = ref.watch(lineSetProvider);
    final currentName = ref.watch(Preferences.lastNodeName);

    final value = set.valueOrNull;
    final options = value?.lines ?? const <LineOption>[];
    final locked = value?.locked ?? false;

    Widget body;
    if (options.isNotEmpty) {
      final selName = currentName.isNotEmpty ? currentName : options.first.name;
      body = Flexible(
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: options.length,
          itemBuilder: (context, i) {
            final o = options[i];
            // 推荐 = 服务端负载均衡排在订阅第一位的那条（节点粘性也认这一条）。
            final recommended = i == 0 && !locked;
            return ListTile(
              leading: LineFlag(o.name, size: 26),
              title: Row(
                children: [
                  Flexible(child: Text(o.name, style: const TextStyle(fontWeight: FontWeight.w600))),
                  if (recommended) ...[
                    const Gap(8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '推荐',
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: theme.colorScheme.onPrimaryContainer),
                      ),
                    ),
                  ],
                ],
              ),
              subtitle: o.desc.isEmpty ? null : Text(o.desc),
              trailing: locked
                  ? Icon(Icons.lock_outline_rounded, size: 18, color: theme.colorScheme.outline)
                  : (o.name == selName
                        ? Icon(Icons.check_rounded, color: theme.colorScheme.primary)
                        : null),
              selected: !locked && o.name == selName,
              onTap: () => locked ? _promptUnlock(context, ref) : _pick(context, ref, o),
            );
          },
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

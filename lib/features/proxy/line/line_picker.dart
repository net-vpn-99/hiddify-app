import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/router/bottom_sheets/bottom_sheets_notifier.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/model/node_display.dart';
import 'package:hiddify/features/proxy/overview/proxies_overview_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

typedef LineOption = ({String name, String desc});

/// 当前订阅里的线路列表，从本地 profile 文件离线读出来（不用连接）。
final activeProfileLinesProvider = FutureProvider<List<LineOption>>((ref) async {
  final profile = await ref.watch(activeProfileProvider.future);
  if (profile == null) return const [];
  final repo = await ref.watch(profileRepositoryProvider.future);
  final raw = await repo.getRawConfig(profile.id).getOrElse((_) => '').run();
  if (raw.isEmpty) return const [];
  return parseSubscriptionLines(raw);
});

/// 首页"光速卡"点一下弹出来的线路选择器（底部抽屉）。断开也能选。
Future<void> showLinePicker(BuildContext context, WidgetRef ref) async {
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => const _LinePickerSheet(),
  );
}

class _LinePickerSheet extends ConsumerWidget {
  const _LinePickerSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    final offline = ref.watch(activeProfileLinesProvider);
    // 连着的时候内核实时列表兜底（离线解析万一失败）
    final liveGroup = ref.watch(proxiesOverviewNotifierProvider).valueOrNull;
    final currentName = ref.watch(Preferences.lastNodeName);

    final offlineOptions = offline.valueOrNull ?? const <LineOption>[];
    final List<LineOption> options;
    if (offlineOptions.isNotEmpty) {
      options = offlineOptions;
    } else if (liveGroup != null && liveGroup.items.isNotEmpty) {
      options = [for (final it in liveGroup.items) splitNodeName(it.tagDisplay)];
    } else {
      options = const [];
    }

    Widget body;
    if (options.isNotEmpty) {
      final selName = currentName.isNotEmpty ? currentName : options.first.name;
      body = Flexible(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final o in options)
              ListTile(
                title: Text(o.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: o.desc.isEmpty ? null : Text(o.desc),
                trailing: o.name == selName ? Icon(Icons.check_rounded, color: theme.colorScheme.primary) : null,
                selected: o.name == selName,
                onTap: () => _pick(context, ref, o),
              ),
          ],
        ),
      );
    } else if (offline.isLoading) {
      body = const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
    } else {
      body = const Padding(
        padding: EdgeInsets.all(20),
        child: Text('没读到线路。点右上角「更新订阅」，或先连接一次再回来。'),
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
          body,
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.swap_horiz_rounded),
            title: const Text('管理 / 更换订阅'),
            onTap: () {
              Navigator.of(context).pop();
              ref.read(bottomSheetsNotifierProvider.notifier).showProfilesOverview();
            },
          ),
          const Gap(8),
        ],
      ),
    );
  }

  /// 选线路：只记偏好 + 立即更新首页卡显示；实际切换由 autoLineFixer 统一做
  /// （已连接 → 立刻切；没连接 → 下次连接时按名字切）。
  Future<void> _pick(BuildContext context, WidgetRef ref, LineOption o) async {
    await ref.read(Preferences.preferredLineName.notifier).update(o.name);
    await ref.read(Preferences.lastNodeName.notifier).update(o.name);
    await ref.read(Preferences.lastNodeDesc.notifier).update(o.desc);
    if (context.mounted) Navigator.of(context).pop();
  }
}

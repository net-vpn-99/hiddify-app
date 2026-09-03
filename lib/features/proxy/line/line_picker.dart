import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/router/bottom_sheets/bottom_sheets_notifier.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/data/proxy_data_providers.dart';
import 'package:hiddify/features/proxy/model/node_display.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

typedef LineOption = ({String name, String desc});

/// 当前订阅里的线路列表，直接从订阅原文离线读出来（不用连接）。
final activeProfileLinesProvider = FutureProvider<List<LineOption>>((ref) async {
  final profile = await ref.watch(activeProfileProvider.future);
  if (profile == null) return const [];
  final repo = await ref.watch(profileRepositoryProvider.future);
  final raw = await repo.getRawConfig(profile.id).getOrElse((_) => '').run();
  if (raw.isEmpty) return const [];
  return parseSubscriptionLines(raw);
});

/// 首页"光速卡"点一下弹出来的线路选择器。断开也能用。
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
    final lines = ref.watch(activeProfileLinesProvider);
    final current = ref.watch(Preferences.lastNodeName);

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text('选择线路', style: theme.textTheme.titleMedium),
          ),
          lines.when(
            loading: () => const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
            error: (e, _) => Padding(
              padding: const EdgeInsets.all(20),
              child: Text('读取线路失败：$e', style: theme.textTheme.bodySmall),
            ),
            data: (options) {
              if (options.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text('这条订阅里没读到线路，试试右上角「更新订阅」。'),
                );
              }
              final selectedName = current.isNotEmpty ? current : options.first.name;
              return Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final o in options)
                      ListTile(
                        title: Text(o.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: o.desc.isEmpty ? null : Text(o.desc),
                        trailing: o.name == selectedName
                            ? Icon(Icons.check_rounded, color: theme.colorScheme.primary)
                            : null,
                        selected: o.name == selectedName,
                        onTap: () => _pick(context, ref, o),
                      ),
                  ],
                ),
              );
            },
          ),
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

  Future<void> _pick(BuildContext context, WidgetRef ref, LineOption o) async {
    // 记住选择：preferredLineName 给 autoLineFixer 用，lastNode* 给首页卡片即时显示
    await ref.read(Preferences.preferredLineName.notifier).update(o.name);
    await ref.read(Preferences.lastNodeName.notifier).update(o.name);
    await ref.read(Preferences.lastNodeDesc.notifier).update(o.desc);

    if (context.mounted) Navigator.of(context).pop();

    // 已连接的话立刻切；没连接的话 first 会抛错，等连接时 autoLineFixer 按名字切
    final repo = ref.read(proxyRepositoryProvider);
    try {
      final either = await repo.watchProxies().first.timeout(const Duration(seconds: 3));
      final group = either.getOrElse((_) => null);
      if (group != null) {
        for (final item in group.items) {
          if (!item.isGroup && !isAutoGroupTag(item.tag) && splitNodeName(item.tag).name == o.name) {
            await repo.selectProxy(group.tag, item.tag).run();
            break;
          }
        }
      }
    } catch (_) {}
  }
}

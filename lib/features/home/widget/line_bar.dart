import 'package:flutter/material.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/panel_auth/notifier/guest_bootstrap.dart';
import 'package:hiddify/features/proxy/line/line_picker.dart';
import 'package:hiddify/features/proxy/line/line_source.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 首页连接按钮下面那条常驻的线路条。
///
/// **一直都在** —— 没连接、没账号、试用到期都显示，点一下就能换线路，不用先连接。
/// 1.1.27 及以前选线路的唯一入口是首页顶上那张「光速卡」，而那张卡在没订阅 / 到期时
/// 直接消失，于是首页只剩一个光秃秃的连接按钮（推广截图里那种）。
class LineBar extends ConsumerWidget {
  const LineBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final preparing = ref.watch(guestBootstrapProvider).working;
    final set = ref.watch(lineSetProvider).valueOrNull;

    // 显示哪条：用户选过的优先，没选过就是服务端排第一的那条（负载均衡给他的）。
    final savedName = ref.watch(Preferences.lastNodeName);
    final savedDesc = ref.watch(Preferences.lastNodeDesc);
    final first = (set != null && set.lines.isNotEmpty) ? set.lines.first : null;
    final name = savedName.isNotEmpty ? savedName : (first?.name ?? '');
    final desc = savedName.isNotEmpty ? savedDesc : (first?.desc ?? '');

    final String title;
    final String? subtitle;
    if (preparing) {
      title = '正在准备线路…';
      subtitle = null;
    } else if (name.isEmpty) {
      title = '选择线路';
      subtitle = '看看有哪些线路';
    } else {
      title = name;
      subtitle = desc.isEmpty ? null : desc;
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Material(
        color: theme.colorScheme.surface.withValues(alpha: .92),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: preparing ? null : () => showLinePicker(context, ref),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: Row(
              children: [
                Icon(Icons.public_rounded, size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '线路',
                        style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline),
                      ),
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      if (subtitle != null)
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '换线路',
                  style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.primary),
                ),
                Icon(Icons.chevron_right_rounded, size: 18, color: theme.colorScheme.primary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

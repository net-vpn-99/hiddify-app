import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// OneRay: 试用 / 会员到期、流量用完、没有套餐时，首页直接顶一张说明卡片 +「去续费」，
/// 不用等用户点连接才知道。账号正常（或未登录）时自己隐藏。
class AccountStateCard extends ConsumerWidget {
  const AccountStateCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(Preferences.panelLoggedIn)) return const SizedBox.shrink();
    final account = ref.watch(panelAuthProvider.select((s) => s.account));
    if (account == null) return const SizedBox.shrink();

    final slug = account.stateSlug;
    if (slug == 'ok') return const SizedBox.shrink();

    final (String title, String subtitle, String btn) = switch (slug) {
      'traffic_exhausted' => ('本期流量已用完', '续费或升级套餐后即可继续连接', '去续费'),
      'expired' => ('会员已到期', '你的套餐（含体验套餐）已到期，续费后立即恢复连接', '去续费'),
      _ => ('还没有可用套餐', '选择一个套餐即可开始使用', '选择套餐'),
    };

    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Row(
          children: [
            Icon(Icons.error_outline_rounded, color: theme.colorScheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onErrorContainer.withValues(alpha: .85),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () => context.pushNamed('purchase'),
              child: Text(btn),
            ),
          ],
        ),
      ),
    );
  }
}

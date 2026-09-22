import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/features/panel_auth/data/panel_api.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

enum QuotaEndedAction { invite, purchase, bind }

/// 流量用完 / 会员到期 / 没有套餐：居中弹窗，不是首页顶栏报错。
/// 到期类主按钮去邀请（还能再拿到体验），续费放第二。
class QuotaEndedDialog extends ConsumerWidget {
  const QuotaEndedDialog({super.key, required this.account});

  final PanelAccount account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final slug = account.stateSlug;
    final bonus = ref.watch(inviteTextsProvider).valueOrNull?.bonus;
    final bonusBit = (bonus != null && bonus.isNotEmpty) ? '双方各得 $bonus' : '双方都能再获得体验';
    // 游客（GslGuest）试用结束：最划算的一步是「绑定邮箱再送 N 小时」，放第一个按钮。
    final isGuest = ref.watch(panelAuthProvider).isGuest && slug != 'no_plan';
    final bindText = ref.watch(guestOptionsProvider).valueOrNull?.bindBonusText;

    final (title, body, showInvite) = isGuest
        ? (
            '免费试用已结束',
            bindText != null
                ? '连接已暂停。$bindText，换手机也能用这个邮箱登录；也可以邀请好友或直接续费。'
                : '连接已暂停。绑定邮箱后可以续费继续用，换手机也能登录；也可以邀请好友试用。',
            true,
          )
        : switch (slug) {
      'traffic_exhausted' => (
        '本期流量已用完',
        '连接已暂停。邀请好友试用，$bonusBit；也可以续费或升级套餐后继续用。',
        true,
      ),
      'expired' => (
        '会员已到期',
        '连接已暂停。邀请好友试用，$bonusBit；也可以续费继续用。',
        true,
      ),
      _ => (
        '还没有可用套餐',
        '选择一个套餐后即可开始使用。',
        false,
      ),
    };

    return Dialog(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(
              slug == 'expired' ? Icons.event_busy_outlined : Icons.data_usage_outlined,
              size: 36,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 10),
            Text(
              body,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 20),
            if (isGuest) ...[
              FilledButton(
                onPressed: () => context.pop(QuotaEndedAction.bind),
                child: Text(bindText ?? '绑定邮箱，继续使用'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () => context.pop(QuotaEndedAction.invite),
                child: const Text('邀请好友试用'),
              ),
            ] else if (showInvite)
              FilledButton(
                onPressed: () => context.pop(QuotaEndedAction.invite),
                child: const Text('邀请好友试用'),
              )
            else
              FilledButton(
                onPressed: () => context.pop(QuotaEndedAction.purchase),
                child: const Text('选择套餐'),
              ),
            if (showInvite) ...[
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () => context.pop(QuotaEndedAction.purchase),
                child: const Text('去续费'),
              ),
            ],
            TextButton(
              onPressed: () => context.pop(),
              child: const Text('稍后再说'),
            ),
          ],
        ),
      ),
    );
  }
}

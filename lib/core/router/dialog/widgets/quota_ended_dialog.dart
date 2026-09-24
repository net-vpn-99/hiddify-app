import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/features/panel_auth/data/panel_api.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

enum QuotaEndedAction { invite, purchase, bind, login }

/// 流量用完 / 会员到期 / 没有套餐：居中弹窗，不是首页顶栏报错。
///
/// 1.1.28 起主按钮统一是**去买套餐**：游客现在不绑邮箱也能下单（GslGuest 1.1.0），
/// 绑定也不再送时长，没理由再把「绑定邮箱」摆在到期用户面前挡路。绑定退回成「我的」页
/// 上的一条提醒（换手机 / 电脑上也能用同一个套餐）。
class QuotaEndedDialog extends ConsumerWidget {
  const QuotaEndedDialog({super.key, required this.account});

  final PanelAccount account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final slug = account.stateSlug;
    final bonus = ref.watch(inviteTextsProvider).valueOrNull?.bonus;
    final bonusBit = (bonus != null && bonus.isNotEmpty) ? '双方各得 $bonus' : '双方都能再获得体验';
    final isGuest = ref.watch(panelAuthProvider).isGuest && slug != 'no_plan';

    final (title, body) = isGuest
        ? ('免费试用已结束', '买个套餐就能接着用，不用先注册。')
        : switch (slug) {
            'traffic_exhausted' => ('本期流量已用完', '续费或升级套餐后继续用。也可以邀请好友，$bonusBit。'),
            'expired' => ('会员已到期', '续费后就能接着用。也可以邀请好友，$bonusBit。'),
            _ => ('还没有套餐', '选一个套餐就能开始用。'),
          };
    final showInvite = slug != 'no_plan';

    return Dialog(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(
              slug == 'traffic_exhausted' ? Icons.data_usage_outlined : Icons.event_busy_outlined,
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
            FilledButton(
              onPressed: () => context.pop(QuotaEndedAction.purchase),
              child: Text(slug == 'no_plan' || isGuest ? '去买套餐' : '去续费'),
            ),
            if (showInvite) ...[
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () => context.pop(QuotaEndedAction.invite),
                child: Text(isGuest ? '邀请好友' : '邀请好友试用'),
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

/// 这台设备连账号都还没有（游客没开成：名额满了 / 后台关了 / 这台手机登录过正式账号）。
/// 点连接或点线路时弹它，给两条路：登录，或者去看套餐。
class NeedAccountDialog extends StatelessWidget {
  const NeedAccountDialog({super.key, this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(Icons.vpn_key_outlined, size: 36, color: theme.colorScheme.primary),
            const SizedBox(height: 12),
            Text(
              '还差一步就能连',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 10),
            Text(
              message ?? '登录已有账号，或者买个套餐就能用。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () => context.pop(QuotaEndedAction.login),
              child: const Text('登录账号'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => context.pop(QuotaEndedAction.purchase),
              child: const Text('看看套餐'),
            ),
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

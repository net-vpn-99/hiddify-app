import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 「我的」页顶部的账号卡（1.1.28 重做，原来是一行 ListTile）。
///
/// 一整块里放三样东西：我是谁 + 还剩多久 / 买套餐和我的订单两个按钮 / 游客没绑邮箱时
/// 的提醒条。原来这页最大的问题是**没有买套餐的入口** —— 想付钱找不到地方。
class AccountCard extends ConsumerWidget {
  const AccountCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final loggedIn = ref.watch(Preferences.panelLoggedIn);
    final auth = ref.watch(panelAuthProvider);

    final String title;
    final String subtitle;
    if (!loggedIn) {
      title = '还没有账号';
      subtitle = '登录已有账号，或直接买套餐开始用';
    } else if (auth.isGuest) {
      title = '游客用户';
      subtitle = _planLine(ref, auth);
    } else {
      title = auth.email ?? '已登录';
      subtitle = _planLine(ref, auth);
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: () => context.pushNamed(loggedIn ? 'account' : 'login'),
              child: Row(
                children: [
                  CircleAvatar(
                    backgroundColor: theme.colorScheme.primaryContainer,
                    child: Icon(
                      loggedIn ? Icons.person_rounded : Icons.person_outline_rounded,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded, color: theme.colorScheme.outline),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: () => context.pushNamed('purchase'),
                    child: Text(auth.account?.stateSlug == 'ok' && !auth.isGuest ? '续费 / 升级' : '买套餐'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => context.pushNamed(loggedIn ? 'account' : 'login'),
                    child: Text(loggedIn ? '账号管理' : '登录'),
                  ),
                ),
              ],
            ),
            // 游客没绑邮箱：常驻提醒。这个号只认这台手机的设备号，换手机 / 恢复出厂
            // 就找不回来了，电脑上也是另一个号 —— 绑定不再送时长，只能把利害说清楚。
            if (loggedIn && auth.isGuest) ...[
              const SizedBox(height: 12),
              Material(
                color: theme.colorScheme.tertiaryContainer,
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => context.pushNamed('bindEmail'),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    child: Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(color: theme.colorScheme.error, shape: BoxShape.circle),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '还没绑邮箱，换手机会丢账号',
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: theme.colorScheme.onTertiaryContainer),
                          ),
                        ),
                        Text(
                          '去绑定',
                          style: theme.textTheme.labelMedium
                              ?.copyWith(color: theme.colorScheme.onTertiaryContainer),
                        ),
                        Icon(Icons.chevron_right_rounded,
                            size: 18, color: theme.colorScheme.onTertiaryContainer),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 副标题：套餐状态 + 还剩多久，口径和首页状态条一致。
  String _planLine(WidgetRef ref, PanelAuthState auth) {
    final acc = auth.account;
    if (acc == null) return '正在读取账号…';
    switch (acc.stateSlug) {
      case 'traffic_exhausted':
        return '流量已用完';
      case 'expired':
        return auth.isGuest ? '免费试用已结束' : '会员已到期';
      case 'no_plan':
        return '还没有套餐';
      default:
        final who = auth.isGuest ? '免费试用中' : '会员';
        if (acc.lifetime) return who;
        final secs = acc.expiredAt! - DateTime.now().millisecondsSinceEpoch ~/ 1000;
        if (secs <= 0) return who;
        if (secs >= 86400) return '$who · 剩 ${secs ~/ 86400} 天';
        if (secs >= 3600) return '$who · 剩 ${secs ~/ 3600} 小时';
        return '$who · 剩 ${(secs ~/ 60).clamp(1, 59)} 分钟';
    }
  }
}

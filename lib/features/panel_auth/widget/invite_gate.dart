import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// 打开邀请页 —— 游客先绑邮箱。
///
/// 邀请是**账号功能**：奖励要记在账号上（好友注册并完成邮箱验证后双方到账），
/// 返利也得结给一个账号。游客号只认这台手机的设备号，没邮箱的话奖励换手机就带不走、
/// 返利也没法结 —— 让他先把号变成自己的，再谈邀请。
///
/// 所有入口（「我的」页的「邀请返利」、到期弹窗的第二个按钮）都走这里，别各写各的。
/// 绑定成功直接进邀请页，不用用户再点一次。
Future<void> openInvite(BuildContext context, {required bool isGuest, String? bonus}) async {
  if (!isGuest) {
    context.pushNamed('invite');
    return;
  }
  // 文案只讲「绑了能得到什么」，一条一行。原来这里是一段口语解释（奖励记在账号上、
  // 只认这台手机、跑不掉…），用户看完的评价是「像没读过书的人说的话」。
  final reward = (bonus != null && bonus.isNotEmpty) ? bonus : '1 天不限流量';
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      final style = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.35);
      Widget line(String text) => Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.check_rounded, size: 16, color: theme.colorScheme.primary),
                const SizedBox(width: 6),
                Expanded(child: Text(text, style: style)),
              ],
            ),
          );
      return AlertDialog(
        title: const Text('邀请好友一起使用'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            line('双方各得 $reward'),
            line('可登录多台设备使用'),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('以后再说')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('绑定邮箱')),
        ],
      );
    },
  );
  if (go != true || !context.mounted) return;
  final bound = await context.pushNamed<bool>('bindEmail');
  if (bound == true && context.mounted) context.pushNamed('invite');
}

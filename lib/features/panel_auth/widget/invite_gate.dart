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
  final reward = (bonus != null && bonus.isNotEmpty) ? '各得 $bonus' : '双方都有奖励';
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('邀请好友要先绑定邮箱'),
      content: Text(
        '好友通过你的链接注册、完成邮箱验证后，你和好友$reward。\n\n'
        '这些奖励要记在账号上。你现在用的是免注册试用，只认这台手机 —— '
        '留个邮箱，奖励和返利才跑不掉，换手机、换电脑也还是同一个号。',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('以后再说')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('去绑定邮箱')),
      ],
    ),
  );
  if (go != true || !context.mounted) return;
  final bound = await context.pushNamed<bool>('bindEmail');
  if (bound == true && context.mounted) context.pushNamed('invite');
}

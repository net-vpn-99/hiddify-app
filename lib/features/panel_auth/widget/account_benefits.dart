import 'package:flutter/material.dart';

/// 绑定邮箱 / 注册账号换来的东西 —— **全 App 只有这一份说法**。
///
/// 以前每个劝绑定的地方都自己写一段口语解释（「这个号只认这台手机，留个邮箱，奖励和
/// 返利才跑不掉…」），用户的评价是「像没读过书的人说的话」。改成清单：先说绑了能得到
/// 什么，一条一行，不解释机制。
/// [inviteFirst]：从邀请入口进来的，把邀请那条放第一行（他就是为这个来的）。
List<String> accountBenefits({String? inviteBonus, bool inviteFirst = false}) {
  final invite = (inviteBonus != null && inviteBonus.isNotEmpty)
      ? '可以邀请好友，双方各得 $inviteBonus'
      : '可以邀请好友，双方都有奖励';
  const rest = ['换手机、换电脑，都是同一个账号', '套餐和剩余时间不会丢'];
  return inviteFirst ? [invite, ...rest] : [...rest, invite];
}

/// 权益清单（每行一个 ✓）。[lead] 是清单上面那句引导语。
class AccountBenefitList extends StatelessWidget {
  const AccountBenefitList({
    super.key,
    this.lead = '注册后：',
    this.inviteBonus,
    this.inviteFirst = false,
    this.color,
  });

  final String lead;
  final String? inviteBonus;
  final bool inviteFirst;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = color ?? theme.colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(lead, style: theme.textTheme.bodyMedium?.copyWith(color: c)),
        const SizedBox(height: 8),
        for (final b in accountBenefits(inviteBonus: inviteBonus, inviteFirst: inviteFirst))
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.check_rounded, size: 16, color: theme.colorScheme.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(b, style: theme.textTheme.bodyMedium?.copyWith(color: c, height: 1.3)),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

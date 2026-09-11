import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 「我的」页里的「邀请好友」入口。奖励额度文案从服务器（guest/comm/config）读；
/// 拿不到就显示「查看邀请奖励」，点进去看规则和记录。
class InviteRewardTile extends ConsumerWidget {
  const InviteRewardTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loggedIn = ref.watch(Preferences.panelLoggedIn);
    if (!loggedIn) return const SizedBox.shrink();

    final bonus = ref.watch(inviteTextsProvider).valueOrNull?.bonus;
    final exhausted = ref.watch(panelAuthProvider.select((s) => s.account?.exhausted ?? false));
    final subtitle = exhausted
        ? (bonus != null && bonus.isNotEmpty
            ? '邀请好友，双方再得 $bonus'
            : '邀请好友，双方都能再获得体验')
        : (bonus != null && bonus.isNotEmpty
            ? '邀请好友注册，双方各得 $bonus'
            : '查看邀请奖励');

    return Material(
      child: ListTile(
        leading: const Icon(Icons.card_giftcard_outlined),
        title: const Text('邀请好友'),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => context.pushNamed('invite'),
      ),
    );
  }
}

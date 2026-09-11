import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 设置页顶部的「账号」栏。
class AccountTile extends ConsumerWidget {
  const AccountTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loggedIn = ref.watch(Preferences.panelLoggedIn);
    final auth = ref.watch(panelAuthProvider);

    if (!loggedIn) {
      return Material(
        child: ListTile(
          leading: const Icon(Icons.person_outline),
          title: const Text('登录光速账号'),
          subtitle: const Text('用邮箱密码登录，自动导入订阅'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.pushNamed('login'),
        ),
      );
    }

    return Material(
      child: ListTile(
        leading: const Icon(Icons.account_circle),
        title: Text(auth.email ?? '已登录'),
        subtitle: Text(switch (auth.account?.stateSlug) {
          'traffic_exhausted' => '本期流量已用完 · 点击处理',
          'expired' => '会员已到期 · 点击处理',
          'no_plan' => '还没有套餐 · 点击开通',
          _ => '光速会员 · 点击查看套餐 / 续费',
        }),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => context.pushNamed('account'),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 设置页顶部的「账号」栏。
class AccountTile extends ConsumerWidget {
  const AccountTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loggedIn = ref.watch(Preferences.panelLoggedIn);
    final auth = ref.watch(panelAuthProvider);
    final theme = Theme.of(context);

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
        subtitle: const Text('光速会员'),
        trailing: TextButton(
          onPressed: () async {
            final ok = await ref.read(dialogNotifierProvider.notifier).showConfirmation(
                  title: '退出登录',
                  message: '退出后需要重新登录才能拉取订阅。已导入的订阅不会被删除。',
                );
            if (!ok) return;
            await ref.read(panelAuthProvider.notifier).logout();
          },
          child: Text('退出登录', style: TextStyle(color: theme.colorScheme.error)),
        ),
      ),
    );
  }
}

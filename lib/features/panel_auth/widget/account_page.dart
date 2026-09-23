import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/features/panel_auth/data/panel_api.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class AccountPage extends HookConsumerWidget {
  const AccountPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final auth = ref.watch(panelAuthProvider);
    final account = useState<PanelAccount?>(null);
    final loading = useState(true);

    Future<void> load() async {
      loading.value = true;
      account.value = await ref.read(panelAuthProvider.notifier).fetchAccount();
      loading.value = false;
    }

    useEffect(() {
      load();
      return null;
    }, const []);

    final a = account.value;

    return Scaffold(
      appBar: AppBar(title: const Text('会员中心')),
      body: RefreshIndicator(
        onRefresh: load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                const Icon(Icons.account_circle, size: 44),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        auth.isGuest ? '游客' : (a?.email ?? auth.email ?? '已登录'),
                        style: theme.textTheme.titleMedium,
                      ),
                      Text(auth.isGuest ? '还没绑定邮箱，换手机前记得绑定' : '光速雷达会员', style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            if (loading.value)
              const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
            else if (a == null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text('拉取账号信息失败，下拉刷新重试', style: theme.textTheme.bodyMedium),
                ),
              )
            else
              Card(
                child: Column(
                  children: [
                    _row('当前套餐', a.planName ?? '—'),
                    const Divider(height: 1),
                    _row('剩余时间', a.lifetime ? '长期有效' : _fmtDate(a.expiredAt!)),
                    const Divider(height: 1),
                    _row(
                      '剩余流量',
                      !a.unlimitedQuota
                          ? '还剩 ${_gb(a.remainingBytes)}（共 ${_gb(a.transferEnable)}）'
                          : '不限',
                    ),
                    if (a.deviceLimit > 0) ...[
                      const Divider(height: 1),
                      _row('设备数上限', '${a.deviceLimit} 台'),
                    ],
                  ],
                ),
              ),
            const SizedBox(height: 20),
            if (a?.exhausted == true) ...[
              FilledButton.icon(
                icon: const Icon(Icons.group_add_outlined),
                label: const Text('邀请好友试用'),
                onPressed: () => context.pushNamed('invite'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.card_membership),
                label: const Text('续费 / 升级套餐'),
                onPressed: () => context.pushNamed('purchase'),
              ),
            ] else ...[
              FilledButton.icon(
                icon: const Icon(Icons.card_membership),
                label: const Text('续费 / 升级套餐'),
                onPressed: () => context.pushNamed('purchase'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.group_add_outlined),
                label: const Text('邀请好友'),
                onPressed: () => context.pushNamed('invite'),
              ),
            ],
            const SizedBox(height: 8),
            // 游客没有密码可改：换成「绑定邮箱」。1.1.28 起绑定不再送时长，卖点改成说
            // 实话的那两条 —— 换手机能找回、电脑上也能用同一个套餐。
            if (auth.isGuest)
              FilledButton.tonalIcon(
                icon: const Icon(Icons.mark_email_read_outlined),
                label: const Text('绑定邮箱，换手机和电脑也能用'),
                onPressed: () async {
                  final bound = await context.pushNamed<bool>('bindEmail');
                  if (bound == true) await load();
                },
              )
            else
            OutlinedButton.icon(
              icon: const Icon(Icons.password_outlined),
              label: const Text('修改密码'),
              onPressed: () {
                final mail = a?.email ?? auth.email;
                context.pushNamed(
                  'resetPassword',
                  queryParameters: {if (mail != null && mail.isNotEmpty) 'email': mail},
                );
              },
            ),
            const SizedBox(height: 24),
            TextButton(
              onPressed: () async {
                final ok = await ref.read(dialogNotifierProvider.notifier).showConfirmation(
                      title: auth.isGuest ? '用已有账号登录' : '退出登录',
                      message: auth.isGuest
                          ? '会回到登录页，用你的邮箱和密码登录。点错了也没关系，登录页点「免注册，直接试用」还能回到现在这个试用。'
                          : '退出后会断开连接、清除已导入的订阅，需要重新登录才能继续使用。',
                    );
                if (!ok) return;
                await ref.read(panelAuthProvider.notifier).logout();
                if (context.mounted) context.go('/login');
              },
              child: Text(auth.isGuest ? '已有账号？去登录' : '退出登录',
                  style: TextStyle(color: theme.colorScheme.error)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String k, String v) => ListTile(
        dense: true,
        title: Text(k),
        trailing: Text(v, style: const TextStyle(fontWeight: FontWeight.w600)),
      );

  static String _gb(int bytes) => '${(bytes / 1073741824).toStringAsFixed(bytes >= 1073741824 ? 1 : 2)} GB';

  static String _fmtDate(int unixSec) {
    final d = DateTime.fromMillisecondsSinceEpoch(unixSec * 1000);
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }
}

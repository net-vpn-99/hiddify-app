import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/features/panel_auth/data/panel_api.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hiddify/utils/uri_utils.dart';
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
                        a?.email ?? auth.email ?? '已登录',
                        style: theme.textTheme.titleMedium,
                      ),
                      Text('光速会员', style: theme.textTheme.bodySmall),
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
                      a.transferEnable > 0
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
            FilledButton.icon(
              icon: const Icon(Icons.card_membership),
              label: const Text('续费 / 升级套餐'),
              onPressed: () => UriUtils.tryLaunch(Uri.parse(Constants.panelPlanUrl)),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.group_add_outlined),
              label: const Text('邀请好友'),
              onPressed: () => context.pushNamed('invite'),
            ),
            const SizedBox(height: 8),
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
                      title: '退出登录',
                      message: '退出后会断开连接、清除已导入的订阅，需要重新登录才能继续使用。',
                    );
                if (!ok) return;
                await ref.read(panelAuthProvider.notifier).logout();
                if (context.mounted) context.go('/login');
              },
              child: Text('退出登录', style: TextStyle(color: theme.colorScheme.error)),
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

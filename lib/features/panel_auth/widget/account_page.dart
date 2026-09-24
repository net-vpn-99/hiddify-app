import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/features/panel_auth/data/panel_api.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hiddify/features/panel_auth/widget/account_key_dialog.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class AccountPage extends HookConsumerWidget {
  const AccountPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final auth = ref.watch(panelAuthProvider);
    final account = useState<PanelAccount?>(null);
    final loading = useState(true);
    // 服务端支持「不留邮箱也有一把自己的钥匙」时才显示那一格（老服务端拿不到 → 不显示）。
    final guestOpts = ref.watch(guestOptionsProvider).valueOrNull;
    final keySaved = ref.watch(Preferences.guestKeySaved);

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
      appBar: AppBar(title: const Text('账号')),
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
                        auth.accountLabel,
                        style: theme.textTheme.titleMedium,
                      ),
                      Text(auth.isGuest ? '还没注册，换手机前记得注册' : '光速雷达会员', style: theme.textTheme.bodySmall),
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
                    // 账号编号：所有人都有，报给客服就能查到人（没注册的号没有邮箱，
                    // 原来根本报不出任何东西）。它是 uuid 派生的，不是订阅令牌，给人看没风险。
                    if (auth.accountNo != null) ...[
                      ListTile(
                        dense: true,
                        title: const Text('账号编号'),
                        subtitle: Text(auth.isGuest
                            ? '点一下复制。报给客服能查到你'
                            : '登录时可以用它代替邮箱 · 点一下复制'),
                        trailing: Text(auth.accountNo!,
                            style: const TextStyle(fontWeight: FontWeight.w600, letterSpacing: 1)),
                        onTap: () async {
                          await Clipboard.setData(ClipboardData(text: auth.accountNo!));
                          if (!context.mounted) return;
                          ScaffoldMessenger.maybeOf(context)
                              ?.showSnackBar(const SnackBar(content: Text('账号编号已复制')));
                        },
                      ),
                      const Divider(height: 1),
                    ],
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
            // 这页只做「账号本身」的事：看详情、绑邮箱 / 改密码、退出。买套餐和邀请在
            // 「我的」页和首页都有入口，这里再摆一遍只会让人分不清两页各管什么。
            FilledButton.icon(
              icon: const Icon(Icons.card_membership),
              label: Text(a?.exhausted == true ? '去买套餐' : '续费 / 升级套餐'),
              onPressed: () => context.pushNamed('purchase'),
            ),
            const SizedBox(height: 8),
            // 钥匙（账号编号 + 密码）。免注册的号才有，而且只在服务端发得出密码时才有。
            //   - 还没抄走 → 强调色，点开是「记下这两样」
            //   - 抄走了   → 平常样子，点开是「设置密码」（换成自己记得住的）
            if (auth.isGuest && (guestOpts?.selfPassword ?? false)) ...[
              if (!keySaved && auth.guestPassword != null)
                FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                    backgroundColor: theme.colorScheme.errorContainer,
                    foregroundColor: theme.colorScheme.onErrorContainer,
                  ),
                  icon: const Icon(Icons.key_outlined),
                  label: const Text('还没记下账号和密码，点这里'),
                  onPressed: () => showAccountKeyDialog(context, ref),
                )
              else
                OutlinedButton.icon(
                  icon: const Icon(Icons.password_outlined),
                  label: const Text('设置密码（换手机时用）'),
                  onPressed: () => showSetGuestPasswordDialog(context, ref),
                ),
              const SizedBox(height: 8),
            ],
            // 游客没有密码可改：换成「绑定邮箱」。1.1.28 起绑定不再送时长，卖点改成说
            // 实话的那两条 —— 换手机能找回、电脑上也能用同一个套餐。
            if (auth.isGuest)
              FilledButton.tonalIcon(
                icon: const Icon(Icons.mark_email_read_outlined),
                label: const Text('注册账号，换手机和电脑也能用'),
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
                // 游客去登录：**不能先退出**。1.1.31 及以前是 logout + go('/login')——
                // 订阅先被删、连接先被断，人还被扔到一个返回不了的登录页（栈被 go 清了），
                // 用户的原话是「好像变成了两个 App，只能杀掉重开」。
                // 正确顺序是「先登上，再换过去」：push 登录页，登录成功那一刻才换账号
                // （订阅按 ID 原地替换），中途退回来还是原来的游客状态，什么都没丢。
                if (auth.isGuest) {
                  await context.pushNamed('login');
                  return;
                }
                final ok = await ref.read(dialogNotifierProvider.notifier).showConfirmation(
                      title: '退出登录',
                      message: '退出后会断开连接、清除已导入的订阅，需要重新登录才能继续使用。',
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

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
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
    final tick = useState(0);
    final secsLeft = (a == null || a.lifetime || a.expiredAt == null)
        ? 1 << 30
        : a.expiredAt! - DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final short = secsLeft > 0 && secsLeft < 86400;
    useEffect(() {
      if (!short) return null;
      final timer = Timer.periodic(const Duration(minutes: 1), (_) => tick.value++);
      return timer.cancel;
    }, [short]);
    final now = DateTime.now().add(Duration(microseconds: tick.value));

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
                      Text(auth.isGuest ? '免注册账号 · 在别的设备上用配对码登录' : '光速雷达会员', style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
              ],
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('在另一台设备上用'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.pushNamed('addDevice'),
            ),
            if (auth.isGuest) ...[
              const Text('防丢', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              const Text('加个邮箱：手机丢了、卸载重装也能找回这个账号。'),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () async {
                  final bound = await context.pushNamed<bool>('bindEmail');
                  if (bound == true) await load();
                },
                child: const Text('加邮箱'),
              ),
            ],
            const SizedBox(height: 12),
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
                    _row('剩余时间', _remainLabel(a, now)),
                    if (a.dailyKnown) ...[
                      const Divider(height: 1),
                      ListTile(
                        dense: true,
                        title: const Text('今日高速'),
                        subtitle: Text(
                          a.dailyThrottled
                              ? '已用完，现在限速 ${a.dailyThrottleMbps}Mbps，0 点恢复'
                              : '还剩 ${formatDailyAmount((a.dailyQuota - a.dailyUsed).clamp(0, 1 << 62))}（每天 ${formatDailyAmount(a.dailyQuota)}，0 点重置）',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: a.dailyThrottled ? theme.colorScheme.error : null,
                          ),
                        ),
                      ),
                    ],
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
            // 推荐码不放首页。首页是连接，这行只在账号页，填过就消失。
            if (auth.isGuest && !ref.watch(Preferences.inviteAttached))
              TextButton(
                onPressed: () => _askInviteCode(context, ref),
                child: const Text('有朋友的推荐码？填一下'),
              ),
            if (!auth.isGuest)
            OutlinedButton.icon(
              icon: const Icon(Icons.password_outlined),
              label: const Text('找回密码'),
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
              onPressed: () => context.pushNamed('login'),
              // 有邮箱的号也只是去登录页，不退出。关掉登录页就还是现在这个号。
              child: Text(auth.isGuest ? '已有账号？去登录' : '换个账号登录'),
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

  static Future<void> _askInviteCode(BuildContext context, WidgetRef ref) async {
    final field = TextEditingController();
    final error = ValueNotifier<String?>(null);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('填写推荐码'),
        content: ValueListenableBuilder<String?>(
          valueListenable: error,
          builder: (_, msg, __) => TextField(
            controller: field,
            autofocus: true,
            decoration: InputDecoration(
              hintText: '朋友发给你的那一串',
              errorText: msg,
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('记下')),
        ],
      ),
    );
    if (ok != true) {
      field.dispose();
      error.dispose();
      return;
    }
    final msg = await ref.read(panelAuthProvider.notifier).applyInviteCode(field.text);
    field.dispose();
    error.dispose();
    if (!context.mounted) return;
    if (msg != null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(msg)));
      return;
    }
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('推荐码已记下')));
  }

  static String _remainLabel(PanelAccount a, DateTime now) {
    if (a.lifetime) return '长期有效';
    final secs = a.expiredAt! - now.millisecondsSinceEpoch ~/ 1000;
    if (secs > 0 && secs < 86400) return '剩 ${a.remainingClock(now)}';
    return _fmtDate(a.expiredAt!);
  }

  static String _fmtDate(int unixSec) {
    final d = DateTime.fromMillisecondsSinceEpoch(unixSec * 1000);
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }
}

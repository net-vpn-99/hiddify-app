import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hiddify/features/panel_auth/model/invite_referral.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

class InvitePage extends HookConsumerWidget {
  const InvitePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final invite = useState<({String code, String link})?>(null);
    final loading = useState(true);
    final referrals = useState<List<InviteReferral>>(const []);
    final total = useState(0);
    final page = useState(1);
    final loadingMore = useState(false);

    final texts = ref.watch(inviteTextsProvider).valueOrNull;
    final bonus = texts?.bonus;
    final rewardDesc = bonus != null
        ? '好友用你的链接注册、完成邮箱验证后，你和好友各自到账 $bonus。好友之后购买套餐，你还能拿返利。'
        : '好友用你的链接注册、完成邮箱验证后，你和好友都能获得赠送的流量和时长。好友之后购买套餐，你还能拿返利。';

    Future<void> loadReferrals(int p) async {
      final res = await ref.read(panelAuthProvider.notifier).getReferrals(page: p);
      if (res == null) return;
      referrals.value = p == 1 ? res.items : [...referrals.value, ...res.items];
      total.value = res.total;
      page.value = p;
    }

    useEffect(() {
      () async {
        invite.value = await ref.read(panelAuthProvider.notifier).getInvite();
        await loadReferrals(1);
        loading.value = false;
      }();
      return null;
    }, const []);

    final d = invite.value;
    final shareText = d == null
        ? ''
        : _buildShareText(texts?.share, bonus, d.link);

    return Scaffold(
      appBar: AppBar(title: const Text('邀请好友')),
      body: loading.value
          ? const Center(child: CircularProgressIndicator())
          : d == null
              ? const Center(child: Text('拉取邀请码失败，返回重试'))
              : ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    Card(
                      color: theme.colorScheme.secondaryContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.card_giftcard, size: 20, color: theme.colorScheme.onSecondaryContainer),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    bonus != null ? '邀请好友，双方各得 $bonus' : '邀请好友，双方都有奖励',
                                    style: theme.textTheme.titleSmall?.copyWith(
                                      color: theme.colorScheme.onSecondaryContainer,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              rewardDesc,
                              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSecondaryContainer),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text('发给好友', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 6),
                    Text(
                      '复制下面这段话，粘贴到微信或 QQ。好友点开就能注册，邀请码会自动带上。',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 10),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: SelectableText(shareText, style: theme.textTheme.bodyMedium?.copyWith(height: 1.45)),
                      ),
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      icon: const Icon(Icons.copy_all_outlined),
                      label: const Text('复制发给好友'),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: shareText));
                        _toast(context, '文案已复制，发给微信或 QQ 好友即可');
                      },
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.share),
                      label: const Text('系统分享'),
                      onPressed: () => Share.share(shareText),
                    ),
                    const SizedBox(height: 4),
                    TextButton.icon(
                      icon: const Icon(Icons.link, size: 18),
                      label: const Text('只复制链接'),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: d.link));
                        _toast(context, '邀请链接已复制');
                      },
                    ),
                    Theme(
                      data: theme.copyWith(dividerColor: Colors.transparent),
                      child: ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        title: Text('当面扫码 / 邀请码', style: theme.textTheme.titleSmall),
                        subtitle: Text(
                          '面对面时再展开。一般不用单独发邀请码，链接里已经带上。',
                          style: theme.textTheme.bodySmall,
                        ),
                        children: [
                          const SizedBox(height: 8),
                          Center(
                            child: Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
                              child: QrImageView(data: d.link, size: 180, backgroundColor: Colors.white),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Center(
                            child: Column(
                              children: [
                                Text('你的邀请码', style: theme.textTheme.bodySmall),
                                const SizedBox(height: 4),
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    SelectableText(
                                      d.code,
                                      style: theme.textTheme.headlineSmall?.copyWith(
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: 2,
                                      ),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.copy, size: 18),
                                      onPressed: () {
                                        Clipboard.setData(ClipboardData(text: d.code));
                                        _toast(context, '邀请码已复制');
                                      },
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      total.value > 0 ? '邀请记录（${total.value} 人）' : '邀请记录',
                      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    if (referrals.value.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: Text(
                          '还没有人通过你的链接注册。把上面的话发给还没用过光速雷达的朋友～',
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      )
                    else ...[
                      if (referrals.value.any((r) => !r.paid))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            '有好友还没开通套餐。可以把上面的话再发一次，提醒他们体验。',
                            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                          ),
                        ),
                      ...referrals.value.map((r) => _ReferralRow(r)),
                    ],
                    if (referrals.value.length < total.value)
                      TextButton(
                        onPressed: loadingMore.value
                            ? null
                            : () async {
                                loadingMore.value = true;
                                await loadReferrals(page.value + 1);
                                loadingMore.value = false;
                              },
                        child: Text(loadingMore.value ? '加载中…' : '加载更多'),
                      ),
                  ],
                ),
    );
  }

  static String _buildShareText(String? template, String? bonus, String link) {
    if (template != null && template.isNotEmpty) {
      return template.replaceAll('{bonus}', bonus ?? '奖励').replaceAll('{link}', link);
    }
    final b = bonus != null ? '各得 $bonus' : '都有奖励';
    return '我在用「光速」，速度快、YouTube 4K 不卡。\n用我的链接注册，咱俩$b：\n$link';
  }

  static void _toast(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}

class _ReferralRow extends StatelessWidget {
  const _ReferralRow(this.r);

  final InviteReferral r;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final date = DateTime.fromMillisecondsSinceEpoch(r.createdAt * 1000);
    final dateStr = '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.person_outline),
      title: Text(r.emailMask),
      subtitle: Text(r.paid ? '$dateStr · 已付费' : dateStr),
      trailing: r.commissionCents > 0
          ? Text(
              '+¥${r.commissionYuan.toStringAsFixed(2)}',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            )
          : null,
    );
  }
}

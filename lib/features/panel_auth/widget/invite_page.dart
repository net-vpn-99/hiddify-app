import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gal/gal.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/core/theme/oneray_tokens.dart';
import 'package:hiddify/features/panel_auth/data/panel_api.dart';
import 'package:hiddify/features/panel_auth/model/invite_referral.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hiddify/gen/assets.gen.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

/// 邀请好友（10-18 按推广重做，跟 Windows InviteOverlay.qml 同一套）：先说「你能得到什么 + 离下一档还差几个」，
/// 再一颗「复制发给好友」；海报 / 二维码给发朋友圈和当面扫；「我邀请的人」点进去看每位好友到哪一步。
/// 奖励天数、门槛都由服务端（GslInviteBonus）下发，这里只有兜底默认。
class InvitePage extends HookConsumerWidget {
  const InvitePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tk = OneRayTokens.of(context);
    final invite = useState<({String code, String link})?>(null);
    final loading = useState(true);
    final referrals = useState<List<InviteReferral>>(const []);
    final total = useState(0);
    final paidCount = useState(0);
    final page = useState(1);

    final texts = _Texts(ref.watch(inviteTextsProvider).valueOrNull);

    Future<void> loadReferrals(int p) async {
      final res = await ref.read(panelAuthProvider.notifier).getReferrals(page: p);
      if (res == null) return;
      referrals.value = p == 1 ? res.items : [...referrals.value, ...res.items];
      total.value = res.total;
      paidCount.value = res.paidCount;
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
    final shareText = d == null ? '' : texts.shareText(d.link, d.code);
    final goalDone = paidCount.value % texts.goal;

    void openList() => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => _ReferralListPage(
              texts: texts,
              initial: referrals.value,
              total: total.value,
              paidCount: paidCount.value,
              loadMore: () async {
                await loadReferrals(page.value + 1);
                return referrals.value;
              },
            ),
          ),
        );

    return Scaffold(
      backgroundColor: tk.bg,
      appBar: AppBar(title: const Text('邀请好友'), backgroundColor: tk.bg, surfaceTintColor: Colors.transparent),
      body: loading.value
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
              children: [
                // ---- 你能得到什么 ----
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(color: tk.card, borderRadius: BorderRadius.circular(16)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('每邀请 1 位好友「用起来」', style: TextStyle(fontSize: 12, color: tk.sub)),
                      const SizedBox(height: 2),
                      Text(
                        '你和好友各得 ${texts.bonus}',
                        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, letterSpacing: -0.3, color: tk.text),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        texts.paidLines,
                        style: TextStyle(fontSize: 13, height: 1.5, color: tk.text),
                      ),
                      if (d != null) ...[
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Divider(height: 1, color: tk.ring),
                        ),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                goalDone == 0 && paidCount.value > 0
                                    ? '每满 ${texts.goal} 位好友付费，你得到 ${texts.goalText}。已经送过你 ${paidCount.value ~/ texts.goal} 次'
                                    : '再有 ${texts.goal - goalDone} 位好友付费，你得到 ${texts.goalText}',
                                style: TextStyle(fontSize: 12, color: tk.text),
                              ),
                            ),
                            Text(
                              '$goalDone / ${texts.goal}',
                              style: TextStyle(
                                fontFamily: OneRayTokens.numberFont,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: tk.sub,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            for (var i = 0; i < texts.goal; i++) ...[
                              if (i > 0) const SizedBox(width: 6),
                              Expanded(
                                child: Container(
                                  height: 6,
                                  decoration: BoxDecoration(
                                    color: i < goalDone ? tk.ok : tk.ring,
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ],
                  ),
                ),

                // ---- 发给好友：预览只露前 2 行（卖点），复制的是整段 ----
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: tk.card, borderRadius: BorderRadius.circular(12)),
                  child: Text(
                    d == null ? '邀请信息没读出来，请检查网络后重新打开这一页' : shareText,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, height: 1.45, color: d == null ? tk.fault : tk.sub),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  onPressed: d == null
                      ? null
                      : () {
                          Clipboard.setData(ClipboardData(text: shareText));
                          _toast(context, '已复制，去微信或 QQ 粘贴给好友');
                        },
                  child: const Text('复制发给好友'),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _SecondaryButton(
                        label: '海报 / 二维码',
                        onPressed: d == null
                            ? null
                            : () => Navigator.of(context).push(
                                  MaterialPageRoute<void>(builder: (_) => _PosterPage(link: d.link, code: d.code, texts: texts)),
                                ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _SecondaryButton(
                        label: '分享到其他 App',
                        onPressed: d == null ? null : () => Share.share(shareText),
                      ),
                    ),
                  ],
                ),

                // ---- 我邀请的人：一行入口 ----
                const SizedBox(height: 16),
                Material(
                  color: tk.card,
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: d == null || total.value == 0 ? null : openList,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 14, 8, 14),
                      child: Row(
                        children: [
                          Text('我邀请的人', style: TextStyle(fontSize: 15, color: tk.text)),
                          Expanded(
                            child: Text(
                              d == null
                                  ? '—'
                                  : total.value == 0
                                      ? '还没有'
                                      : '${total.value} 人 · 已付费 ${paidCount.value} 人',
                              textAlign: TextAlign.right,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 13, color: tk.sub),
                            ),
                          ),
                          if (d != null && total.value > 0) Icon(Icons.chevron_right_rounded, color: tk.sub),
                        ],
                      ),
                    ),
                  ),
                ),
                if (d != null && total.value == 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text('先发给常一起追剧、用 AI 的朋友，他们最需要。', style: TextStyle(fontSize: 13, color: tk.sub)),
                  ),
                const SizedBox(height: 12),
                Text(
                  '「用起来」指：好友注册后 7 天内，至少有 2 天连上过光速雷达。好友的号和你的号用的是同一台设备时，不算邀请。',
                  style: TextStyle(fontSize: 12, height: 1.45, color: tk.dim),
                ),
                const SizedBox(height: 8),
                Center(
                  child: TextButton(
                    onPressed: () => UriUtils.tryLaunch(Uri.parse('${Constants.websiteUrl}promoter/')),
                    child: Text('想赚更多？成为推广员 ›', style: TextStyle(fontSize: 13, color: tk.sub)),
                  ),
                ),
              ],
            ),
    );
  }
}

/// 服务端文案 + 兜底默认，两端同一套（Windows InviteOverlay.qml）。
class _Texts {
  _Texts(InviteTexts? t)
      : bonus = t?.bonus ?? '3 天会员时长',
        paidBonus = t?.paidBonus ?? '7 天会员时长',
        goalText = t?.goalText ?? '1 个月会员时长',
        goal = t?.goal ?? 3,
        paidMinYuan = t?.paidMinYuan,
        rate = t?.rate,
        share = t?.share;

  final String bonus;
  final String paidBonus;
  final String goalText;
  final int goal;
  final int? paidMinYuan;
  final int? rate;
  final String? share;

  /// 给好友看的不说「会员时长」（他还没用过，不懂），只说天数。
  String get shortBonus => bonus.replaceAll('会员时长', '');

  String get paidLines {
    final when = paidMinYuan != null ? '第一次付款满 ¥$paidMinYuan' : '第一次付费';
    final first = '好友$when：你再得 $paidBonus';
    return rate != null ? '$first\n好友每次付款：你得到付款金额的 $rate% 作为返利' : first;
  }

  /// 给没用过的朋友看的宣传文案：先痛点和卖点；条件（用起来才算）放在页面规则里（运营 10-12 定）。
  String shareText(String link, String code) {
    final s = share;
    if (s != null && s.isNotEmpty) {
      return s.replaceAll('{bonus}', shortBonus).replaceAll('{link}', link).replaceAll('{code}', code);
    }
    return '推荐你用「光速雷达」：ChatGPT、Claude 直接用，YouTube 4K 秒开，晚高峰也不卡。\n'
        '用我的链接下载，免费试用之外，用起来后再送你 $shortBonus：\n$link\n官网打不开时用这个：${Constants.statusPageUrl}';
  }

  /// 好友走到哪一步。服务端给 status；老服务端只有 paid，就退回「已付费 / 已注册」。
  (String, Color) statusOf(InviteReferral r, OneRayTokens tk) {
    final s = r.status.isNotEmpty ? r.status : (r.paid ? 'paid' : 'registered');
    return switch (s) {
      'paid' => ('已付费 · 你得 ${paidBonus.replaceAll('会员时长', '')}', tk.ok),
      'connected' => ('已用起来 · 你们各得 $shortBonus', tk.ok),
      'connected_capped' => ('已用起来 · 好友得 $shortBonus，你本月的奖励已满', tk.sub),
      'same_device' => ('和你同一台设备 · 不算邀请', tk.dim),
      'old_device' => ('设备登过别的账号 · 不算邀请', tk.dim),
      'same_network' => ('和你同一个网络 · 不算邀请', tk.dim),
      'expired' => ('7 天内没用起来 · 不算邀请', tk.dim),
      _ => ('已注册 · 还没用起来', tk.sub),
    };
  }
}

class _SecondaryButton extends StatelessWidget {
  const _SecondaryButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final tk = OneRayTokens.of(context);
    return FilledButton(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(44),
        backgroundColor: tk.card,
        foregroundColor: tk.text,
        disabledBackgroundColor: tk.card,
        disabledForegroundColor: tk.dim,
      ),
      onPressed: onPressed,
      child: Text(label),
    );
  }
}

/// 海报：发朋友圈、发群里用；当面让好友直接扫。按 3 倍存进相册。
class _PosterPage extends HookWidget {
  const _PosterPage({required this.link, required this.code, required this.texts});

  final String link;
  final String code;
  final _Texts texts;

  @override
  Widget build(BuildContext context) {
    final tk = OneRayTokens.of(context);
    final posterKey = useMemoized(GlobalKey.new);
    const ink = Color(0xFF191C2E);
    const inkSub = Color(0xFF646A84);

    Future<void> save() async {
      final boundary = posterKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return;
      try {
        if (!await Gal.hasAccess(toAlbum: true) && !await Gal.requestAccess(toAlbum: true)) {
          if (context.mounted) _toast(context, '没有相册权限，去系统设置里打开');
          return;
        }
        final image = await boundary.toImage(pixelRatio: 3);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        if (bytes == null) throw StateError('png');
        await Gal.putImageBytes(bytes.buffer.asUint8List(), album: '光速雷达');
        if (context.mounted) _toast(context, '海报已保存到相册');
      } on GalException catch (e) {
        if (context.mounted) {
          _toast(context, e.type == GalExceptionType.accessDenied ? '没有相册权限，去系统设置里打开' : '海报没存上，再试一次');
        }
      } catch (_) {
        if (context.mounted) _toast(context, '海报没存上，再试一次');
      }
    }

    return Scaffold(
      backgroundColor: tk.bg,
      appBar: AppBar(title: const Text('海报 / 二维码'), backgroundColor: tk.bg, surfaceTintColor: Colors.transparent),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
        children: [
          Center(
            child: RepaintBoundary(
              key: posterKey,
              child: Container(
                width: 290,
                padding: const EdgeInsets.all(22),
                decoration: BoxDecoration(
                  color: OneRayTokens.paper,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: tk.ring),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Assets.images.brandMarkSmall.svg(width: 26, height: 26),
                        const SizedBox(width: 8),
                        const Text('光速雷达', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: ink)),
                      ],
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'ChatGPT 直接用\nYouTube 4K 秒开',
                      style: TextStyle(fontSize: 22, height: 1.3, fontWeight: FontWeight.w600, color: ink),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '扫码下载光速雷达。免费试用之外，用起来后再送你 ${texts.shortBonus}',
                      style: const TextStyle(fontSize: 12, height: 1.45, color: inkSub),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      '晚高峰不卡 · 不限流量 · 电脑手机都能用',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: ink),
                    ),
                    const SizedBox(height: 18),
                    Center(child: QrImageView(data: link, size: 150, backgroundColor: OneRayTokens.paper)),
                    const SizedBox(height: 12),
                    Center(
                      child: Text('邀请码 $code', style: const TextStyle(fontSize: 12, color: inkSub, fontFamily: 'monospace')),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '保存后发朋友圈或群里；当面时让好友直接扫这个码。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: tk.sub),
          ),
          const SizedBox(height: 20),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: save,
            child: const Text('保存海报到相册'),
          ),
        ],
      ),
    );
  }
}

/// 我邀请的人（全部）：每位好友走到哪一步。
class _ReferralListPage extends HookWidget {
  const _ReferralListPage({
    required this.texts,
    required this.initial,
    required this.total,
    required this.paidCount,
    required this.loadMore,
  });

  final _Texts texts;
  final List<InviteReferral> initial;
  final int total;
  final int paidCount;
  final Future<List<InviteReferral>> Function() loadMore;

  @override
  Widget build(BuildContext context) {
    final tk = OneRayTokens.of(context);
    final rows = useState(initial);
    final busy = useState(false);
    return Scaffold(
      backgroundColor: tk.bg,
      appBar: AppBar(title: const Text('我邀请的人'), backgroundColor: tk.bg, surfaceTintColor: Colors.transparent),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
        children: [
          Text('已邀请 $total 人 · 已付费 $paidCount 人', style: TextStyle(fontSize: 13, color: tk.sub)),
          const SizedBox(height: 6),
          for (final r in rows.value) _ReferralRow(r, texts),
          if (rows.value.length < total)
            TextButton(
              onPressed: busy.value
                  ? null
                  : () async {
                      busy.value = true;
                      rows.value = await loadMore();
                      busy.value = false;
                    },
              child: Text(busy.value ? '加载中…' : '加载更多'),
            ),
        ],
      ),
    );
  }
}

class _ReferralRow extends StatelessWidget {
  const _ReferralRow(this.r, this.texts);

  final InviteReferral r;
  final _Texts texts;

  @override
  Widget build(BuildContext context) {
    final tk = OneRayTokens.of(context);
    final date = DateTime.fromMillisecondsSinceEpoch(r.createdAt * 1000);
    final dateStr = '${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    final (status, color) = texts.statusOf(r, tk);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: tk.ring.withValues(alpha: 0.6)))),
      child: Row(
        children: [
          Expanded(
            flex: 4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(r.emailMask, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: tk.text)),
                Text(dateStr, style: TextStyle(fontFamily: OneRayTokens.numberFont, fontSize: 11, color: tk.dim)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 6,
            child: Text(status, textAlign: TextAlign.right, style: TextStyle(fontSize: 12, color: color)),
          ),
        ],
      ),
    );
  }
}

void _toast(BuildContext context, String msg) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
}

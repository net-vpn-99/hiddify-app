import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/panel_auth/data/panel_api.dart';
import 'package:hiddify/features/panel_auth/notifier/guest_bootstrap.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 首页最下面那条状态条：一眼知道自己是什么身份、还剩多久、下一步点哪。
///
/// 文案按用户真实状态说人话（运营定的口径）：
///   免费试用中 · 剩 11 小时 / 全速版 · 剩 28 天 / 全速版 · 长期有效 /
///   免费试用已结束 · 买套餐继续用 / 会员已到期 · 去续费 / 流量已用完 · 去续费 /
///   还没有套餐 · 去看看
/// 点哪都是去购买页 —— 只有「这台手机登录过账号」那种情况去登录页。
///
/// 颜色也是口径的一部分：**正常会员用低调灰**（_Tone.plain）。付过钱、还没到期
/// 的人不需要每次开 App 都被一条高亮条提醒「有事要办」。黄（good）只留给还在
/// 试用、该转化的游客，橙（warn）只留给真出事了 —— 到期 / 流量用完。
class AccountStatusBar extends ConsumerWidget {
  const AccountStatusBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final auth = ref.watch(panelAuthProvider);
    final boot = ref.watch(guestBootstrapProvider);
    final loggedIn = ref.watch(Preferences.panelLoggedIn);

    final (text, action, tone, route) = _describe(auth, boot, loggedIn);

    final Color bg;
    final Color fg;
    switch (tone) {
      case _Tone.good:
        bg = theme.colorScheme.primaryContainer;
        fg = theme.colorScheme.onPrimaryContainer;
      case _Tone.warn:
        bg = theme.colorScheme.tertiaryContainer;
        fg = theme.colorScheme.onTertiaryContainer;
      case _Tone.plain:
        bg = theme.colorScheme.surfaceContainerHighest;
        fg = theme.colorScheme.onSurfaceVariant;
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => context.pushNamed(route),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(color: fg),
                  ),
                ),
                const SizedBox(width: 8),
                Text(action, style: theme.textTheme.labelMedium?.copyWith(color: fg)),
                Icon(Icons.chevron_right_rounded, size: 18, color: fg),
              ],
            ),
          ),
        ),
      ),
    );
  }

  (String, String, _Tone, String) _describe(
    PanelAuthState auth,
    GuestBootstrapState boot,
    bool loggedIn,
  ) {
    if (!loggedIn) {
      if (boot.working) return ('正在开通免费试用…', '', _Tone.plain, 'purchase');
      if (boot.reason == GuestBlockReason.hasAccount) {
        return (boot.message ?? '这台手机登录过账号', '去登录', _Tone.warn, 'login');
      }
      return (boot.message ?? '还没开通，先看看套餐', '看套餐', _Tone.plain, 'purchase');
    }

    final acc = auth.account;
    if (acc == null) return ('正在读取账号…', '', _Tone.plain, 'purchase');

    final guest = auth.isGuest;
    switch (acc.stateSlug) {
      case 'traffic_exhausted':
        return ('流量已用完', '去续费', _Tone.warn, 'purchase');
      case 'expired':
        return guest
            ? ('免费试用已结束 · 买套餐继续用', '去买', _Tone.warn, 'purchase')
            : ('会员已到期', '去续费', _Tone.warn, 'purchase');
      case 'no_plan':
        return ('还没有套餐', '去看看', _Tone.plain, 'purchase');
      default:
        if (guest) {
          final left = _remaining(acc);
          return (left == null ? '免费试用中' : '免费试用中 · 剩 $left', '看套餐', _Tone.good, 'purchase');
        }
        // 会员：报套餐名，且第二段（长期有效 / 剩多久）一定要有。
        // 以前长期有效的号算不出剩余时长，整条就只剩「会员」两个字 + 右边「看套餐」，
        // 被读成「去开通会员」的广告 —— 分不清是在说我的状态还是在推销。
        final name = acc.planName?.trim().isNotEmpty == true ? acc.planName!.trim() : '会员';
        if (acc.lifetime) return ('$name · 长期有效', '我的套餐', _Tone.plain, 'purchase');
        final left = _remaining(acc);
        return (left == null ? name : '$name · 剩 $left', '续费', _Tone.plain, 'purchase');
    }
  }

  /// 剩余时长，说人话：超过一天说天，不足一天说小时，不足一小时说分钟。
  /// 长期有效（expiredAt 为空）返回 null。
  String? _remaining(PanelAccount acc) {
    if (acc.lifetime) return null;
    final secs = acc.expiredAt! - DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (secs <= 0) return null;
    if (secs >= 86400) return '${secs ~/ 86400} 天';
    if (secs >= 3600) return '${secs ~/ 3600} 小时';
    return '${(secs ~/ 60).clamp(1, 59)} 分钟';
  }
}

enum _Tone { good, warn, plain }

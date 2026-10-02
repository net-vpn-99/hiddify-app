import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/panel_auth/data/panel_api.dart';
import 'package:hiddify/features/panel_auth/notifier/guest_bootstrap.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hiddify/features/proxy/line/line_tier.dart';
import 'package:hiddify/features/purchase/notifier/purchase_notifier.dart';
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
class AccountStatusBar extends HookConsumerWidget {
  const AccountStatusBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final auth = ref.watch(panelAuthProvider);
    final boot = ref.watch(guestBootstrapProvider);
    final loggedIn = ref.watch(Preferences.panelLoggedIn);
    final tick = useState(0);
    final acc = auth.account;
    final secsLeft = (acc == null || acc.lifetime || acc.expiredAt == null)
        ? 1 << 30
        : acc.expiredAt! - DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final short = secsLeft > 0 && secsLeft < 86400;
    useEffect(() {
      if (!short) return null;
      final timer = Timer.periodic(const Duration(minutes: 1), (_) => tick.value++);
      return timer.cancel;
    }, [short]);
    final now = DateTime.now().add(Duration(microseconds: tick.value));
    final tier = ref.watch(lineTierProvider);
    final connected = ref.watch(connectionNotifierProvider).valueOrNull?.isConnected ?? false;

    final (text, action, tone, route) = tier.trialEnded && !connected
        ? ('优化线路体验已结束，可以选一条标准线路继续用，或者升级优化版', '升级优化版', _Tone.warn, 'purchase')
        : _describe(auth, boot, loggedIn, now);

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
          onTap: action.isEmpty
              ? null
              : () async {
                  if (route == 'login') {
                    context.pushNamed('login');
                  } else if (route == 'retry') {
                    ref.read(guestBootstrapProvider.notifier).reset();
                    await ref.read(guestBootstrapProvider.notifier).ensure();
                  } else if (route == 'trial') {
                    await ref.read(Preferences.guestOptOut.notifier).update(false);
                    ref.read(guestBootstrapProvider.notifier).reset();
                    await ref.read(guestBootstrapProvider.notifier).ensure();
                  } else {
                    if (route == 'purchase' && tier.trialEnded) {
                      ref.read(purchasePreferTierProvider.notifier).state = 'pro';
                    }
                    context.pushNamed(route);
                  }
                },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    text,
                    maxLines: tier.trialEnded && !connected ? 3 : 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(color: fg),
                  ),
                ),
                if (action.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Text(action, style: theme.textTheme.labelMedium?.copyWith(color: fg)),
                  Icon(Icons.chevron_right_rounded, size: 18, color: fg),
                ],
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
    DateTime now,
  ) {
    if (!loggedIn) {
      if (boot.working) return ('正在开通免费试用…', '', _Tone.plain, '');
      final mask = boot.knownAccountMask;
      if (mask != null) {
        return (mask.isEmpty ? '这台手机上有账号' : '这台手机上是 $mask', '登录', _Tone.warn, 'login');
      }
      if (boot.reason == GuestBlockReason.unavailable) {
        return (boot.message ?? '免费试用暂时开不了，稍后再试', '重试', _Tone.plain, 'retry');
      }
      return ('还没有账号', '免费试用', _Tone.plain, 'trial');
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
          if (acc.dailyThrottled && acc.dailyTier == 'trial') {
            final limited = '今日高速已用完，限速 ${acc.dailyThrottleMbps}Mbps';
            final paid = acc.paidQuota > 0 ? formatDailyAmount(acc.paidQuota) : '';
            return (
              paid.isEmpty ? limited : '$limited · 买套餐每天 $paid 高速',
              '看套餐',
              _Tone.warn,
              'purchase',
            );
          }
          if (acc.dailyThrottled) {
            return ('免费试用中 · 今日高速已用完 · 0 点恢复', '看套餐', _Tone.warn, 'purchase');
          }
          final left = acc.remainingClock(now);
          return (left == null ? '免费试用中' : '免费试用中 · 剩 $left', '看套餐', _Tone.good, 'purchase');
        }
        // 会员：报套餐名，且第二段（长期有效 / 剩多久）一定要有。
        // 以前长期有效的号算不出剩余时长，整条就只剩「会员」两个字 + 右边「看套餐」，
        // 被读成「去开通会员」的广告 —— 分不清是在说我的状态还是在推销。
        final name = acc.planName?.trim().isNotEmpty == true ? acc.planName!.trim() : '会员';
        if (acc.dailyThrottled) {
          return ('$name · 今日高速已用完 · 0 点恢复', acc.lifetime ? '我的套餐' : '续费', _Tone.warn, 'purchase');
        }
        if (acc.lifetime) return ('$name · 长期有效', '我的套餐', _Tone.plain, 'purchase');
        final left = acc.remainingClock(now);
        return (left == null ? name : '$name · 剩 $left', '续费', _Tone.plain, 'purchase');
    }
  }
}

enum _Tone { good, warn, plain }

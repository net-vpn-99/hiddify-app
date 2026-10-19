import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/theme/oneray_tokens.dart';
import 'package:hiddify/features/common/guide_card.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/panel_auth/data/panel_api.dart';
import 'package:hiddify/features/panel_auth/notifier/guest_bootstrap.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hiddify/features/proxy/line/line_tier.dart';
import 'package:hiddify/features/purchase/notifier/purchase_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 顶栏账户胶囊（B 夜航，跟 Windows 顶栏同一个）：一眼知道自己是什么身份、还剩多久。
///
/// 文案按用户真实状态说人话（运营定的口径）：
///   免费试用 · 剩 11 小时 / 精品版 · 剩 28 天 / 长期有效 /
///   试用已结束 · 去买 / 已到期 · 去续费 / 流量已用完 · 去续费 / 还没有套餐
/// 点它去购买页 —— 只有「这台手机登录过账号」去登录页。
/// 要他办事的时候（到期、快到期、这台手机有账号）胶囊变强调色实心；正常会员是低调的白底。
/// 限速、精品体验结束这类长句不塞胶囊，放在主页状态下面那行（[homeAccountNote]）。
class AccountChip extends HookConsumerWidget {
  const AccountChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(panelAuthProvider);
    final boot = ref.watch(guestBootstrapProvider);
    final loggedIn = ref.watch(Preferences.panelLoggedIn);
    final tick = useState(0);
    final acc = auth.account;
    final secsLeft = acc?.secsLeft() ?? (1 << 30);
    final short = secsLeft > 0 && secsLeft < 86400;
    useEffect(() {
      if (!short) return null;
      final timer = Timer.periodic(const Duration(minutes: 1), (_) => tick.value++);
      return timer.cancel;
    }, [short]);
    final now = DateTime.now().add(Duration(microseconds: tick.value));
    final tier = ref.watch(lineTierProvider);
    final (text, hot, route) = _describe(auth, boot, loggedIn, now, secsLeft);
    final tk = OneRayTokens.of(context);

    Future<void> handle() async {
      switch (route) {
        case '':
          return;
        // 开不了免费试用：说为什么 + 能做的那一步（_describe 已经按 boot.reason 判好了）。
        case 'retry':
          await showDialog<void>(
            context: context,
            barrierColor: guideCanvasColor(context),
            builder: (dctx) => GuideCard(
              title: '为什么领不了免费试用',
              body: boot.message ?? '免费试用暂时开不了，请稍后重试',
              actionText: boot.reason == GuestBlockReason.unavailable ? '去注册' : '重试',
              onAction: () async {
                Navigator.of(dctx).pop();
                if (boot.reason == GuestBlockReason.unavailable) {
                  if (context.mounted) unawaited(context.pushNamed('register'));
                } else {
                  ref.read(guestBootstrapProvider.notifier).reset();
                  await ref.read(guestBootstrapProvider.notifier).ensure();
                }
              },
              secondaryText: boot.reason == GuestBlockReason.fixable ? '去注册' : '',
              onSecondary: () {
                Navigator.of(dctx).pop();
                context.pushNamed('register');
              },
              links: [GuideLink('知道了', () => Navigator.of(dctx).pop())],
            ),
          );
        case 'login':
          unawaited(context.pushNamed('login'));
        case 'trial':
          // 先等「不再是退出状态」写完，ensure() 一开头就读这个值。
          await ref.read(Preferences.guestOptOut.notifier).update(false);
          ref.read(guestBootstrapProvider.notifier).reset();
          await ref.read(guestBootstrapProvider.notifier).ensure();
        default:
          if (tier.trialEnded) ref.read(purchasePreferTierProvider.notifier).state = 'pro';
          unawaited(context.pushNamed(route));
      }
    }

    return Semantics(
      button: true,
      label: text,
      child: Material(
        color: hot ? tk.acc : tk.card,
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: handle,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 32, maxWidth: 190),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: hot ? tk.accInk : tk.sub,
                        fontWeight: hot ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded, size: 16, color: hot ? tk.accInk : tk.sub),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// (胶囊上的字, 是否变强调色, 点了去哪)
  (String, bool, String) _describe(
    PanelAuthState auth,
    GuestBootstrapState boot,
    bool loggedIn,
    DateTime now,
    int secsLeft,
  ) {
    if (!loggedIn) {
      final mask = boot.knownAccountMask ?? '';
      return switch (boot.noAccountState) {
        NoAccountState.opening => ('正在开通…', false, ''),
        NoAccountState.knownAccount => (mask.isEmpty ? '登录' : '登录 $mask', true, 'login'),
        NoAccountState.unavailable || NoAccountState.retryable => ('免费试用开不了', false, 'retry'),
        NoAccountState.fresh => ('免费试用', false, 'trial'),
      };
    }

    final acc = auth.account;
    if (acc == null) return ('正在读取账号…', false, '');

    final freeTrial = auth.freeTrial;
    switch (acc.stateSlug) {
      case 'traffic_exhausted':
        return ('流量已用完 · 去续费', true, 'purchase');
      case 'expired':
        return freeTrial ? ('试用已结束 · 去买', true, 'purchase') : ('已到期 · 去续费', true, 'purchase');
      case 'no_plan':
        return ('还没有套餐 · 去看看', false, 'purchase');
      default:
        final left = acc.remainingClock(now);
        if (freeTrial) return (left == null ? '免费试用' : '免费试用 · 剩 $left', false, 'purchase');
        if (acc.lifetime) return ('长期有效', false, 'purchase');
        // 剩 7 天内：胶囊变强调色「去续费」（B 夜航 §四）。
        final days = acc.daysLeft(now) ?? 1 << 30;
        if (secsLeft > 0 && days <= 7) return ('还剩 $days 天 · 去续费', true, 'purchase');
        final name = _tierWord(acc.planName);
        return (left == null ? name : '$name · 剩 $left', false, 'purchase');
    }
  }

  /// 「精品版 · 月付」→「精品版」；没写就叫「会员」。
  static String _tierWord(String? planName) {
    final n = planName?.trim() ?? '';
    if (n.isEmpty) return '会员';
    return n.split('·').first.trim();
  }
}

/// 主页状态下面那行提示（限速、精品体验结束）和要不要挂「升级 ›」。没事说就是空。
/// 跟 Windows Main.qml homeNote 同一套。
(String, bool) homeAccountNote(WidgetRef ref) {
  final acc = ref.watch(panelAuthProvider.select((s) => s.account));
  final freeTrial = ref.watch(panelAuthProvider.select((s) => s.freeTrial));
  final tier = ref.watch(lineTierProvider);
  final connected = ref.watch(connectionNotifierProvider).valueOrNull?.isConnected ?? false;
  final lineName = ref.watch(Preferences.lastNodeName);
  if (acc == null) return ('', false);
  if (connected && acc.proThrottled && tier.isProName(lineName)) {
    return ('精品线路今天已超 ${formatDailyAmount(acc.proQuota)}，现在速度最高 ${acc.proThrottleMbps}Mbps；标准线路照常用', false);
  }
  if (tier.trialEnded && !connected) return ('精品线路体验已结束，可以选一条标准线路继续用，或者升级精品版', true);
  if (!acc.dailyThrottled) return ('', false);
  final upgrade = !(acc.planName?.contains('精品') ?? false);
  if (freeTrial && acc.dailyTier == 'trial' && acc.paidQuota > 0) {
    return ('今日标准高速已用完，现在速度最高 ${acc.dailyThrottleMbps}Mbps · 买套餐每天 ${formatDailyAmount(acc.paidQuota)} 高速', upgrade);
  }
  return ('今日标准高速已用完，现在速度最高 ${acc.dailyThrottleMbps}Mbps，0 点恢复。', upgrade);
}

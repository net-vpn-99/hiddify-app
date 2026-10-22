import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/theme/oneray_tokens.dart';
import 'package:hiddify/features/common/text_link.dart';
import 'package:hiddify/features/panel_auth/data/panel_api.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 「我的」页顶部的账户卡（B 夜航，跟 Windows「我的」侧栏同一张）：
/// 我是谁 + 套餐还剩多久（点进账号管理）/ 今日高速和设备 / 免注册号的防丢提醒 / 一颗「续费 / 升级」。
class AccountCard extends ConsumerWidget {
  const AccountCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tk = OneRayTokens.of(context);
    final loggedIn = ref.watch(Preferences.panelLoggedIn);
    final auth = ref.watch(panelAuthProvider);
    if (auth.isGuest && auth.account != null && auth.guestPaidReminder == null) {
      Future.microtask(() => ref.read(panelAuthProvider.notifier).refreshGuestPaidHint());
    }
    final acc = auth.account;
    final active = acc != null && acc.stateSlug == 'ok';

    // 游客显示「账号 #A1B2C3D4」而不是「游客用户」：他确实有一个账号，套餐也买在这个号上。
    final title = loggedIn ? auth.accountLabel : '还没有账号';
    final subtitle = loggedIn ? _planLine(auth) : '登录已有账号，或直接买套餐开始用';
    final expired = loggedIn && acc != null && (acc.stateSlug == 'expired' || acc.stateSlug == 'traffic_exhausted');

    Widget stat(String label, String value, String unit) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 11, color: tk.sub)),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: value,
                  style: TextStyle(fontFamily: OneRayTokens.numberFont, fontSize: 15, fontWeight: FontWeight.w600, color: tk.text),
                ),
                TextSpan(text: unit, style: TextStyle(fontSize: 11, color: tk.sub)),
              ],
            ),
          ),
        ],
      ),
    );
    String left(int quota, int used) => formatDailyAmount((quota - used).clamp(0, quota)).replaceAll(' GB', '').replaceAll(' MB', 'M');
    String total(int quota) => '/${formatDailyAmount(quota).replaceAll(' GB', 'G')}';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: tk.card, borderRadius: BorderRadius.circular(18)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => context.pushNamed(loggedIn ? 'account' : 'login'),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(color: tk.accSoft, shape: BoxShape.circle),
                    child: Icon(Icons.person_outline_rounded, size: 22, color: tk.acc),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: tk.text),
                        ),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: expired ? tk.fault : tk.sub),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded, color: tk.sub),
                ],
              ),
            ),
            if (active && (acc.proKnown || acc.dailyKnown || acc.deviceLimit > 0)) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(color: tk.panel, borderRadius: BorderRadius.circular(12)),
                child: Row(
                  children: [
                    if (acc.proKnown) stat('今日精品剩余', left(acc.proQuota, acc.proUsed), total(acc.proQuota)),
                    if (acc.dailyKnown) stat('今日标准剩余', left(acc.dailyQuota, acc.dailyUsed), total(acc.dailyQuota)),
                    if (acc.deviceLimit > 0) stat('设备上限', '${acc.deviceLimit}', ' 台'),
                  ],
                ),
              ),
            ],
            // 免注册的号：提醒加邮箱防丢（换手机或重装后找不回来）。
            if (auth.isGuest) ...[
              const SizedBox(height: 10),
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => context.pushNamed('bindEmail'),
                child: Text.rich(
                  TextSpan(
                    children: [
                      const TextSpan(text: '这是这台手机的免注册账号，换手机或重装后找不回来。'),
                      TextSpan(text: '加个邮箱防丢 ›', style: TextStyle(color: tk.acc)),
                    ],
                  ),
                  style: TextStyle(fontSize: 12, height: 1.5, color: tk.sub),
                ),
              ),
            ],
            const SizedBox(height: 12),
            SizedBox(
              height: 48,
              child: FilledButton(
                onPressed: () => context.pushNamed('purchase'),
                // 跟 Windows「我的」侧栏同一套：没套餐「选择套餐」、免注册号「去买套餐」、过期「去续费」。
                child: Text(
                  !loggedIn || acc == null || acc.stateSlug == 'no_plan'
                      ? '选择套餐'
                      : auth.freeTrial
                      ? '去买套餐'
                      : active
                      ? '续费 / 升级'
                      : '去续费',
                ),
              ),
            ),
            // 游客 / 没账号：登录已有账号 —— 在官网注册过的人装上 App 会被自动开成游客号，首页一个「登录」字样都没有。
            if (!loggedIn || auth.isGuest)
              TextLink('已经有账号？登录', onTap: () => context.pushNamed('login')),
          ],
        ),
      ),
    );
  }

  /// 副标题：套餐状态 + 还剩多久，口径和首页账户胶囊一致。
  String _planLine(PanelAuthState auth) {
    final acc = auth.account;
    if (acc == null) return '正在读取账号…';
    switch (acc.stateSlug) {
      case 'traffic_exhausted':
        return '流量已用完';
      case 'expired':
        return auth.freeTrial ? '免费试用已结束' : '会员已到期';
      case 'no_plan':
        return '还没有套餐';
      default:
        if (auth.freeTrial) {
          final left = acc.remainingClock();
          return left == null ? '免费试用中' : '免费试用中 · 剩 $left';
        }
        final name = acc.planName?.trim().isNotEmpty == true ? acc.planName!.trim().split('·').first.trim() : '会员';
        if (acc.lifetime) return '$name · 长期有效';
        if (acc.trialPendingHours > 0) return '$name · 试用 ${acc.trialPendingHours} 小时，连上后开始算';
        final left = acc.remainingClock();
        return left == null ? name : '$name · 还剩 $left';
    }
  }
}

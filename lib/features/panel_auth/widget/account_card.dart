import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/common/soft_card.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hiddify/features/purchase/widget/purchase_tokens.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 「我的」页顶部的账号卡（1.1.28 重做，原来是一行 ListTile）。
///
/// 一整块里放三样东西：我是谁 + 还剩多久（点进账号管理）/ 续费 + 在另一台设备上用（游客是登录已有账号）/ 游客没绑邮箱时
/// 的提醒条。原来这页最大的问题是**没有买套餐的入口** —— 想付钱找不到地方。
class AccountCard extends ConsumerWidget {
  const AccountCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final tk = PurchaseTokens.of(context);
    final buttonText = theme.textTheme.labelLarge?.copyWith(fontSize: 15, fontWeight: FontWeight.w600);
    final secondary = OutlinedButton.styleFrom(
      foregroundColor: tk.text,
      side: BorderSide(color: tk.border.withValues(alpha: 0.8)),
      minimumSize: const Size.fromHeight(44),
      textStyle: buttonText,
    );
    final loggedIn = ref.watch(Preferences.panelLoggedIn);
    final auth = ref.watch(panelAuthProvider);
    if (auth.isGuest && auth.account != null && auth.guestPaidReminder == null) {
      Future.microtask(() => ref.read(panelAuthProvider.notifier).refreshGuestPaidHint());
    }

    final String title;
    final String subtitle;
    if (!loggedIn) {
      title = '还没有账号';
      subtitle = '登录已有账号，或直接买套餐开始用';
    } else {
      // 游客显示「账号 #A1B2C3D4」而不是「游客用户」：他确实有一个账号，套餐也买在
      // 这个号上，只是还没绑邮箱。原来这里叫「游客用户」、购买页叫「这台手机的免注册
      // 试用」、账号页叫「游客」—— 同一个东西三种叫法，用户只会更糊涂。
      title = auth.accountLabel;
      subtitle = _planLine(ref, auth);
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
      child: SoftCard(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (auth.isGuest && auth.guestPaidReminder == true) ...[
              Material(
                color: theme.colorScheme.tertiaryContainer,
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => context.pushNamed('bindEmail'),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    child: Text(
                      '加个邮箱，方便找回账号 ›',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onTertiaryContainer),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
            InkWell(
              onTap: () => context.pushNamed(loggedIn ? 'account' : 'login'),
              child: Row(
                children: [
                  IconTile(loggedIn ? Icons.person_rounded : Icons.person_outline_rounded, IconTile.gold, size: 44),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(color: tk.text),
                        ),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: tk.secondary),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded, color: tk.secondary),
                ],
              ),
            ),
            const SizedBox(height: 12),
            // 账号管理就是上面那一行（点头像 / 邮箱进去），这里不再放一颗同样去处的按钮。
            if (loggedIn && !auth.isGuest)
              _PrimaryButton(
                label: auth.account?.stateSlug == 'ok' ? '续费 / 升级' : '买套餐',
                onTap: () => context.pushNamed('purchase'),
              )
            else
              Row(
                children: [
                  Expanded(
                    child: _PrimaryButton(label: '买套餐', onTap: () => context.pushNamed('purchase')),
                  ),
                  const SizedBox(width: 10),
                  // 游客 / 没账号：登录已有账号 —— 在官网注册过的人装上 App 会被自动开成游客号，
                  // 首页一个「登录」字样都没有。
                  Expanded(
                    child: OutlinedButton(
                      style: secondary,
                      onPressed: () => context.pushNamed('login'),
                      child: const Text('登录已有账号'),
                    ),
                  ),
                ],
              ),
            // 在另一台设备上用（配对码）。游客多一句「换手机也能用」：这个号只认这台手机，
            // 换手机 / 恢复出厂就找不回来了，电脑上也是另一个号。
            if (loggedIn) ...[
              const SizedBox(height: 4),
              InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => context.pushNamed('addDevice'),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(4, 12, 0, 4),
                  child: Row(
                    children: [
                      Expanded(child: Text('在另一台设备上用', style: theme.textTheme.bodyMedium?.copyWith(color: tk.text))),
                      if (auth.isGuest)
                        Text(
                          '换手机也能用',
                          style: theme.textTheme.bodySmall?.copyWith(color: tk.secondary),
                        ),
                      Icon(Icons.chevron_right_rounded, color: tk.secondary),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 副标题：套餐状态 + 还剩多久，口径和首页状态条一致。
  String _planLine(WidgetRef ref, PanelAuthState auth) {
    final acc = auth.account;
    if (acc == null) return '正在读取账号…';
    switch (acc.stateSlug) {
      case 'traffic_exhausted':
        return '流量已用完';
      case 'expired':
        return auth.isGuest ? '免费试用已结束' : '会员已到期';
      case 'no_plan':
        return '还没有套餐';
      default:
        // 会员报套餐名，且第二段一定要有 —— 长期有效的号算不出剩余时长，
        // 以前这里就只剩「会员」两个字，跟首页状态条同一个毛病（1.1.40 一起改）。
        if (auth.isGuest) {
          final left = acc.remainingClock();
          return left == null ? '免费试用中' : '免费试用中 · 剩 $left';
        }
        final name = acc.planName?.trim().isNotEmpty == true ? acc.planName!.trim() : '会员';
        if (acc.lifetime) return '$name · 长期有效';
        final left = acc.remainingClock();
        return left == null ? name : '$name · 剩 $left';
    }
  }
}

/// 账号卡上的主按钮（续费 / 买套餐）：GoMami 同款橙底白字（运营 10-15 选的 A 版；
/// 品牌金做大块按钮在浅色下发闷，像芥末黄）。
class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  static const _orange = Color(0xFFEE7B3B);

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme.labelLarge?.copyWith(
      fontSize: 15,
      fontWeight: FontWeight.w600,
      color: Colors.white,
    );
    return Material(
      color: _orange,
      borderRadius: BorderRadius.circular(22),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(height: 44, child: Center(child: Text(label, style: text))),
      ),
    );
  }
}

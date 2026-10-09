import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/panel_auth/data/other_vpn.dart';
import 'package:hiddify/features/panel_auth/notifier/guest_bootstrap.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 首页顶部：新用户手机上开着别家 VPN 时，请他先关掉（OneRay 2026-10-09）。
///
/// 是否显示看 guestBootstrapProvider 的 [GuestBlockReason.otherVpn]（开号前本机查到的）。
/// 用户去系统设置关掉、回到 App 时（以及提示显示期间每 3 秒）再查一次；关掉了就
/// reset + ensure，接着把没做完的事做完（新用户 = 领免费试用），用户什么都不用再点。
/// 老用户不显示：他们的请求不会被拒，点连接时系统会自动把别家顶掉。
class OtherVpnBanner extends HookConsumerWidget {
  const OtherVpnBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loggedIn = ref.watch(Preferences.panelLoggedIn);
    final showing = !loggedIn && ref.watch(guestBootstrapProvider.select((s) => s.reason == GuestBlockReason.otherVpn));

    useEffect(() {
      if (!showing) return null;
      var checking = false;
      Future<void> recheck() async {
        if (checking) return;
        checking = true;
        try {
          if (!await OtherVpn.isActive()) {
            final boot = ref.read(guestBootstrapProvider.notifier);
            boot.reset();
            await boot.ensure();
          }
        } finally {
          checking = false;
        }
      }

      final listener = AppLifecycleListener(onResume: recheck);
      // 从通知栏直接断开别家 VPN 不一定触发 onResume，提示还在时顺手轮询。
      final timer = Timer.periodic(const Duration(seconds: 3), (_) => recheck());
      return () {
        listener.dispose();
        timer.cancel();
      };
    }, [showing]);

    if (!showing) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final bg = theme.colorScheme.tertiaryContainer;
    final fg = theme.colorScheme.onTertiaryContainer;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: OtherVpn.openSettings,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    OtherVpn.message,
                    style: theme.textTheme.bodyMedium?.copyWith(color: fg),
                  ),
                ),
                const SizedBox(width: 8),
                Text('去关掉', style: theme.textTheme.labelLarge?.copyWith(color: fg, fontWeight: FontWeight.w600)),
                Icon(Icons.chevron_right_rounded, size: 18, color: fg),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

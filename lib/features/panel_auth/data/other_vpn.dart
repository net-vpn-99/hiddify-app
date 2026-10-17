import 'dart:io';

import 'package:flutter/services.dart';

/// 手机上是不是开着别家 VPN（OneRay 2026-10-09）。
///
/// 开着别家 VPN 不拦（10-17 起，开号前那道拦截已删）：系统只留一个 VPN，我们连上就把它顶掉。
/// 只在系统没让我们连（别家设了「始终开启的 VPN」）时，用这里的说法请他关掉。
///
/// 调用方要保证我们自己的 VPN 没连着，否则这里会把自己算进去。
abstract final class OtherVpn {
  static const _channel = MethodChannel('com.hiddify.app/platform');

  static Future<bool> isActive() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('other_vpn_active') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> openSettings() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('open_vpn_settings');
    } catch (_) {}
  }

  // 别家 VPN 的说法只在这里写一份（10-15 两端合并）：首页横幅、开号被拦、连接第 4 步都用它。
  // 跟 Windows 的「「X」正在接管网络，关掉它光速雷达才能用」同一句话。
  static const title = '手机上开着别的 VPN';
  static const message = '手机上开着别的 VPN，关掉它光速雷达才能用。';
  static const howTo = '点「打开 VPN 设置」把它断开；如果它开着「始终开启的 VPN」，也要关掉。然后回来再点一下按钮。';
}

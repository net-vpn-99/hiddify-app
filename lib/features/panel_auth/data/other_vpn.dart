import 'dart:io';

import 'package:flutter/services.dart';

/// 手机上是不是开着别家 VPN（OneRay 2026-10-09）。
///
/// 只给还没登录的新用户用：开着别家 VPN 时，我们 App 的请求都从别家出去，服务端看到的是
/// 国外 IP，领免费试用会被拒。与其等服务端拒，不如打开 App 就说「先关掉它」。
/// 老用户不提醒 —— 他们的请求不会被拒，点连接时系统也会自动把别家顶掉。
///
/// 调用方要保证我们自己的 VPN 没连着（新用户本来就连不上），否则这里会把自己算进去。
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

  static const message = '手机上开着别的 VPN，请先把它关掉，再用光速雷达。';
}

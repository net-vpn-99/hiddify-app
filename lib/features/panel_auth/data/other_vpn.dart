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

  // 别家 VPN 的说法只在这里写一份（10-15 两端合并）：首页横幅、连接第 4 步都用它。
  // 标题、句式跟 Windows 冲突卡一样（运营 10-17 定：「网络被其他软件占用」+「你的电脑上还开着…，关掉它光速雷达才能连上」）。
  static const title = '网络被其他软件占用';
  static const message = '你的手机上还开着别的 VPN，关掉它光速雷达才能连上。';
  // 回来不用再点（体检修复 R5）：从 VPN 设置回到光速雷达时，别的 VPN 已经关了就自动接着连。
  static const howTo = '点「打开 VPN 设置」把它断开；如果它开着「始终开启的 VPN」，也要关掉。回到光速雷达会自动接着连接。';
}

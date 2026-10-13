import 'dart:io';

import 'package:flutter/services.dart';

/// 安卓系统「网络连接请求」（允许光速雷达建 VPN）那一下（10-14 运营：客户卡在这里找客服）。
///
/// - 没允许过：第一次连接前先弹说明卡，告诉他接下来点「确定」。
/// - 被拒了：分两种说 —— 连接前手机上开着别的 VPN，或者连着被拒两次（多半是别的 VPN 设了
///   「始终开启」，系统直接拒、根本不弹窗），说「先关掉另一个 VPN」；否则只说「再点一次，点确定」。
abstract final class VpnPermission {
  static const _channel = MethodChannel('com.hiddify.app/platform');

  /// 查不到（非安卓 / 原生没这个方法）按「允许过」算，不多弹卡。
  static Future<bool> granted() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _channel.invokeMethod<bool>('vpn_permission_granted') ?? true;
    } catch (_) {
      return true;
    }
  }

  /// 这次点连接之前，手机上是不是开着别的 VPN（我们自己的还没连）。
  static bool otherVpnBeforeConnect = false;

  /// 连着被拒了几次（按点连接的次数算，同一次被报两遍只算一次）；连上就清零。
  static int deniedStreak = 0;
  static int _lastDeniedTicket = -1;

  static void noteDenied(int ticket) {
    if (ticket == _lastDeniedTicket) return;
    _lastDeniedTicket = ticket;
    deniedStreak++;
  }

  static void noteConnected() {
    deniedStreak = 0;
    _lastDeniedTicket = -1;
  }
}

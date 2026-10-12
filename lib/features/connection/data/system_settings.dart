import 'dart:io';

import 'package:flutter/services.dart';

/// 连接失败时首页给的「去设置」按钮（connect_progress.dart 的 connectFailProgress）。
/// 原生那边见 PlatformSettingsHandler.kt。
enum SettingsAction {
  none(''),
  vpn('打开 VPN 设置'),
  notifications('打开通知设置'),
  battery('允许后台运行');

  const SettingsAction(this.label);
  final String label;

  static const _channel = MethodChannel('com.hiddify.app/platform');

  Future<void> open() async {
    if (!Platform.isAndroid || this == none) return;
    final method = switch (this) {
      vpn => 'open_vpn_settings',
      notifications => 'open_notification_settings',
      battery => 'request_ignore_battery_optimizations',
      none => '',
    };
    try {
      await _channel.invokeMethod<bool>(method);
    } catch (_) {}
  }
}

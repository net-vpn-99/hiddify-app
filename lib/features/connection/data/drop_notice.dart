import 'dart:io';

import 'package:flutter/services.dart';

/// 用着用着断了：发一条系统通知（App 在后台、手机锁着屏也看得到）。
/// 和 Windows 的托盘气泡同一件事、同一句话（10-12 洛杉矶 05 机房断网，运营没收到提醒）。
/// 原生那边见 PlatformSettingsHandler.kt 的 show_drop_notice；没通知权限时什么都不发。
class DropNotice {
  DropNotice._();

  static const _channel = MethodChannel('com.hiddify.app/platform');

  static Future<void> show(String text, {String title = '光速雷达已断开'}) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('show_drop_notice', {'title': title, 'text': text});
    } catch (_) {}
  }
}

import 'dart:async';

import 'package:android_id/android_id.dart';
import 'package:loggy/loggy.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 设备闸（VPN 仓库 `tools/device-gate/gate.py`）用的稳定设备 ID。
///
/// 只认系统的 `Settings.Secure.ANDROID_ID`，绝不自己生成 UUID 存本地：卸载
/// 重装 App 后 ANDROID_ID 不变，跟闸的 45 天座位对得上；换成自造的 UUID 的
/// 话，用户一清 App 数据 / 重装就换一个新号，旧座位占着不放、又不停占新
/// 座位，设备数很快就把限额挤满。
///
/// 恢复出厂会变、多用户 profile 每个用户拿到的值不同——这些是系统本身的
/// 语义，接受，不额外处理。
class DeviceId {
  DeviceId._();

  static const _prefsKey = 'oneray.device_id.android_id';

  // 空值 / 占位值 / 部分改机 ROM 和老模拟器共享的著名坏值——很多台设备会
  // 撞同一个号，绝不能当真实设备 ID 用来占座位。
  static const _badValues = {'', 'unknown-device', '9774d56d682e549c'};

  static String? _cached;

  /// 拿一次稳定设备 ID。拿不到（读取失败，或读到已知坏值）返回 null——
  /// 调用方应该当作「这台设备用不了闸」处理：停止连接并提示用户，而不是
  /// 放行或者拿坏 ID 去占座位。
  static Future<String?> read() async {
    final cached = _cached;
    if (cached != null) return cached;

    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_prefsKey);
    if (stored != null && !_badValues.contains(stored)) {
      _cached = stored;
      return stored;
    }

    String? fresh;
    try {
      fresh = await const AndroidId().getId();
    } catch (e, stackTrace) {
      Loggy('DeviceId').warning('read ANDROID_ID failed', e, stackTrace);
      return null;
    }
    if (fresh == null || _badValues.contains(fresh)) return null;

    _cached = fresh;
    unawaited(prefs.setString(_prefsKey, fresh));
    return fresh;
  }
}

import 'dart:async';

import 'package:android_id/android_id.dart';
import 'package:loggy/loggy.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// 设备闸（VPN 仓库 `tools/device-gate/gate.py`）用的稳定设备 ID。
///
/// 优先认系统的 `Settings.Secure.ANDROID_ID`，正常情况不自己生成 UUID（坏值例外见下）：卸载
/// 重装 App 后 ANDROID_ID 不变，跟闸的 45 天座位对得上；换成自造的 UUID 的
/// 话，用户一清 App 数据 / 重装就换一个新号，旧座位占着不放、又不停占新
/// 座位，设备数很快就把限额挤满。
///
/// 恢复出厂会变、多用户 profile 每个用户拿到的值不同——这些是系统本身的
/// 语义，接受，不额外处理。
///
/// 例外（10-18）：有的手机 ANDROID_ID 读出来是一串 0 之类的坏值，很多台不相干的手机撞同一个号，
/// 服务器（GslGuest 1.9.1）一律拒绝，这些人以前就开不了免费试用。读到坏值时自己生成一个随机号
/// 存起来用。代价：卸载重装后会变成新设备、多占一个座位——只有这几台会这样，比完全用不了好。
class DeviceId {
  DeviceId._();

  static const _prefsKey = 'oneray.device_id.android_id';
  static const _generatedKey = 'oneray.device_id.generated';

  // 空值 / 占位值 / 部分改机 ROM 和老模拟器共享的著名坏值——很多台设备会
  // 撞同一个号，绝不能当真实设备 ID 用来占座位。
  static const _badValues = {'', 'unknown-device', '9774d56d682e549c'};

  /// 坏值：上面那几个，或者全是同一个字符（0000000000000000）——跟服务器 GslGuest 的判断一样。
  static bool _bad(String v) => _badValues.contains(v.toLowerCase()) || RegExp(r'^(.)\1*$').hasMatch(v.replaceAll('-', ''));

  static String? _cached;

  /// 拿一次稳定设备 ID。拿不到（读取失败，或读到已知坏值）返回 null——
  /// 调用方应该当作「这台设备用不了闸」处理：停止连接并提示用户，而不是
  /// 放行或者拿坏 ID 去占座位。
  static Future<String?> read() async {
    final cached = _cached;
    if (cached != null) return cached;

    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_prefsKey);
    if (stored != null && !_bad(stored)) {
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
    if (fresh == null || _bad(fresh)) {
      // 系统给的是坏值：用自己生成、存在本机的号（第一次生成后一直用同一个）。
      var own = prefs.getString(_generatedKey);
      if (own == null || own.isEmpty) {
        own = const Uuid().v4();
        await prefs.setString(_generatedKey, own);
      }
      _cached = own;
      return own;
    }

    _cached = fresh;
    unawaited(prefs.setString(_prefsKey, fresh));
    return fresh;
  }
}

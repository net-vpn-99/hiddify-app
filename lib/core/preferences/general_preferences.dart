import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/core/model/environment.dart';
import 'package:hiddify/core/model/region.dart';
import 'package:hiddify/core/preferences/actions_at_closing.dart';

import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/core/utils/preferences_utils.dart';
import 'package:hiddify/features/per_app_proxy/model/per_app_proxy_mode.dart';
import 'package:hiddify/features/window/notifier/window_notifier.dart';
import 'package:hiddify/utils/platform_utils.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'general_preferences.g.dart';

/// OneRay: 这次启动是「装好后的第一次」（bootstrap 里置位）。没有引导页，首启和平时一样
/// 直接进首页，游客号由 guestBootstrapProvider 在后台开。这个标记留给诊断 / 埋点。
/// 别改成在 router 的 redirect 里写偏好 —— 写入会通知 RefreshListenable，页面白重建一遍。
// ignore: unused_element
bool firstLaunchAfterInstall = false;

bool _debugIntroPage = false;

abstract class Preferences {
  static final introCompleted = PreferencesNotifier.create(
    "intro_completed",
    false,
    overrideValue: _debugIntroPage && kDebugMode ? false : null,
  );

  // Null means that auto selection has not been performed yet.
  static final autoAppsSelectionRegion = PreferencesNotifier.create<Region?, String?>(
    "auto_apps_selection_region",
    null,
    mapFrom: (value) => value == null || value.isEmpty ? null : Region.values.byName(value),
    mapTo: (value) => value == null ? '' : value.name,
  );

  static final autoAppsSelectionUpdateInterval = PreferencesNotifier.create<double, double>(
    "auto_apps_selection_update_interval",
    1.0,
  );

  static final autoAppsSelectionLastUpdate = PreferencesNotifier.create<DateTime?, String?>(
    "auto_apps_selection_last_update",
    null,
    mapFrom: (value) => value == null ? null : DateTime.tryParse(value),
    mapTo: (value) => value?.toIso8601String(),
  );

  static final includeApps = PreferencesNotifier.create<List<String>, List<String>>(
    "per_app_proxy_include_list",
    <String>[],
  );

  static final excludeApps = PreferencesNotifier.create<List<String>, List<String>>(
    "per_app_proxy_exclude_list",
    <String>[],
  );

  static final windowMaximized = PreferencesNotifier.create<bool, bool>("window_maximized", false);

  static final windowPosition = PreferencesNotifier.create<Offset?, String?>(
    "window_position",
    null,
    mapFrom: (value) {
      if (value == null) return null;
      final list = value.split(',').map((e) => double.tryParse(e)).toList();
      return Offset(list[0]!, list[1]!);
    },
    mapTo: (value) {
      if (value == null) return null;
      return "${value.dx},${value.dy}";
    },
  );

  static final windowSize = PreferencesNotifier.create<Size, String>(
    "window_size",
    defaultWindowSize,
    mapFrom: (value) {
      final list = value.split(',').map((e) => double.tryParse(e)).toList();
      return Size(list[0]!, list[1]!);
    },
    mapTo: (value) => "${value.width},${value.height}",
  );

  static final silentStart = PreferencesNotifier.create<bool, bool>("silent_start", false);

  static final disableMemoryLimit = PreferencesNotifier.create<bool, bool>(
    "disable_memory_limit",
    // disable memory limit on desktop by default
    PlatformUtils.isDesktop,
  );

  static final perAppProxyMode = PreferencesNotifier.create<PerAppProxyMode, String>(
    "per_app_proxy_mode",
    PerAppProxyMode.off,
    mapFrom: PerAppProxyMode.values.byName,
    mapTo: (value) => value.name,
  );

  static final markNewProfileActive = PreferencesNotifier.create<bool, bool>("mark_new_profile_active", true);

  // OneRay: 是否已登录光速会员账号（同步可读，用于路由判断；令牌本身在 flutter_secure_storage）
  static final panelLoggedIn = PreferencesNotifier.create<bool, bool>("panel_logged_in", false);

  // OneRay: 主动退出过（游客或正式账号）就不再自动开游客；登录页的「免注册试用」照样能点。
  static final guestOptOut = PreferencesNotifier.create<bool, bool>("guest_opt_out", false);

  // OneRay: 免注册号的「钥匙」（账号编号 + 密码）用户已经抄走了。没抄走之前「我的」页
  // 挂红点。默认 true —— 1.3.0 之前开的老号本来就没有待办，别凭空长出一个红点。
  static final guestKeySaved = PreferencesNotifier.create<bool, bool>("guest_key_saved", true);

  // OneRay: 「关于」页连点版本号 5 次解锁，「我的」页才显示高级设置（路由 / DNS / 入站 /
  // TLS / WARP / 日志）。普通用户改这些只会把自己搞挂，但客服排障时要用。
  static final devMode = PreferencesNotifier.create<bool, bool>("dev_mode", false);

  // OneRay: 上次连接的线路名 / 说明，断开时也能在首页显示"当前线路"
  static final lastNodeName = PreferencesNotifier.create<String, String>("last_node_name", "");
  static final lastNodeDesc = PreferencesNotifier.create<String, String>("last_node_desc", "");

  // OneRay: 用户在首页线路选择器里选的线路名（splitNodeName 后的 name 段）。
  // 断开时也能选；连接后由 autoLineFixer 按名字匹配到真实出站并切过去。空 = 不指定。
  static final preferredLineName = PreferencesNotifier.create<String, String>("preferred_line_name", "");

  static final dynamicNotification = PreferencesNotifier.create<bool, bool>("dynamic_notification", true);

  static final autoCheckIp = PreferencesNotifier.create<bool, bool>("auto_check_ip", true);

  static final startedByUser = PreferencesNotifier.create<bool, bool>("started_by_user", false);

  static final storeReviewedByUser = PreferencesNotifier.create<bool, bool>("store_reviewed_by_user", false);

  static final actionAtClose = PreferencesNotifier.create<ActionsAtClosing, String>(
    "action_at_close",
    ActionsAtClosing.ask,
    mapFrom: ActionsAtClosing.values.byName,
    mapTo: (value) => value.name,
  );
}

@Riverpod(keepAlive: true)
class DebugModeNotifier extends _$DebugModeNotifier {
  late final _pref = PreferencesEntry(
    preferences: ref.watch(sharedPreferencesProvider).requireValue,
    key: "debug_mode",
    defaultValue: ref.read(environmentProvider) == Environment.dev,
  );

  @override
  bool build() => _pref.read();

  Future<void> update(bool value) {
    state = value;
    return _pref.write(value);
  }
}

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/core/directories/directories_provider.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/core/utils/device_id.dart';
import 'package:hiddify/features/app/notifier/app_foreground.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/log/data/log_path_resolver.dart';
import 'package:hiddify/features/panel_auth/data/panel_api_base.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/smart_split/data/route_api.dart';
import 'package:hiddify/features/smart_split/data/route_writer.dart';
import 'package:hiddify/features/smart_split/data/things_store.dart';
import 'package:hiddify/features/smart_split/model/public_suffix.dart';
import 'package:hiddify/features/smart_split/notifier/smart_split_controller.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:installed_apps/index.dart';

/// 智能分流页的状态。离开这页（返回键）就释放：采集记录清空（计划书四「安卓」那条）。
final smartSplitProvider = NotifierProvider.autoDispose<SmartSplitNotifier, SmartSplitState>(SmartSplitNotifier.new);

/// 页面上能做的事（截图测试换成空的）。
abstract interface class SplitActions {
  Map<String, Uint8List?> get icons;
  Future<void> startCollect();
  void stopCollect();
  Future<void> choose(String key, String picked);
  Future<void> resetOne(String key);
  Future<void> resetAll();
  Future<void> retrySync(String key);
  void setDomainIncluded(String key, String domain, {required bool included});
}

class SmartSplitNotifier extends AutoDisposeNotifier<SmartSplitState> implements SplitActions {
  SmartSplitController? _c;
  Timer? _timer;
  final _names = <String, String>{};
  final _asking = <String>{};
  var _disposed = false;

  /// App 图标（包名 → PNG），取不到为 null。页面用来画 App 那一行。
  @override
  final icons = <String, Uint8List?>{};

  @override
  SmartSplitState build() {
    ref.onDispose(() {
      _disposed = true;
      _timer?.cancel();
      _c?.leave();
    });
    ref.listen(connectionNotifierProvider, (_, next) => _c?.onConnection(connected: next.valueOrNull?.isConnected ?? false));
    unawaited(_init());
    return const SmartSplitState();
  }

  bool get _connected => !_disposed && (ref.read(connectionNotifierProvider).valueOrNull?.isConnected ?? false);

  /// 每个 await 之后都看一下：页面在初始化完之前就离开了，不再 ref.read（会抛）、不再去跟账号对。
  Future<void> _init() async {
    final dirs = await ref.read(appDirectoriesProvider.future);
    if (_disposed) return;
    final psl = PublicSuffix.parse(await rootBundle.loadString('assets/split/public_suffix_list.dat'));
    final deviceId = await DeviceId.read() ?? '';
    if (_disposed) return;
    final auth = ref.read(panelAuthProvider.notifier);
    final c = SmartSplitController(SmartSplitDeps(
      baseDir: dirs.baseDir,
      boxLog: File(LogPathResolver.corePath(dirs.workingDir)),
      currentConfigPath: '${dirs.workingDir.path}/data/current-config.json',
      psl: psl,
      loadThings: () => loadThings(dirs.baseDir),
      saveThings: (json) => saveThings(dirs.baseDir, json),
      api: () => RouteApi.panel(tokenOf: auth.currentToken),
      reconnect: _reconnect,
      loggedIn: () => !_disposed && ref.read(panelAuthProvider).loggedIn,
      accountId: () => _disposed ? '' : splitAccountId(ref.read(panelAuthProvider).account?.uuid),
      appName: _appName,
      appVer: ref.read(appInfoProvider).valueOrNull?.version ?? '',
      deviceId: deviceId,
      ownDomains: _ownDomains(psl),
    ));
    c.onChange = (s) {
      if (_disposed) return;
      state = s;
      _syncTimer(s.collecting);
    };
    _c = c;
    await c.open(connected: _connected);
  }

  /// 我们的面板、下载、官网域名（采集里不列出）。
  static List<String> _ownDomains(PublicSuffix psl) {
    final hosts = <String>{
      for (final u in [...Constants.panelApiFallbacks, ...Constants.releasesJsonUrls, PanelApiBase.current])
        Uri.tryParse(u)?.host ?? '',
    }..remove('');
    return {for (final h in hosts) psl.registrable(h)}.toList();
  }

  /// 重连，以连接状态回到「已连接」为准（审查 3：reconnect 出错不抛、没连着时什么都不做，光看它返回判不出来）。
  Future<bool> _reconnect() async {
    try {
      await ref.read(connectionNotifierProvider.notifier).reconnect(await ref.read(activeProfileProvider.future));
      for (var i = 0; i < 75; i++) {
        if (_connected) return true;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 采集归类要马上有个名字：先用包名，App 名拿到了再刷新一次。
  String _appName(String pkg) {
    final n = _names[pkg];
    if (n != null) return n;
    if (_asking.add(pkg)) {
      unawaited(InstalledApps.getAppInfo(pkg, null).then((info) {
        if (info == null) return;
        _names[pkg] = info.name;
        icons[pkg] = info.icon;
        _c?.tick();
      }).catchError((_) {}));
    }
    return pkg;
  }

  /// 正在采集时每秒读一次 box.log；切到浏览器时（App 在后台）不读，回来一次读完。
  void _syncTimer(bool collecting) {
    if (!collecting) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _timer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (ref.read(appForegroundProvider)) _c?.tick();
    });
  }

  @override
  Future<void> startCollect() async => _c?.startCollect();
  @override
  void stopCollect() => _c?.stopCollect();
  @override
  Future<void> choose(String key, String picked) async => _c?.choose(key, picked);
  @override
  Future<void> resetOne(String key) async => _c?.resetOne(key);
  @override
  Future<void> resetAll() async => _c?.resetAll();
  @override
  Future<void> retrySync(String key) async => _c?.retrySync(key);
  @override
  void setDomainIncluded(String key, String domain, {required bool included}) =>
      _c?.setDomainIncluded(key, domain, included: included);
}

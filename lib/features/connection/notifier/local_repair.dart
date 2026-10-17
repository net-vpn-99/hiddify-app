import 'dart:async';

import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/connection/data/connect_reporter.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/connection/notifier/stability_notifier.dart';
import 'package:hiddify/features/home/widget/connect_progress.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hiddify/features/profile/notifier/profile_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 一键修复 / 初始化本地网络（两端统一，Windows 见 ConnectionController::runLocalInit；
/// 规则见 docs/计划/一键修复-初始化本地网络.md 第一、三、八节）。
///
/// 安卓能做的就三件，只动我们自己的东西：
///  1. 停掉我们的连接（断开 = VPN 服务连同里面的内核一起停）；
///  2. 把本地那份线路（自家订阅）重新下载一遍；
/// 然后：失败处点的「修复并重新连接」、或者之前是连着的 → 接着走一键连接。
/// 开着别家 VPN 不在这里拦（10-17）：连接时系统会把它顶掉，顶不掉由第 4 步说清楚。

/// 修过一次的是哪种失败（'start' 启动连接没成功、'engine' 连接意外断开）。
/// 修完还是同一种失败，就不再给修复按钮，只剩联系客服。确认网通后清空。
final repairedKindProvider = StateProvider<String>((ref) => '');

final localRepairProvider = Provider<LocalRepair>((ref) => LocalRepair(ref));

class LocalRepair {
  LocalRepair(this._ref);

  final Ref _ref;
  bool _running = false;

  /// 失败处的「修复并重新连接」。
  Future<void> repairAndReconnect(String kind) async {
    _ref.read(repairedKindProvider.notifier).state = kind;
    await run(reconnect: true);
  }

  /// 「我的」→「初始化本地网络」：之前连着就重新连上，没连着就停在「尚未连接」。
  Future<String> initialize() {
    final s = _ref.read(connectionNotifierProvider).valueOrNull;
    return run(reconnect: s is Connected || s is Connecting);
  }

  /// 返回给用户看的一句话（做了哪几步）。
  Future<String> run({required bool reconnect}) async {
    if (_running) return '';
    _running = true;
    try {
      final done = <String>[];
      final said = <String>[];
      // 上一次失败留在首页的说法先收掉，这次做完按结果重新说。
      _ref.read(deadLineProvider.notifier).state = false;
      _ref.read(homeFaultProvider.notifier).state = '';
      _ref.read(connectProgressProvider.notifier).state = const ConnectProgress();

      // ① 停掉我们的连接和内核。
      final s = _ref.read(connectionNotifierProvider).valueOrNull;
      final wasUp = s is Connected || s is Connecting;
      if (wasUp) {
        await _ref.read(connectionNotifierProvider.notifier).abortConnection();
        await _untilDown();
        done.add('core');
        said.add('断开连接');
      }

      // ② 本地那份线路重新下载（跟登录时同一条路：拿最新订阅地址，按绑定 ID 更新）。
      if (_ref.read(Preferences.panelLoggedIn)) {
        final url = await _ref.read(panelAuthProvider.notifier).refreshSubscribeUrl();
        if (url != null && url.isNotEmpty) {
          await _ref.read(addProfileNotifierProvider.notifier).addAccountSubscription(url);
          if (_ref.read(addProfileNotifierProvider) is! AsyncError) {
            done.add('nodes');
            said.add('重新获取线路');
          }
        }
      }

      _ref.read(connectReporterProvider).conflictFix = 'repair:${done.join('+')}';
      if (reconnect) _ref.read(connectRequestProvider.notifier).state++;
      return said.join('、');
    } finally {
      _running = false;
    }
  }

  /// 等连接真的停下来（断开一般一两秒）。等不到也往下做：重连那一步自己会看状态。
  Future<void> _untilDown() async {
    bool down(AsyncValue<ConnectionStatus> v) => v is AsyncError || v.valueOrNull is Disconnected;
    if (down(_ref.read(connectionNotifierProvider))) return;
    final stopped = Completer<void>();
    final sub = _ref.listen(connectionNotifierProvider, (_, next) {
      if (down(next) && !stopped.isCompleted) stopped.complete();
    });
    try {
      await stopped.future.timeout(const Duration(seconds: 10), onTimeout: () {});
    } finally {
      sub.close();
    }
  }
}

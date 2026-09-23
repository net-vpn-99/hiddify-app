import 'dart:async';

import 'package:hiddify/features/connection/data/connect_reporter.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 连接稳定性（0~10）。默认满分，探测连着失败才降；恢复即回满。
/// 连接后每 15 秒过隧道跑一次 urlTest（不带震动，见 active_proxy_notifier）。
///
/// **故意做得迟钝**（1.1.29）：客户盯着这行字看，一会儿「很稳」一会儿「一般」比
/// 不显示还糟。所以 —— 偶尔一次探测没回来不降级、切后台再回来不重测也不回
/// 「测量中」、显示只给档位不给分数。真出问题（连着 2 次以上探不通）才降。
class StabilityState {
  const StabilityState(this.score);

  /// 0~10；-1 = 这次连接还没测出过结果
  final int score;

  bool get measuring => score < 0;

  String get label {
    if (score < 0) return '测量中';
    if (score >= 10) return '很稳';
    if (score >= 8) return '稳定';
    if (score >= 6) return '一般';
    if (score >= 4) return '波动';
    return '不稳';
  }
}

/// 上一次测出来的分数，记在模块级。
///
/// App 切后台再回来时连接状态流会先来一拍空值、widget 也可能整棵重建，要是跟着
/// 清零，客户就会看到「稳定性测量中…」再从头测一遍 —— 1.1.28 验收时反馈的就是这个。
int _rememberedScore = -1;

final stabilityProvider =
    NotifierProvider<StabilityNotifier, StabilityState>(StabilityNotifier.new);

class StabilityNotifier extends Notifier<StabilityState> {
  Timer? _timer;
  int _consecFail = 0;
  bool _running = false;

  @override
  StabilityState build() {
    ref.onDispose(() => _timer?.cancel());
    ref.listen(connectionNotifierProvider, (_, next) {
      // 状态还没读出来（loading / 刚回前台）时什么都不做：当成「断开」就会停掉探测，
      // 回来再 _start 一次，客户看到的就是又测一遍。
      final status = next.valueOrNull;
      if (status == null) return;
      final connected = status.isConnected;
      if (connected && !_running) {
        _start();
      } else if (!connected && _running) {
        _stop();
      }
    }, fireImmediately: true);
    return StabilityState(_rememberedScore);
  }

  void _start() {
    _running = true;
    _consecFail = 0;
    // 有上次的分数就先照着显示，探完再更新；没有才是「测量中」。
    state = StabilityState(_rememberedScore);
    _timer?.cancel();
    _probe();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _probe());
  }

  void _stop() {
    _running = false;
    _timer?.cancel();
    // 分数留着不清：断开时首页本来就不显示这一行，下次连上先显示上次结果。
  }

  Future<void> _probe() async {
    if (!_running) return;
    try {
      await ref.read(activeProxyNotifierProvider.notifier).urlTest("", haptic: false);
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    if (!_running) return;
    final delay = ref.read(activeProxyNotifierProvider).valueOrNull?.urlTestDelay ?? 0;
    final ok = delay > 0 && delay < 60000;
    _consecFail = ok ? 0 : _consecFail + 1;

    // First real request through the tunnel this attempt == the connect-trace
    // reporter's stage 8 passed (the "it actually works" signal).
    if (ok) {
      final reporter = ref.read(connectReporterProvider);
      if (reporter.attemptOpen) {
        reporter.markStage(ConnectReporter.stageProxyRequest);
        unawaited(reporter.reportSuccess(delay));
      }
    }

    // 单次没测到不算数（探测本身会被限流、超时、切后台时系统掐后台请求），
    // 连着两次以上才认为线路真的在抖。
    final int g;
    if (_consecFail >= 6) {
      g = 2;
    } else if (_consecFail >= 5) {
      g = 4;
    } else if (_consecFail >= 4) {
      g = 6;
    } else if (_consecFail >= 2) {
      g = 8;
    } else {
      g = 10;
    }
    _rememberedScore = g;
    state = StabilityState(g);
  }
}

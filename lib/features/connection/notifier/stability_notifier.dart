import 'dart:async';

import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 连接稳定性（0~10）。逻辑照搬桌面版：默认满分，探测失败才降；恢复即回满。
/// 连接后每 5 秒过隧道跑一次 urlTest，按连续失败次数打分。
class StabilityState {
  const StabilityState(this.score);

  /// 0~10；-1 = 未连接 / 测量中
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

final stabilityProvider =
    NotifierProvider<StabilityNotifier, StabilityState>(StabilityNotifier.new);

class StabilityNotifier extends Notifier<StabilityState> {
  Timer? _timer;
  int _consecFail = 0;
  bool _warmed = false;
  bool _running = false;

  @override
  StabilityState build() {
    ref.onDispose(() => _timer?.cancel());
    ref.listen(connectionNotifierProvider, (_, next) {
      final connected = next.valueOrNull?.isConnected ?? false;
      if (connected && !_running) {
        _start();
      } else if (!connected && _running) {
        _stop();
      }
    }, fireImmediately: true);
    return const StabilityState(-1);
  }

  void _start() {
    _running = true;
    _consecFail = 0;
    _warmed = false;
    state = const StabilityState(-1);
    _timer?.cancel();
    _probe();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _probe());
  }

  void _stop() {
    _running = false;
    _timer?.cancel();
    state = const StabilityState(-1);
  }

  Future<void> _probe() async {
    if (!_running) return;
    try {
      await ref.read(activeProxyNotifierProvider.notifier).urlTest("");
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    if (!_running) return;
    final delay = ref.read(activeProxyNotifierProvider).valueOrNull?.urlTestDelay ?? 0;
    final ok = delay > 0 && delay < 60000;
    _consecFail = ok ? 0 : _consecFail + 1;
    _warmed = true;

    final int g;
    if (_consecFail >= 5) {
      g = 2;
    } else if (_consecFail >= 4) {
      g = 3;
    } else if (_consecFail >= 3) {
      g = 4;
    } else if (_consecFail >= 2) {
      g = 6;
    } else if (_consecFail >= 1) {
      g = 8;
    } else {
      g = 10;
    }
    state = StabilityState(_warmed ? g : -1);
  }
}

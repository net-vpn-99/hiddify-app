/// 一键连接 5 步的计时（两端统一，Windows 见 ConnectionController::flowTrack）：
///   1 开通账号  2 获取线路  3 选择线路  4 启动连接  5 检查网络
///
/// 只记录每一步用了多久，写进连接上报（step_ms）和 app.log，**不参与任何判断**。
/// 从按下连接（或引擎自己开始连，例如换线路 / 开机自连）开始，连上并确认网通 / 失败 /
/// 取消时结束。老用户前几步一按就是现成的，记 0。
class ConnectFlowClock {
  ConnectFlowClock._();

  static final Stopwatch _sw = Stopwatch();
  static bool _open = false;
  static int _step = 0;
  static final List<int> _doneMs = List.filled(6, -1);

  /// 写 app.log 用（ConnectionNotifier 启动时接上自己的 logger）。
  static void Function(String line)? log;

  static bool get isOpen => _open;
  static int get step => _step;

  static void begin() {
    _open = true;
    _sw
      ..reset()
      ..start();
    _step = 0;
    _doneMs.fillRange(0, 6, -1);
    log?.call('connect flow begin');
  }

  /// 走到第 [step] 步了（前面没走过的步记成「这一刻做完」）。没开着就从这里开一个。
  static void at(int step) {
    if (!_open) begin();
    if (step <= _step) return;
    final now = _sw.elapsedMilliseconds;
    for (var k = _step < 1 ? 1 : _step; k < step; k++) {
      if (_doneMs[k] < 0) {
        _doneMs[k] = now;
        log?.call('connect step $k done +$now ms');
      }
    }
    _step = step;
  }

  /// "120,340,0,2100,800"：每一步用了多少毫秒；正在走的那步算到现在，没走到的是 "-"。
  static String text() {
    if (!_open) return '';
    final now = _sw.elapsedMilliseconds;
    final parts = <String>[];
    var prev = 0;
    for (var k = 1; k <= 5; k++) {
      if (_doneMs[k] >= 0) {
        parts.add('${(_doneMs[k] - prev).clamp(0, 9999999)}');
        prev = _doneMs[k];
      } else if (k == _step) {
        parts.add('${(now - prev).clamp(0, 9999999)}');
        prev = now;
      } else {
        parts.add('-');
      }
    }
    return parts.join(',');
  }

  /// 结束（ok / fail / cancel）。重复调用无害。
  static void end(String how) {
    if (!_open) return;
    log?.call('connect flow $how at step $_step +${_sw.elapsedMilliseconds} ms (${text()})');
    _open = false;
    _sw.stop();
  }

  /// 取消时上报用的步骤名（和服务器的 fail_stage 白名单一致）。
  static String slug(int step) => switch (step) {
    1 => 'account',
    2 => 'nodes',
    3 => 'route_pick',
    4 => 'connect',
    _ => 'verify',
  };
}

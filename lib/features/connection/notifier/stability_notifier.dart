import 'dart:async';

import 'package:hiddify/features/connection/data/connect_reporter.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 连接稳定性（0~10）。默认满分，探测连着失败才降；恢复即回满。
/// 连接后过隧道跑 urlTest（不带震动，见 active_proxy_notifier）：确认通之前每 3 秒一次，
/// 确认之后每 15 秒一次。
///
/// **故意做得迟钝**（1.1.29）：客户盯着这行字看，一会儿「很稳」一会儿「一般」比
/// 不显示还糟。所以 —— 偶尔一次探测没回来不降级、切后台再回来不重测也不回
/// 「测量中」、显示只给档位不给分数。真出问题（连着 2 次以上探不通）才降。
///
/// **两端统一的规则**（和 Windows 一样，见 docs/连上但不通-两端统一-手册.md）：
///  - [confirmed] 之前首页还是「连接中」，第一次探测成功才算「已连接」；
///  - 10 秒一次都不通 → connection_notifier 断开并置 [deadLineProvider]，首页说原因和下一步；
///  - 确认过之后约 1 分钟不通 → [outage]，只提示，不断开、**不换线**。
class StabilityState {
  const StabilityState(this.score, {this.confirmed = false, this.outage = false});

  /// 0~10；-1 = 这次连接还没测出过结果
  final int score;

  /// 这次连接至少有一次经隧道的请求成功了（= 真的通了）
  final bool confirmed;

  /// 确认过之后又连着约 1 分钟不通
  final bool outage;

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

/// 上一次连接「连上了服务器但 10 秒打不开外网、已断开」。首页据此显示原因和下一步；
/// 下次点连接 / 换线路 / 手动关掉时清掉。
final deadLineProvider = StateProvider<bool>((ref) => false);

/// 这次连接已经测通过。记在模块级，和 [_rememberedScore] 一样经得起 widget 重建。
///
/// **切到桌面再回来不能清它**（1.1.46 真机反馈）：回前台时连接状态流会重放一遍
///（先来个「断开」，紧接着「已连接」），隧道其实一直没断。原来一看到「断开」就清掉，
/// 首页于是又从「连接中」测一遍，用户的感觉是「一动它就断」。
/// 现在只有真的在断开（Disconnecting）才立刻清；
/// 单独一个「断开」要持续 2 秒才算数，2 秒内又回到「已连接」就当没发生。
bool _confirmedFlag = false;

class StabilityNotifier extends Notifier<StabilityState> {
  Timer? _timer;
  Timer? _clearTimer;
  int _consecFail = 0;
  bool _running = false;

  bool get _confirmed => _confirmedFlag;
  set _confirmed(bool v) => _confirmedFlag = v;

  @override
  StabilityState build() {
    ref.onDispose(() {
      _timer?.cancel();
      _clearTimer?.cancel();
    });
    ref.listen(connectionNotifierProvider, (_, next) {
      // 状态还没读出来（loading / 刚回前台）时什么都不做：当成「断开」就会停掉探测，
      // 回来再 _start 一次，客户看到的就是又测一遍。
      final status = next.valueOrNull;
      if (status == null) return;
      // 真的在断开（用户点断开 / 重连 / 换订阅都会经过这一步）：「已确认」立刻作废。
      // 不看 Connecting：回前台的重放可能也会带一拍 Connecting。
      if (status is Disconnecting) {
        _clearTimer?.cancel();
        _clearConfirmed();
      }
      final connected = status.isConnected;
      if (connected && !_running) {
        _start();
      } else if (!connected && _running) {
        _stop();
      }
    }, fireImmediately: true);
    return StabilityState(_rememberedScore, confirmed: _confirmedFlag);
  }

  void _clearConfirmed() {
    if (!_confirmed) return;
    _confirmed = false;
    state = StabilityState(_rememberedScore);
  }

  void _start() {
    _running = true;
    _consecFail = 0;
    _clearTimer?.cancel();
    _timer?.cancel();
    if (_confirmed) {
      // 回前台重放出来的「已连接」：之前已经测通过，界面保持「已连接」，照常 15 秒一探。
      state = StabilityState(_rememberedScore, confirmed: true);
      _timer = Timer.periodic(const Duration(seconds: 15), (_) => _probe());
      return;
    }
    // 有上次的分数就先照着显示，探完再更新；没有才是「测量中」。
    state = StabilityState(_rememberedScore);
    _probe();
    // 确认通之前 3 秒一探：首页要尽快从「连接中」变「已连接」，不通的线在 10 秒
    // 截止前也要试够几次。确认后在 _probe 里换成 15 秒。
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _probe());
  }

  void _stop() {
    _running = false;
    _timer?.cancel();
    // 分数留着不清：断开时首页本来就不显示这一行，下次连上先显示上次结果。
    // 「已确认」等 2 秒再清 —— 回前台的重放会在这之前回到「已连接」。
    _clearTimer?.cancel();
    _clearTimer = Timer(const Duration(seconds: 2), () {
      if (!_running) _clearConfirmed();
    });
  }

  bool _probing = false;

  Future<void> _probe() async {
    if (!_running || _probing) return;
    _probing = true;
    try {
      await ref.read(activeProxyNotifierProvider.notifier).urlTest("", haptic: false);
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    _probing = false;
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
      if (!_confirmed) {
        _confirmed = true;
        _timer?.cancel();
        _timer = Timer.periodic(const Duration(seconds: 15), (_) => _probe());
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
    // 15 秒一探，连着 4 次不通 ≈ 1 分钟。
    state = StabilityState(g, confirmed: _confirmed, outage: _confirmed && _consecFail >= 4);
  }
}

import 'dart:async';
import 'dart:io';

import 'package:hiddify/core/http_client/http_client_provider.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/app/notifier/app_foreground.dart';
import 'package:hiddify/features/connection/data/connect_reporter.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 连接稳定性（0~10）。默认满分，探测连着失败才降；恢复即回满。
/// 连接后直接问核心测当前出站（不读界面上那条会断的流）：确认通之前每 3 秒一次，
/// 确认之后每 15 秒一次。没测到（通道断了）不算失败。
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
  const StabilityState(this.score, {this.confirmed = false, this.outage = false, this.egressAudit = ''});

  /// 0~10；-1 = 这次连接还没测出过结果
  final int score;

  /// 这次连接至少有一次经隧道的请求成功了（= 真的通了）
  final bool confirmed;

  /// 确认过之后又连着约 1 分钟不通
  final bool outage;

  /// 诊断报告用：最近一次出口核对。
  final String egressAudit;

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

/// 首页故障原因。空 = 没有。engine / egress / line。
final homeFaultProvider = StateProvider<String>((ref) => '');

class StabilityNotifier extends Notifier<StabilityState> {
  Timer? _timer;
  Timer? _ifaceTimer;
  String _ifaces = '';
  int _consecFail = 0;
  bool _running = false;
  bool _confirmed = false;
  int _gen = 0;
  bool _probing = false;
  final List<String> _probeNotes = [];

  bool get isRunning => _running;

  /// 这次连接的探测结果，最多 10 个，例如 `142,err,timeout`。
  String probeLog() => _probeNotes.join(',');

  @override
  StabilityState build() {
    ref.onDispose(() {
      _timer?.cancel();
      _ifaceTimer?.cancel();
    });
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
    ref.listen<bool>(appForegroundProvider, (prev, next) {
      if (next != true || !_running || _confirmed) return;
      _schedule(immediate: true);
    });
    return StabilityState(_rememberedScore);
  }

  /// Connected 每来一次都重新计。已经确认过的这次连接（状态流重放）不打回「连接中」。
  void restart() {
    if (_running && _confirmed) return;
    _start();
  }

  void _start() {
    _gen++;
    _running = true;
    _consecFail = 0;
    _confirmed = false;
    _probeNotes.clear();
    // 有上次的分数就先照着显示，探完再更新；没有才是「测量中」。
    state = StabilityState(_rememberedScore);
    _schedule(immediate: true);
  }

  void _schedule({required bool immediate}) {
    _timer?.cancel();
    final gen = _gen;
    if (immediate) unawaited(_probe(gen));
    // 确认通之前 3 秒一探：首页要尽快从「连接中」变「已连接」，不通的线在 10 秒
    // 截止前也要试够几次。确认后在 _probe 里换成 15 秒。
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _probe(gen));
    _ifaceTimer?.cancel();
    _ifaceTimer = Timer.periodic(const Duration(seconds: 5), (_) => _watchIfaces(gen));
  }

  void _stop() {
    _gen++;
    _running = false;
    _confirmed = false;
    _timer?.cancel();
    _ifaceTimer?.cancel();
    // 分数留着不清：断开时首页本来就不显示这一行，下次连上先显示上次结果。
    state = StabilityState(_rememberedScore);
  }

  void _note(String token) {
    _probeNotes.add(token);
    if (_probeNotes.length > 10) _probeNotes.removeAt(0);
  }

  Future<void> _watchIfaces(int gen) async {
    if (!_running || gen != _gen || !_confirmed) return;
    try {
      final list = await NetworkInterface.list();
      final now = list.map((n) => n.name).join(',');
      if (_ifaces.isEmpty) {
        _ifaces = now;
        return;
      }
      if (now == _ifaces) return;
      _ifaces = now;
      unawaited(_probe(gen));
    } catch (_) {}
  }

  Future<void> _probe(int gen) async {
    if (!_running || gen != _gen) return;
    if (_probing) return;
    _probing = true;
    _Exit? exit;
    try {
      exit = await _readExit();
    } catch (_) {
      exit = null;
    } finally {
      _probing = false;
    }
    if (gen != _gen || !_running) {
      if (_running && gen != _gen) unawaited(_probe(_gen));
      return;
    }
    final line = ref.read(Preferences.lastNodeName);
    final proved = exit != null && _proves(exit, line);
    final audit = _audit(proved, exit, line);
    if (exit == null) {
      _note('timeout');
    } else {
      _note(proved ? 'ok' : 'err');
    }
    // 还没亮过绿灯时，一次没结果不当失败（接口可能被限流），等下一次。
    if (exit == null && !_confirmed) return;
    _consecFail = proved ? 0 : _consecFail + 1;

    if (proved) {
      final reporter = ref.read(connectReporterProvider);
      if (reporter.attemptOpen) {
        reporter.markStage(ConnectReporter.stageProxyRequest);
        unawaited(reporter.reportSuccess(1));
      }
      if (!_confirmed) {
        _confirmed = true;
        _timer?.cancel();
        _timer = Timer.periodic(const Duration(minutes: 5), (_) => _probe(gen));
      }
    }

    final int g = _consecFail >= 2 ? 4 : 10;
    _rememberedScore = g;
    state = StabilityState(g, confirmed: _confirmed, egressAudit: audit);

    if (!proved && _confirmed && exit != null && exit.cc.toUpperCase() == 'CN') {
      ref.read(homeFaultProvider.notifier).state = 'egress';
      unawaited(ref.read(connectionNotifierProvider.notifier).abortConnection());
      return;
    }
    if (!proved && _confirmed && _consecFail >= 2) {
      ref.read(homeFaultProvider.notifier).state = 'line';
      ref.read(deadLineProvider.notifier).state = true;
      unawaited(ref.read(connectionNotifierProvider.notifier).abortConnection());
    }
  }

  Future<_Exit?> _readExit() async {
    final client = ref.read(httpClientProvider);
    // 本进程被排除在 VPN 之外，直接请求会绕过隧道。走本地 mixed 端口、不指定出站，
    // 和系统流量进隧道后走的是同一套规则。内核停了这个端口也不在。
    for (final url in const ['https://api.ip.sb/geoip', 'https://ipinfo.io/json']) {
      try {
        final res = await client.get<dynamic>(url, proxyOnly: true);
        final data = res.data;
        if (data is! Map) continue;
        final ip = '${data['ip'] ?? ''}'.trim();
        final cc = '${data['country_code'] ?? data['country'] ?? ''}'.trim();
        if (ip.isNotEmpty) return _Exit(ip, cc);
      } catch (_) {}
    }
    return null;
  }

  bool _proves(_Exit exit, String line) {
    final cc = exit.cc.toUpperCase();
    if (cc.isEmpty || cc == 'CN') return false;
    final expect = _countryCode(line);
    return expect.isEmpty || cc == expect;
  }

  String _audit(bool passed, _Exit? exit, String line) {
    final when = DateTime.now().toIso8601String().substring(0, 19).replaceFirst('T', ' ');
    final ip = exit == null || exit.ip.isEmpty ? '无' : exit.ip;
    return '$when  ${passed ? '通过' : '未通过'}  出口 $ip  线路 $line';
  }
}

class _Exit {
  const _Exit(this.ip, this.cc);
  final String ip;
  final String cc;
}

String _countryCode(String line) {
  const codes = {
    '日本': 'JP',
    '美国': 'US',
    '香港': 'HK',
    '新加坡': 'SG',
    '台湾': 'TW',
    '英国': 'GB',
    '韩国': 'KR',
    '德国': 'DE',
    '法国': 'FR',
    '荷兰': 'NL',
  };
  final parts = line.trim().split(RegExp(r'\s+'));
  final word = parts.isEmpty ? '' : parts.first;
  for (final entry in codes.entries) {
    if (word.startsWith(entry.key)) return entry.value;
  }
  return '';
}

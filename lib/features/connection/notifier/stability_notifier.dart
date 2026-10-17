import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hiddify/core/http_client/http_client_provider.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/app/notifier/app_foreground.dart';
import 'package:hiddify/features/connection/data/connect_reporter.dart';
import 'package:hiddify/features/connection/data/drop_notice.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 连接稳定性（0~10）。默认满分，探测连着失败才降；恢复即回满。
/// 连接后经隧道问出口 IP：确认通之前每秒一次（每次最多 4 秒，和 Windows 一样），
/// 确认之后每分钟一次，不通 20 秒后再探一次。10 秒一次都没通由 connection_notifier 断开。
///
/// **故意做得迟钝**（1.1.29）：客户盯着这行字看，一会儿「很稳」一会儿「一般」比
/// 不显示还糟。所以 —— 偶尔一次探测没回来不降级、切后台再回来不重测也不回
/// 「测量中」、显示只给档位不给分数。真出问题（连着 2 次以上探不通）才降。
///
/// **两端统一的规则**（和 Windows 一样，见 docs/连上但不通-两端统一-手册.md）：
///  - [confirmed] 之前首页还是「连接中」，第一次探测成功才算「已连接」；
///  - 10 秒一次都不通 → connection_notifier 断开并置 [deadLineProvider]，首页说原因和下一步；
class StabilityState {
  const StabilityState(this.score, {this.confirmed = false, this.egressAudit = ''});

  /// 0~10；-1 = 这次连接还没测出过结果
  final int score;

  /// 这次连接至少有一次经隧道的请求成功了（= 真的通了）
  final bool confirmed;

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

/// 本次运行里，断开后绕开 VPN 直接碰也没回音的不同节点地址（connection_notifier 填）。
/// 同一时刻我们的接口服务器能连上、这里攒到 2 个 → 首页说「你的网络连不上我们的线路」，
/// 不再叫他换线路（10-13 运营定：查实了才说，两端统一；Windows 见 ConnectionController::onNodeProbed）。
/// 任何一次确认网通就清空。
final unreachableNodesProvider = StateProvider<Set<String>>((ref) => const {});

/// 判「不通」后直连节点是通的那台（体检修复 R2）：线路是好的，是这台手机这边没走通，首页不叫他换线。
final reachableDeadNodeProvider = StateProvider<String?>((ref) => null);

/// 首页故障原因。空 = 没有。engine / egress / line。
final homeFaultProvider = StateProvider<String>((ref) => '');

class StabilityNotifier extends Notifier<StabilityState> {
  Timer? _timer;
  Timer? _ifaceTimer;
  String _ifaces = '';
  int _misses = 0;
  bool _running = false;
  bool _confirmed = false;
  int _gen = 0;
  DateTime? _ifacesChangedAt;   // 网卡最近一次变化（换网络时「没回音」先不算）
  final List<String> _probeNotes = [];
  DateTime? _confirmedAt;

  bool get isRunning => _running;

  /// 这次连接确认网通到现在多少秒（上报「掉线」用）；没确认过是 0。
  int get confirmedSeconds =>
      _confirmedAt == null ? 0 : DateTime.now().difference(_confirmedAt!).inSeconds;

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
      if (next != true || !_running) return;
      if (!_confirmed) {
        _schedule(immediate: true);
        return;
      }
      // 在后台时没回音的那几次不算数（见 _probe）：回到前台重新数，马上探一次。
      if (_misses > 0) {
        _misses = 0;
        unawaited(_probe(_gen));
      }
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
    _misses = 0;
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
    // 确认通之前每秒一探（和 Windows 一样；每一轮自己的连接，不等上一轮）：
    // 隧道一通就立刻亮绿。确认后在 _probe 里换成 30 秒一次。
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _probe(gen));
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
      _ifacesChangedAt = DateTime.now();
      unawaited(_probe(gen));
    } catch (_) {}
  }

  Future<void> _probe(int gen) async {
    if (!_running || gen != _gen) return;
    // 不等上一轮：每一轮都是自己的新连接、到点自己断（_readExit），第一轮卡住不会把后面几轮堵住
    // （体检修复 R1：以前「上一个没回来就不发」，10 秒里常常只回来 1 个结果，能通的线被判成不通）。
    final started = DateTime.now();
    _Exit? exit;
    try {
      exit = await _readExit();
    } catch (_) {
      exit = null;
    }
    if (gen != _gen || !_running) {
      if (_running && gen != _gen) unawaited(_probe(_gen));
      return;
    }
    final line = ref.read(Preferences.lastNodeName);
    final proved = exit != null && _proves(exit, line);
    // 确认网通之前发出、确认之后才超时回来的那几轮：不算「用着时没回音」（不然第一轮卡住、第三轮通了，
    // 前两轮晚到的超时会把刚连上的连接判成断了）。
    final confirmedAt = _confirmedAt;
    if (!proved && _confirmed && confirmedAt != null && started.isBefore(confirmedAt)) return;
    final audit = _audit(proved, exit, line);
    if (exit == null) {
      _note('timeout');
    } else {
      _note(proved ? 'ok' : 'err');
    }
    if (proved) {
      _misses = 0;
      final reporter = ref.read(connectReporterProvider);
      if (reporter.attemptOpen) {
        reporter.markStage(ConnectReporter.stageProxyRequest);
        unawaited(reporter.reportSuccess(1));
      }
      if (!_confirmed) {
        _confirmed = true;
        _confirmedAt = DateTime.now();
      }
      if (ref.read(unreachableNodesProvider).isNotEmpty) {
        ref.read(unreachableNodesProvider.notifier).state = const {};
      }
      _armSteady(gen);
      _rememberedScore = 10;
      state = StabilityState(10, confirmed: true, egressAudit: audit);
      return;
    }

    final cn = exit != null && exit.cc.toUpperCase() == 'CN';
    if (!_confirmed) {
      state = StabilityState(_rememberedScore, egressAudit: audit);
      // 10 秒一直核不到由 connection_notifier 的 _armUnconfirmedDeadline 处理
      // （它先查流量用完、在后台时等回到前台），这里只管出口是国内这一种。
      if (cn) _fault('egress');
      return;
    }

    if (cn) {
      state = StabilityState(4, confirmed: true, egressAudit: audit);
      _fault('egress');
      return;
    }
    // 刚换过网络（换 Wi-Fi / 开关飞行模式 / 从睡眠醒来网卡重连）：这一次不算，重新确认。
    final changedAt = _ifacesChangedAt;
    if (changedAt != null && DateTime.now().difference(changedAt) < const Duration(minutes: 1)) {
      _ifacesChangedAt = null;
      _timer?.cancel();
      _timer = Timer(const Duration(seconds: 3), () => _probe(gen));
      return;
    }
    _misses++;
    state = StabilityState(4, confirmed: true, egressAudit: audit);
    if (_misses >= 2) {
      // App 在后台时手机会限制它联网，探测没回音不等于线路断了：先不断开，照常每分钟探，
      // 回到前台再重新判断。跟「还没确认网通、人在后台」同一条规矩（connection_notifier
      // _armUnconfirmedDeadline）。10-15 查：7 天 25 次「用着用着断了」24 次在后台，
      // 连了几小时被我们自己断开还弹通知。
      if (!ref.read(appForegroundProvider)) {
        _armSteady(gen);
        return;
      }
      _fault('line');
      return;
    }
    // 没换网络：马上再探一次（不等 20 秒），还不回才断开。
    unawaited(_probe(gen));
  }

  /// 确认通之后每 30 秒探一次（一个很小的请求，两端同一套，体检修复 R3）。以前 1 分钟；更早是 5 分钟，
  /// 线路断了最晚要 5 分半才发现（10-12 洛杉矶 05 断网那次）。
  void _armSteady(int gen) {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _probe(gen));
  }

  void _fault(String kind) {
    final reporter = ref.read(connectReporterProvider);
    final stage = kind == 'egress' ? 'egress_mismatch' : 'dead_tunnel';
    if (_confirmed) {
      // 用着用着断的：上一次连接早报过成功了，单报一条「掉线」，再发系统通知。
      final secs = _confirmedAt == null ? 0 : DateTime.now().difference(_confirmedAt!).inSeconds;
      final fg = ref.read(appForegroundProvider) ? '前台' : '后台';
      unawaited(reporter.reportDrop(stage, '已连 $secs 秒｜探测：${probeLog()}｜App 在$fg'));
      final line = ref.read(Preferences.lastNodeName).trim();
      unawaited(DropNotice.show(kind == 'egress'
          ? '网页没有经过光速雷达的线路。打开光速雷达看看怎么办'
          : '${line.isEmpty ? '这条线路' : line} 连不上了。换一条线路试试，或者稍后再点「连接」'));
    } else if (kind == 'egress' && reporter.attemptOpen) {
      // 还没确认网通就发现出口是国内：第 5 步失败（以前被 abortConnection 当成取消丢掉了）。
      unawaited(reporter.reportFailure('出口是国内 IP，流量没走隧道', forcedStage: 'egress_mismatch',
          probeLog: probeLog()));
    }
    if (kind == 'line') ref.read(deadLineProvider.notifier).state = true;
    ref.read(homeFaultProvider.notifier).state = kind;
    unawaited(ref.read(connectionNotifierProvider.notifier).abortConnection());
  }

  /// 问「出口 IP + 国家」的三家，两端同一份（体检修复 R6）。Cloudflare trace 按 IP 地址访问、不用解析域名、
  /// 不按 IP 限流，排第一。我们自己的域名在路由里强制直连、不走隧道，问自家接口拿到的是家里的 IP，不能用。
  static const _exitUrls = [
    'https://1.1.1.1/cdn-cgi/trace',
    'https://api.ip.sb/geoip',
    'https://ipinfo.io/json',
  ];

  Future<_Exit?> _readExit() async {
    // 本进程被排除在 VPN 之外，直接请求会绕过隧道。走本地 mixed 端口、不指定出站，
    // 和系统流量进隧道后走的是同一套规则。内核停了这个端口也不在。
    //
    // 每一轮都用自己的 HttpClient（全新连接、不复用、不自动重试），4 秒到点 close(force) 把 socket 一起掐掉
    // （体检修复 R1）。以前用全局的 HTTP 客户端：连接复用 + 失败自动重试，取消了也没真断，下一轮排在后面。
    final port = ref.read(httpClientProvider).port;
    if (port <= 0) return null;
    final client = HttpClient()
      ..findProxy = ((_) => 'PROXY localhost:$port')
      ..connectionTimeout = const Duration(seconds: 4)
      ..idleTimeout = Duration.zero;
    Future<_Exit?> ask(String url) async {
      try {
        final req = await client.getUrl(Uri.parse(url));
        req.persistentConnection = false;
        final res = await req.close();
        final body = await res.transform(utf8.decoder).join();
        return _parseExit(url, body);
      } catch (_) {
        return null;
      }
    }

    final done = Completer<_Exit?>();
    var pending = _exitUrls.length;
    for (final url in _exitUrls) {
      unawaited(ask(url).then((exit) {
        pending--;
        if (done.isCompleted) return;
        if (exit != null || pending == 0) done.complete(exit);
      }));
    }
    final exit = await done.future.timeout(const Duration(seconds: 4), onTimeout: () => null);
    client.close(force: true);
    return exit;
  }

  /// 三家的回答统一成 (ip, 国家码)：Cloudflare 是文本行 ip=… loc=US，另外两家是 JSON。
  static _Exit? _parseExit(String url, String body) {
    var ip = '';
    var cc = '';
    if (url.contains('cdn-cgi/trace')) {
      for (final line in const LineSplitter().convert(body)) {
        if (line.startsWith('ip=')) ip = line.substring(3).trim();
        if (line.startsWith('loc=')) cc = line.substring(4).trim();
      }
    } else {
      final data = jsonDecode(body);
      if (data is! Map) return null;
      ip = '${data['ip'] ?? ''}'.trim();
      cc = '${data['country_code'] ?? data['country'] ?? ''}'.trim();
    }
    return ip.isEmpty ? null : _Exit(ip, cc);
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

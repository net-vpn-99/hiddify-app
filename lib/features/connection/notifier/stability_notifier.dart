import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hiddify/core/http_client/http_client_provider.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/app/notifier/app_foreground.dart';
import 'package:hiddify/features/connection/data/connect_flow_clock.dart';
import 'package:hiddify/features/connection/data/connect_reporter.dart';
import 'package:hiddify/features/connection/data/drop_notice.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/proxy/data/proxy_data_providers.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service_provider.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 连接稳定性（0~10）。默认满分，探测连着失败才降；恢复即回满。
/// 确认通之前：三家检测网址各问一次（不设超时）+ 每秒读一次经节点回来的字节，字节涨了或拿到 HTTP 回答就算通；
/// 检测连接被结束、节点一个字节没回够 3 条，由 connection_notifier.concludeNoAnswer 下结论（不按秒数，两端统一）。
/// 检测连接在途中切过线路的不算（切线路时内核把正在走的连接全部结束，没到节点），重问一次。
/// 确认之后每 30 秒探一次，不通 5 秒后再探。
///
/// **故意做得迟钝**（1.1.29）：客户盯着这行字看，一会儿「很稳」一会儿「一般」比
/// 不显示还糟。所以 —— 偶尔一次探测没回来不降级、切后台再回来不重测也不回
/// 「测量中」、显示只给档位不给分数。真出问题（连着 2 次以上探不通）才降。
///
/// **两端统一的规则**（和 Windows 一样，见 docs/连上但不通-两端统一-手册.md）：
///  - [confirmed] 之前首页还是「连接中」，第一次探测成功才算「已连接」；
///  - 判出不通（有正面证据）→ connection_notifier 断开并置 [deadLineProvider]，首页说原因和下一步；
class StabilityState {
  const StabilityState(this.score, {this.confirmed = false, this.egressAudit = '', this.offline = false});

  /// 0~10；-1 = 这次连接还没测出过结果
  final int score;

  /// 这次连接至少有一次经隧道的请求成功了（= 真的通了）
  final bool confirmed;

  /// 诊断报告用：最近一次出口核对。
  final String egressAudit;

  /// 用着时没回音、直连一查这台手机自己上不了网：不断开，等网好（Windows 同一句提示）。
  final bool offline;

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

/// 上一次连接「连上了服务器但判出不通、已断开」。首页据此显示原因和下一步；
/// 下次点连接 / 换线路 / 手动关掉时清掉。
final deadLineProvider = StateProvider<bool>((ref) => false);

/// 本次运行里，断开后绕开 VPN 直接碰也没回音的不同节点地址（connection_notifier 填）。
/// 同一时刻我们的接口服务器能连上、这里攒到 2 个 → 首页说「你的网络连不上我们的线路」，
/// 不再叫他换线路（10-13 运营定：查实了才说，两端统一；Windows 见 ConnectionController::onNodeProbed）。
/// 任何一次确认网通就清空。
final unreachableNodesProvider = StateProvider<Set<String>>((ref) => const {});

/// 端口通、节点却把连接结束且零字节的不同线路地址（两条都这样 = 原因不明，主按钮给联系客服）。任何一次确认网通就清空。
final refusedNodesProvider = StateProvider<Set<String>>((ref) => const {});

/// 判「不通」的正面证据：refused = 节点结束了连接、零字节；reality = 节点没认出我们（REALITY 校验失败）。
final deadEvidenceProvider = StateProvider<String>((ref) => '');

/// 首页故障原因。空 = 没有。engine / egress / line。
final homeFaultProvider = StateProvider<String>((ref) => '');

class StabilityNotifier extends Notifier<StabilityState> {
  Timer? _timer;
  Timer? _ifaceTimer;
  String _ifaces = '';
  int _misses = 0;
  DateTime? _firstMissAt;   // 这一串没回音从什么时候开始的（有回音就清空）
  bool _running = false;
  bool _confirmed = false;
  int _gen = 0;
  DateTime? _ifacesChangedAt;   // 网卡最近一次变化（换网络时「没回音」先不算）
  final List<String> _probeNotes = [];
  DateTime? _confirmedAt;
  // 经节点回来的字节（内核按线路记的下载量）；null = 还没读到 / 读不到。判通看它涨没涨，不看过了几秒。
  int? _down;
  // 判通的起点：新连接 0；接回已在跑的连接时取第一次读数（_takeBase）。
  int _base = 0;
  bool _takeBase = false;
  bool get _sentData => (_down ?? 0) > _base;
  // 用着用着检测开始没回音时的字节数：要断开前对一下，涨了说明节点还在回数据，线路没坏。
  int? _downAtMiss;
  // 还没确认通时，被结束且节点一个字节都没回的检测连接（条数、各自原因）。
  int _zeroEnds = 0;
  final List<String> _zeroWhy = [];
  final Set<HttpClient> _warmClients = {};

  /// 第 5 步取消 / 失败时记进上报：节点回了多少字节、几条检测连接被结束（两端统一）。
  String byteDetail() => '节点回了 ${_down ?? 0} 字节，$_zeroEnds 个检测连接被结束';

  /// 被结束的检测连接条数和各自原因（判不通时写进上报）。
  int get zeroEnds => _zeroEnds;
  String zeroWhy() => _zeroWhy.join('；');

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
        _firstMissAt = null;
        unawaited(_probe(_gen));
      }
    });
    return StabilityState(_rememberedScore);
  }

  /// Connected 每来一次都重新计。已经确认过的这次连接（状态流重放）不打回「连接中」。
  /// [attach]：接回已经在跑的连接（App 重开、内核没重启），内核的下载量是之前一直累计的，
  /// 第一次读到的当起点，比它多了才算节点现在在回数据（跟 Windows m_nodeBase 一样）。
  void restart({bool attach = false}) {
    if (_running && _confirmed) return;
    _start();
    _takeBase = attach;
  }

  void _start() {
    _gen++;
    _running = true;
    _misses = 0;
    _firstMissAt = null;
    _confirmed = false;
    _probeNotes.clear();
    _down = null;
    _base = 0;
    _takeBase = false;
    _downAtMiss = null;
    _zeroEnds = 0;
    _zeroWhy.clear();
    _closeWarmClients();
    // 有上次的分数就先照着显示，探完再更新；没有才是「测量中」。
    state = StabilityState(_rememberedScore);
    _schedule(immediate: true);
  }

  /// 确认通之前（两端统一，docs/计划/连上后判通-按节点回数据.md）：三家检测网址同时问一次，**不设超时**
  /// （「没回音」不是证据）；每秒读一次经节点回来的字节（取样），一涨就亮绿。确认后在 _confirm 里换成 30 秒一探。
  void _schedule({required bool immediate}) {
    _timer?.cancel();
    final gen = _gen;
    if (immediate) {
      for (final url in _exitUrls) {
        unawaited(_warmAsk(gen, url));
      }
    }
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _pollBytes(gen));
    _ifaceTimer?.cancel();
    _ifaceTimer = Timer.periodic(const Duration(seconds: 5), (_) => _watchIfaces(gen));
  }

  void _closeWarmClients() {
    for (final c in _warmClients) {
      c.close(force: true);
    }
    _warmClients.clear();
  }

  /// 读一次经节点回来的字节。还没确认通、比起点多：线路是通的，亮绿。
  /// 同一次连接里同一时间只读一份；换了连接（gen 变了）不能拿上一次连接那份当这次的读数。
  Future<void> _pollBytes(int gen) {
    final inflight = _bytesInflight;
    if (inflight != null && _bytesGen == gen) return inflight;
    _bytesGen = gen;
    late final Future<void> f;
    f = _readBytes(gen).whenComplete(() {
      if (identical(_bytesInflight, f)) _bytesInflight = null;
    });
    return _bytesInflight = f;
  }

  Future<void>? _bytesInflight;
  int _bytesGen = -1;

  /// 判不通前最后现读一次：这期间节点回了数据就算通（concludeNoAnswer 用；人在后台等过一阵再判时尤其要）。
  Future<bool> sentDataNow() async {
    final gen = _gen;
    await _pollBytes(gen);
    return gen == _gen && _running && (_confirmed || _sentData);
  }

  Future<void> _readBytes(int gen) async {
    final d = await ref.read(proxyRepositoryProvider).selectedOutboundDownload();
    if (gen != _gen || !_running) return;
    if (d != null) {
      if (_takeBase) {
        _base = d;
        _takeBase = false;
      }
      _down = d;
    }
    if (!_confirmed && _sentData) {
      ConnectFlowClock.log?.call('node answered $d bytes');
      _confirm(gen, _audit(true, null, ref.read(Preferences.lastNodeName), note: '节点回了 $d 字节'));
    }
  }

  /// 确认通之前的一个检测请求（自己的连接，不设超时，只等它自己有结果）。
  Future<void> _warmAsk(int gen, String url) async {
    final port = ref.read(httpClientProvider).port;
    if (port <= 0) return;
    final core = ref.read(hiddifyCoreServiceProvider);
    final switches = core.lineSwitches;
    final client = HttpClient()
      ..findProxy = ((_) => 'PROXY localhost:$port')
      ..idleTimeout = Duration.zero;
    _warmClients.add(client);
    _Exit? exit;
    Object? err;
    // 拿到了 HTTP 回答（哪怕是 429 / 格式认不出）：回答是经节点回来的，线路是通的。
    var answered = false;
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.persistentConnection = false;
      final res = await req.close();
      answered = true;
      final body = await res.transform(utf8.decoder).join();
      exit = _parseExit(url, body);
    } catch (e) {
      err = e;
    } finally {
      client.close(force: true);
      _warmClients.remove(client);
    }
    if (gen != _gen || !_running || _confirmed) return;
    if (!answered) {
      // 发出后 App 切过线路（连上后 auto_line_fixer 切到偏好 / 推荐那条，或用户自己点）：这条是被切线路结束的，
      // 没到节点，不是证据，重问。1.1.67 的 24 份 dead_tunnel 包全是这样（三条同一毫秒结束，离连上 13～50 毫秒）。
      if (core.lineSwitches != switches) {
        ConnectFlowClock.log?.call('probe cut by line switch, ask again: ${Uri.parse(url).host}');
        unawaited(_warmAsk(gen, url));
        return;
      }
      await _warmEnded(gen, url, '$err');
      return;
    }
    final line = ref.read(Preferences.lastNodeName);
    // 出口是国内 = 流量没走隧道。别的情况回答都是经节点来的，线路是通的（出口国家对不上多半是 IP 库标错）。
    if (exit != null && exit.cc.toUpperCase() == 'CN') {
      _note('err');
      state = StabilityState(_rememberedScore, egressAudit: _audit(false, exit, line));
      _fault('egress');
      return;
    }
    _note('ok');
    _confirm(gen, _audit(exit == null || _proves(exit, line), exit, line,
        note: exit == null ? '${Uri.parse(url).host} 有回答' : null));
  }

  /// 一个检测连接自己结束了。先现读一次字节：节点回过数据就不算（线路通，只是这家没答上来）；
  /// 一个字节都没回才记一条，够 3 条（三家同时问的第一轮全被结束）就下结论，不够就把这一家再问一次。
  /// 按条数，不按时间（10-19 实测：账号 / 密钥不对时节点 0.5 秒内就把三条都断了）。
  Future<void> _warmEnded(int gen, String url, String why) async {
    await _pollBytes(gen);
    if (gen != _gen || !_running || _confirmed || _sentData) return;
    _zeroEnds++;
    final short = why.split('\n').first;
    _zeroWhy.add('${Uri.parse(url).host} ${short.length > 80 ? short.substring(0, 80) : short}');
    _note('end');
    ConnectFlowClock.log?.call('probe ended, 0 bytes from node ($_zeroEnds): ${_zeroWhy.last}');
    if (_zeroEnds >= 3) {
      _timer?.cancel();
      unawaited(ref.read(connectionNotifierProvider.notifier).concludeNoAnswer());
    } else {
      unawaited(_warmAsk(gen, url));
    }
  }

  /// 确认通了（检测请求核到出口，或者节点回了数据）：上报成功、亮绿、换成 30 秒一探。
  void _confirm(int gen, String audit) {
    _misses = 0;
    _firstMissAt = null;
    final reporter = ref.read(connectReporterProvider);
    if (reporter.attemptOpen) {
      reporter.markStage(ConnectReporter.stageProxyRequest);
      unawaited(reporter.reportSuccess(1));
    }
    if (!_confirmed) {
      _confirmed = true;
      _confirmedAt = DateTime.now();
      _closeWarmClients();
      // 用着时「没回音但字节在涨」从亮绿这一刻比起（不然亮绿后第一次没回音永远算失败）。
      _downAtMiss = _down;
    }
    if (ref.read(unreachableNodesProvider).isNotEmpty) {
      ref.read(unreachableNodesProvider.notifier).state = const {};
    }
    if (ref.read(refusedNodesProvider).isNotEmpty) {
      ref.read(refusedNodesProvider.notifier).state = const {};
    }
    _armSteady(gen);
    _rememberedScore = 10;
    state = StabilityState(10, confirmed: true, egressAudit: audit);
  }

  void _stop() {
    _gen++;
    _running = false;
    _confirmed = false;
    _timer?.cancel();
    _ifaceTimer?.cancel();
    _closeWarmClients();
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
      _confirm(gen, audit);
      return;
    }

    final cn = exit != null && exit.cc.toUpperCase() == 'CN';
    if (!_confirmed) {
      // 确认通之前判通由 _warmAsk / _pollBytes 管（不按时间），这里只管出口是国内这一种。
      state = StabilityState(_rememberedScore, egressAudit: audit);
      if (cn) _fault('egress');
      return;
    }

    if (cn) {
      state = StabilityState(4, confirmed: true, egressAudit: audit);
      _fault('egress');
      return;
    }
    // 跟 Windows 同一套（R3，finecomb 审查 A-1）：
    //  - 换网络后 1 分钟内的没回音都不算（整整 1 分钟，不是只挡一次：换之前发出的那轮和换网卡时那轮往往都会失败）；
    //  - 没换网络：没回音要持续 30 秒以上（期间 5 秒再探一次、都不通）才断开。以前两次没回音、约 8 秒就断。
    // 检测没回音，但经节点回来的字节比上一次没回音时涨了：节点一直在回数据，线路是通的，
    // 算一次成功（字节在涨就是通，两端统一，Windows healthMissed）。
    final before = _downAtMiss;
    await _pollBytes(gen);
    if (gen != _gen || !_running) return;
    _downAtMiss = _down;
    if (before != null && (_down ?? 0) > before) {
      _misses = 0;
      _firstMissAt = null;
      _armSteady(gen);
      state = StabilityState(10, confirmed: true, egressAudit: audit);
      return;
    }
    final now = DateTime.now();
    final changedAt = _ifacesChangedAt;
    if (changedAt != null && now.difference(changedAt) < const Duration(minutes: 1)) {
      _recheckSoon(gen);
      return;
    }
    _misses++;
    final since = _firstMissAt ??= now;
    state = StabilityState(4, confirmed: true, egressAudit: audit);
    if (_misses >= 2 && now.difference(since) >= const Duration(seconds: 30)) {
      // App 在后台时手机会限制它联网，探测没回音不等于线路断了：先不断开，照常探，
      // 回到前台再重新判断。跟「还没确认网通、人在后台」同一条规矩（connection_notifier
      // concludeNoAnswer）。10-15 查：7 天 25 次「用着用着断了」24 次在后台，
      // 连了几小时被我们自己断开还弹通知。
      if (!ref.read(appForegroundProvider)) {
        _armSteady(gen);
        return;
      }
      // 判线路断之前先看手机自己上不上得了网：上不了网不是线路的事，不断开、重新数，照常探；
      // 网好了探测自己会通（两端统一，Windows fetchExit，E8E6-1021）。
      // 查的时候停掉定时探测（要等系统给结论，可能几十秒），别再叠一轮进来；查完再按结果排下一次。
      _timer?.cancel();
      if (!await ref.read(connectReporterProvider).internetUp()) {
        if (gen != _gen || !_running) return;
        _note('offline');
        _misses = 0;
        _firstMissAt = null;
        state = StabilityState(4, confirmed: true, egressAudit: audit, offline: true);
        _recheckSoon(gen);
        return;
      }
      if (gen != _gen || !_running) return;
      _fault('line');
      return;
    }
    _recheckSoon(gen);
  }

  /// 没回音时 5 秒后再探一次（跟 Windows 用着时 5 秒一探一样）；有回音会换回 30 秒一次（_armSteady）。
  void _recheckSoon(int gen) {
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 5), () => _probe(gen));
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

    // 确认网通之前三家同时问（要快）；确认之后 30 秒一次，先问 Cloudflare，它没答再依次问后两家
    // （节点后面所有人共用一个出口 IP，每次三家都问，ipinfo / ip.sb 很快会限流，真用得上它们时反而答不了。
    // finecomb 审查 A-2，跟 Windows fetchExit 一样依次问）。
    Future<_Exit?> askAll() {
      final done = Completer<_Exit?>();
      var pending = _exitUrls.length;
      for (final url in _exitUrls) {
        unawaited(ask(url).then((exit) {
          pending--;
          if (done.isCompleted) return;
          if (exit != null || pending == 0) done.complete(exit);
        }));
      }
      return done.future;
    }

    Future<_Exit?> askInOrder() async {
      for (final url in _exitUrls) {
        final exit = await ask(url);
        if (exit != null) return exit;
      }
      return null;
    }

    final exit = await (_confirmed ? askInOrder() : askAll())
        .timeout(const Duration(seconds: 4), onTimeout: () => null);
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

  String _audit(bool passed, _Exit? exit, String line, {String? note}) {
    final when = DateTime.now().toIso8601String().substring(0, 19).replaceFirst('T', ' ');
    final ip = exit == null || exit.ip.isEmpty ? '无' : exit.ip;
    return '$when  ${passed ? '通过' : '未通过'}  ${note ?? '出口 $ip'}  线路 $line';
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

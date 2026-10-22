import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/core/directories/directories_provider.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/features/connection/data/connect_check.dart';
import 'package:hiddify/features/connection/data/connect_flow_clock.dart';
import 'package:hiddify/features/connection/data/vpn_permission.dart';
import 'package:hiddify/features/log/data/log_path_resolver.dart';
import 'package:hiddify/features/panel_auth/data/panel_api_base.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/model/node_display.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path/path.dart' as p;

/// Reports one row per connect attempt to the panel (GslInviteBonus's
/// `POST /api/v1/guest/gsl_connect/report`) so the server can see which of the
/// eight stages an attempt got stuck on. Mirrors the Windows client's
/// ConnectReporter -- see D:/VPN/docs/连接轨迹采集-数据协议.md.
///
///  - fail_stage is a raw observation ("node_tcp = TCP never opened"), never a
///    verdict; no auto-attribution.
///  - the lightweight attempt row is sent on every terminal outcome (ok + fail)
///    so the failure-rate denominator is real; the heavy bundle is separately
///    rate-limited and its loss never drops the attempt row.
///  - upload must survive a dead VPN: primary apiBase, then api-hk direct, then
///    an on-disk queue flushed on the next attempt. attempt_id dedupes.
///  - no toast. Surfaces only on the diagnostics screen.
///
/// 1.1.6:
///  - node_tag = the actually-selected outbound tag (resolved from the local
///    profile), not the subscription name; the subscription name goes in
///    sub_name. host/port of that outbound are kept for the TCP probe.
///  - on failure: snapshot box.log synchronously (a reconnect truncates it),
///    then actively TCP-probe the node and report dest / ms / errno / err
///    directly -- not only via the core log.
///  - the report carries the panel Authorization token so the server binds the
///    attempt to the real account instead of trusting a self-reported email.
class ConnectReporter {
  ConnectReporter(this._ref);

  final Ref _ref;

  static const int stageSubRequested = 1;
  static const int stageSubDownloaded = 2;
  static const int stageNodesParsed = 3;
  static const int stageCoreStarted = 4;
  static const int stageTunnelReady = 5;
  static const int stageNodeTcp = 6;
  static const int stageNodeTls = 7;
  static const int stageProxyRequest = 8;

  static const String _fallbackApiBase = Constants.panelApiBase;
  static const String _reportPath = '/api/v1/guest/gsl_connect/report';
  static const int _queueMax = 10;
  static const int _queueTtlSecs = 3 * 24 * 3600;
  static const int _bundleMaxPerDay = 3;

  String? _attemptId;
  // 这次连接点下去那一刻别的 VPN 在不在。只有用户点按钮那条流程查过（ConnectFlowClock 开着）才有值；
  // 自动重连没查过，不报（以前报的是上一次点按钮时的旧值。code-review 第 5 条）。
  bool? _otherVpn;
  String _subName = '';
  String _nodeTag = '';
  String? _nodeHost;
  int? _nodePort;
  int _reached = 0;
  bool _done = false;
  bool _snapDone = false;
  DateTime _startedAt = DateTime.now();
  Map<String, dynamic> _sub = {};
  Map<String, dynamic>? _tcp;
  Map<String, dynamic>? _tunnel;

  // 一键修复 / 初始化本地网络做了什么（「repair:core+nodes+vpn」），跟下一次连接的结果一起报，
  // 报完清掉（两端统一，Windows 见 ConnectReporter::attachConflictFix；服务器 GslStats 1.25.0 存 fix 列）。
  String conflictFix = '';

  // "", "sent", "queued", "failed" -- read by the diagnostics screen.
  String state = '';
  String code = '';

  bool get attemptOpen => _attemptId != null && !_done;

  Dio _dio(String baseUrl) => Dio(
        BaseOptions(
          baseUrl: baseUrl,
          connectTimeout: const Duration(seconds: 12),
          receiveTimeout: const Duration(seconds: 12),
          sendTimeout: const Duration(seconds: 12),
          validateStatus: (_) => true,
          headers: {'User-Agent': 'OneRay-Android'},
        ),
      );

  String primaryApiBase() => PanelApiBase.current;

  /// 最近一次连接用的节点（上报结束后 _nodeHost 会清掉，这两个留着给断开后的直接探测）。
  String? lastNodeHost;
  int? lastNodePort;

  /// 断开（VPN 已经拆掉）之后直接碰一下刚才的节点；碰不到再看这台手机自己上不上得了网（接口服务器或百度，有一个通就算）。
  /// [tcp] 是补进失败记录的那段（节点那一下 + 接口服务器通不通 + 能不能上网）。
  Future<({bool nodeOk, bool online, Map<String, dynamic> tcp})> probeLastNodeDirect() async {
    final host = lastNodeHost;
    final port = lastNodePort;
    if (host == null || port == null) return (nodeOk: false, online: true, tcp: <String, dynamic>{});
    final node = await probeTcp(host, port);
    if (node['ok'] == true) return (nodeOk: true, online: true, tcp: node);
    final net = await _internet(waitBoth: true);
    if (net.apiOk != null) node['api_ok'] = net.apiOk;
    node['online'] = net.online;
    return (nodeOk: false, online: net.online, tcp: node);
  }

  /// 这台手机自己能不能上网：直接碰接口服务器和百度（本进程不走 VPN），有一个通就算。不自己计时，等系统给结论。
  /// 判「线路断了」之前先问它：上不了网（Wi-Fi 刚断、进电梯）不是线路的事（两端统一，Windows probeInternet，E8E6-1021）。
  Future<bool> internetUp() async => (await _internet()).online;

  /// 接口服务器和百度同时碰（真没网时只等一轮系统超时）。apiOk = null：接口地址读不出来，没碰。
  /// [waitBoth] = false：哪个先通就算能上网，不等另一个（接口服务器被墙时它要等满一轮系统超时，判没网不能跟着等）；
  /// true：两个都等完（失败记录里要接口服务器那一下）。Windows InternetReachable 同一套。
  Future<({bool online, bool? apiOk})> _internet({bool waitBoth = false}) async {
    final api = Uri.tryParse(primaryApiBase());
    final probes = <Future<bool>>[
      probeTcp(onlineProbeHost, 443).then((r) => r['ok'] == true),
      if (api != null && api.host.isNotEmpty) probeTcp(api.host, api.hasPort ? api.port : 443).then((r) => r['ok'] == true),
    ];
    if (!waitBoth) {
      final first = Completer<bool>();
      var left = probes.length;
      for (final f in probes) {
        unawaited(f.then((ok) {
          left--;
          if (!first.isCompleted && (ok || left == 0)) first.complete(ok);
        }));
      }
      return (online: await first.future, apiOk: null);
    }
    final results = await Future.wait(probes);
    final apiOk = results.length > 1 ? results[1] : null;
    return (online: results.any((ok) => ok), apiOk: apiOk);
  }

  /// 上一条失败记录（不带诊断包），给 [amendFailure] 补直连节点的结果用。
  Map<String, dynamic>? _lastFail;

  /// 失败已经先发出去了（不等直连节点）；直连结果回来后用同一个 attempt_id 再报一次，服务器按它更新那一条。
  /// [fault]：直连结果让原因细分了（没上网 = offline）。标成补报（amend）：服务器只让补报改已经记下的原因，
  /// 排队后到的原报改不回去（Windows 同一套）。
  Future<void> amendFailure(Map<String, dynamic> tcp, {String? fault}) async {
    final payload = _lastFail;
    _lastFail = null;
    if (payload == null || tcp.isEmpty) return;
    payload['tcp'] = tcp;
    payload['amend'] = true;
    if (fault != null) payload['fault'] = fault;
    await _send(payload, null);
  }

  String _host(String url) => Uri.tryParse(url)?.host ?? url;

  /// 按 Unicode 码位截断，不按 UTF-16 code unit（`String.substring` 那样）——线路名
  /// 里如果带旗帜 emoji 之类的代理对（surrogate pair），`substring` 在半路切开会产生
  /// 悬空代理位，编码/显示时炸成乱码或问号（"适?" 那种）。
  static String _truncateRunes(String s, int maxChars) {
    if (s.length <= maxChars) return s; // UTF-16 长度已经 <= 上限，码位数只会更少，直接放行
    final runes = s.runes.toList();
    return runes.length <= maxChars ? s : String.fromCharCodes(runes.take(maxChars));
  }

  Directory? _workingDirSync() {
    try {
      return _ref.read(appDirectoriesProvider).requireValue.workingDir;
    } catch (_) {
      return null;
    }
  }

  Future<Directory?> _workingDir() async => _workingDirSync();

  String? _email() {
    try {
      final e = _ref.read(panelAuthProvider).email;
      return (e != null && e.isNotEmpty) ? e : null;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _panelToken() async {
    try {
      final t = await _ref.read(panelAuthProvider.notifier).currentToken();
      return (t != null && t.isNotEmpty) ? t : null;
    } catch (_) {
      return null;
    }
  }

  String _version() {
    try {
      return _ref.read(appInfoProvider).requireValue.version;
    } catch (_) {
      return '';
    }
  }

  // -------------------------------------------------------------- lifecycle

  /// [subName] is the active profile / subscription name ("光速").
  /// [preferredLine] is Preferences.preferredLineName -- the line the user
  /// picked on the home card, if any; used to resolve which outbound (and thus
  /// which host:port) this attempt will actually dial.
  Future<void> beginAttempt(String subName, {String? preferredLine}) async {
    _attemptId = _mintId();
    _otherVpn = ConnectFlowClock.isOpen ? VpnPermission.otherVpnBeforeConnect : null;
    _subName = _truncateRunes(subName, 64);
    _startedAt = DateTime.now();
    _done = false;
    _snapDone = false;
    _tcp = null;
    _tunnel = null;
    state = '';
    code = '';

    final node = await resolveNode(preferredLine);
    _nodeTag = _truncateRunes(node.tag, 64);
    _nodeHost = node.host;
    _nodePort = node.port;
    lastNodeHost = node.host;
    lastNodePort = node.port;

    _sub = await _readSubFetch();
    final subStage = _sub.remove('_stage') as int? ?? 0;
    _reached = subStage > 0 ? subStage : stageNodesParsed;

    unawaited(flushQueue());
    unawaited(_sendPending());
  }

  /// 一开始连就先报一条「进行中」（GslStats 1.31.0）。以前只在出结果时报：点了连接就切走、App 被系统停掉、
  /// 一直没等到确认的那些连接一条都不记（10-17 体检：近 7 天至少 25 台有几十 MB～8.5 GB 流量却没有连接记录）。
  /// 出了结果按 attempt_id 覆盖这一条；服务器不会让「进行中」盖回已有的结果。发不出去就算了（不排队、不改诊断页状态）。
  Future<void> _sendPending() async {
    if (_attemptId == null) return;
    final payload = _basePayload('pending')..['reached_stage'] = _reached;
    try {
      await _post(primaryApiBase(), payload, await _panelToken());
    } catch (_) {}
  }

  void markStage(int stage) {
    if (attemptOpen && stage > _reached) _reached = stage;
  }

  void abandon() {
    _attemptId = null;
    _done = true;
  }

  /// Synchronous, cheap, idempotent. Call the instant a failure is observed --
  /// before any retry `start()` truncates box.log.
  ///
  /// 1.1.11：以前 box.log 为空/还不存在时直接放弃、不建 snap —— 于是 `_buildBundle()`
  /// 后来（异步，可能已经是几秒/几次重试之后）去读 live box.log，读到的是那之后又被
  /// 覆盖的内容，包里显示 `source: live` + 内容对不上失败那一刻。现在无论 box.log
  /// 当下是空是满，都立刻落一份快照（没有源文件就写个空快照），保证 `_buildBundle()`
  /// 一定读快照、不读 live，快照内容对应失败那一刻的真实状态（哪怕是"当时确实是空的"）。
  void captureCoreLogSync() {
    if (_snapDone) return;
    try {
      final dir = _workingDirSync();
      if (dir == null) return;
      final src = File(LogPathResolver.corePath(dir));
      final dst = File(p.join(dir.path, 'box.log.snap'));
      if (src.existsSync()) {
        // 只拷末尾 256KB（诊断包里也只放末尾）：这里在界面线程上同步跑，整份十几 MB 拷会卡住
        final raf = src.openSync();
        try {
          final len = raf.lengthSync();
          raf.setPositionSync(len > _snapBytes ? len - _snapBytes : 0);
          dst.writeAsBytesSync(raf.readSync(_snapBytes));
        } finally {
          raf.closeSync();
        }
      } else {
        dst.writeAsStringSync('');
      }
      _snapDone = true;
    } catch (_) {}
  }

  static const _snapBytes = 256 * 1024;

  /// 这次连接的内核日志从哪里算起（连上那一刻的文件长度）。快捷开关 / 开机自动连起的连接不清日志，
  /// 前面那段是上一次连接的，判「不通」找证据不能读到它（10-22 自检）。
  int _coreLogFrom = 0;

  void markCoreLogStart() {
    try {
      final dir = _workingDirSync();
      if (dir == null) return;
      final f = File(LogPathResolver.corePath(dir));
      _coreLogFrom = f.existsSync() ? f.lengthSync() : 0;
    } catch (_) {
      _coreLogFrom = 0;
    }
  }

  /// 这次连接的内核日志（连上之后那段的末尾 64KB）里有没有这句（不分大小写）。判「不通」找正面证据用，
  /// 比如 REALITY 校验失败（节点没认出我们）。
  Future<bool> coreLogHas(String needle) async {
    final dir = _workingDirSync();
    if (dir == null) return false;
    final text = await _tail(LogPathResolver.corePath(dir), 2000, 64 * 1024, from: _coreLogFrom);
    return text.toLowerCase().contains(needle.toLowerCase());
  }

  Future<void> reportSuccess(int proxyMs) async {
    if (!attemptOpen) return;
    _done = true;
    _reached = stageProxyRequest;

    final payload = _basePayload('ok')
      ..['reached_stage'] = stageProxyRequest
      ..['proxy'] = {'result': 'ok', 'ms': max(0, proxyMs)}
      ..['egress'] = {'result': 'unknown'};
    if (_sub.isNotEmpty) payload['sub'] = _sub;
    ConnectFlowClock.end('ok');
    await _send(payload, null);
  }

  /// [forcedStage] skips the guesswork (`_mapFailStage`) for call sites that
  /// already know exactly which stage this is -- e.g. the 15s-no-traffic-after-
  /// Connected timeout is `proxy_request` by definition, not a guess from an
  /// error string that never mentions "timeout".
  ///
  /// [tunnelVpnPermission] / [tunnelNote] let the caller (which has the typed
  /// `ConnectionFailure`, not just its stringified message) tell us precisely
  /// what happened when the stage turns out to be `tunnel` -- see
  /// ConnectionNotifier's error handler.
  Future<void> reportFailure(
    String engineError, {
    String? forcedStage,
    String? tunnelVpnPermission,
    String? tunnelNote,
    bool? appForeground,
    String? probeLog,
    String? fault,
    bool probeNode = true,
  }) async {
    if (!attemptOpen) return;
    _done = true;

    captureCoreLogSync();
    // 每步用时现在就取：下面的 TCP 探测要好几秒，计时不能算到那时候。
    final steps = ConnectFlowClock.text();
    ConnectFlowClock.end('fail');

    var failStage = forcedStage ?? _mapFailStage(engineError, _reached);

    // Active TCP probe: whenever we got at least as far as tunnel takeover, or
    // the mapped stage is node-level, probe the node ourselves so we record the
    // dest / latency / OS error code / text directly, not only via the core log.
    // [probeNode] = false：调用方失败后自己会直连节点（connection_notifier._probeDeadLineDirect），这里不再碰一遍——
    // 直连不自己计时、要等系统的 TCP 超时（安卓最长约 2 分钟），等它的话这条失败要很久才发出去，他走了就丢了。
    if (probeNode &&
        _tcp == null &&
        _nodeHost != null &&
        _nodePort != null &&
        (_reached >= stageTunnelReady ||
            failStage == 'node_tcp' ||
            failStage == 'node_tls' ||
            failStage == 'proxy_request')) {
      _tcp = await probeTcp(_nodeHost!, _nodePort!);
    }
    // 探测已经证明裸 TCP 是通的，就不能再标 node_tcp（那是"没通"的意思）——大概率是
    // 后面 TLS/urltest 那一步的超时被落到了这个格子里，改成 proxy_request 更贴近事实。
    if (failStage == 'node_tcp' && _tcp?['ok'] == true) {
      failStage = 'proxy_request';
    }

    if (failStage == 'tunnel') {
      _tunnel = await _buildTunnelDiag(tunnelVpnPermission ?? 'unknown', tunnelNote ?? engineError);
    }

    final payload = _basePayload('fail')
      ..['fail_stage'] = failStage
      ..['reached_stage'] = _reached;
    if (steps.isNotEmpty) payload['step_ms'] = steps;
    if (appForeground != null) payload['app_fg'] = appForeground;
    if (probeLog != null && probeLog.isNotEmpty) payload['probe_n'] = probeLog;
    // 诊断结论（dead_tunnel / reality_mismatch …），服务器据此标「原因不明」（两端统一，Windows 的 fault）。
    if (fault != null && fault.isNotEmpty) payload['fault'] = fault;
    if (_sub.isNotEmpty) payload['sub'] = _sub;
    if (_tcp != null) payload['tcp'] = _tcp;
    final errMsg = _errMsg(engineError);
    if (errMsg.isNotEmpty) payload['err_msg'] = errMsg;

    _lastFail = Map.of(payload);
    String? bundle;
    final sig = '$failStage|$_nodeTag|${_host(primaryApiBase())}';
    if (await _bundleRateLimitOk(sig)) {
      bundle = await _buildBundle(failStage);
    }
    await _send(payload, bundle);
  }

  /// 后台「客户端报错」一列：引擎原始报错去换行、截 240 字。先抹掉 UUID 和长串密钥，
  /// 免得订阅 uuid / token 混在报错里被存下来。
  static String _errMsg(String raw) {
    var s = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    s = s.replaceAll(RegExp('[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'), '<uuid>');
    s = s.replaceAll(RegExp(r'[A-Za-z0-9_\-]{32,}'), '<key>');
    return s.length > 240 ? s.substring(0, 240) : s;
  }

  /// tunnel 阶段的诊断：VPN 授权状态 / 是否疑似被别的 VPN 占用 / 路由是否起来 / 一句话原因。
  /// 只在诊断包（bundle）里带，不进轻量上报行——不改 attempts 表结构。
  Future<Map<String, dynamic>> _buildTunnelDiag(String vpnPermission, String note) async {
    return {
      'mode': 'tun',
      'vpn_permission': vpnPermission,
      'other_vpn': await _detectOtherVpn(),
      // Connected 事件（markStage(tunnelReady)）证明 TUN + 路由已经起来；没到那一步就是没起来。
      'route_ok': _reached >= stageTunnelReady,
      'note': note.length > 200 ? note.substring(0, 200) : note,
    };
  }

  /// 粗略探测：这次失败时，本机是不是已经有一个别的 VPN/隧道接口在跑。只在我们自己的
  /// TUN 肯定还没起来时（tunnel 阶段失败，_reached < tunnelReady）这个信号才可信——
  /// 探测不了 / 拿不到网络接口列表就报 unknown，不瞎猜。
  Future<String> _detectOtherVpn() async {
    try {
      final ifaces = await NetworkInterface.list();
      for (final i in ifaces) {
        final n = i.name.toLowerCase();
        if (n.startsWith('tun') || n.startsWith('ppp') || n.startsWith('utun') || n.contains('vpn')) {
          return 'yes';
        }
      }
      return 'no';
    } catch (_) {
      return 'unknown';
    }
  }

  /// Connect was pressed but there is no profile and a resync did not fix it.
  /// The last subscription fetch is why.
  Future<void> reportNoRoute() => reportStepFailure(2, 'sub_download', '没有可用线路（没有订阅）');

  /// 一键连接在前三步就停了（开通账号 / 获取线路 / 选择线路）：还没有连接尝试，单开一条。
  /// 第 2 步以最近一次拉订阅的结果为准（sub_download / sub_parse），[stageHint] 是兜底。
  Future<void> reportStepFailure(int step, String stageHint, String message) async {
    final steps = ConnectFlowClock.text();
    ConnectFlowClock.end('fail');
    _attemptId = _mintId();
    _startedAt = DateTime.now();
    _done = true;
    _snapDone = false;
    _tcp = null;
    _nodeTag = '';
    _nodeHost = null;
    _nodePort = null;
    var stage = stageHint;
    var reached = step >= 3 ? stageNodesParsed : 0;
    _sub = {};
    if (step == 2) {
      _sub = await _readSubFetch();
      reached = _sub.remove('_stage') as int? ?? 0;
      stage = _sub.remove('_fail_stage') as String? ?? stageHint;
    }
    final payload = _basePayload('fail')
      ..['fail_stage'] = stage
      ..['reached_stage'] = reached;
    if (steps.isNotEmpty) payload['step_ms'] = steps;
    final errMsg = _errMsg('第 $step 步：$message');
    if (errMsg.isNotEmpty) payload['err_msg'] = errMsg;
    if (_sub.isNotEmpty) payload['sub'] = _sub;
    ConnectFlowClock.log?.call('connect step $step failed ($stage): $message');
    // 前三步停下的也带诊断包（照常限流，两端统一，Windows 0.4.48 同改）：以前不带，
    // 卡在开号 / 拿线路的人服务器上只有一行字，看不到日志。
    String? bundle;
    if (await _bundleRateLimitOk('$stage|step$step|${_host(primaryApiBase())}')) {
      bundle = await _buildBundle(stage);
    }
    await _send(payload, bundle);
  }

  /// 连接过程中他自己点了取消。[stepSlug]：account / nodes / route_pick / connect / verify。
  /// 第 4、5 步连接尝试已经开着，就记到那一条上（不再悄悄丢掉）。
  /// [detail]：比如第 5 步取消时节点回了多少字节（跟 Windows 一样记进 err_msg）。
  Future<void> reportCancel(String stepSlug, {String? detail}) async {
    final steps = ConnectFlowClock.text();
    ConnectFlowClock.end('cancel');
    final open = attemptOpen;
    if (!open) {
      _attemptId = _mintId();
      _startedAt = DateTime.now();
      _nodeTag = '';
      _sub = {};
    }
    _done = true;
    final payload = _basePayload('cancel')
      ..['fail_stage'] = stepSlug
      ..['reached_stage'] = open ? _reached : 0;
    if (steps.isNotEmpty) payload['step_ms'] = steps;
    if (detail != null && detail.isNotEmpty) payload['err_msg'] = _errMsg(detail);
    ConnectFlowClock.log?.call('connect cancelled at $stepSlug');
    await _send(payload, null);
  }

  /// 连上（已确认网通）之后又断了：[kind] 是哪项检查判的（engine_gone / dead_tunnel /
  /// egress_mismatch），[detail] 写已连多久、探测结果、前后台。不算连接失败率（outcome=drop），
  /// 线路沿用上一次连接的。也带一份诊断包（同样限频）。
  Future<void> reportDrop(String kind, String detail) async {
    _attemptId = _mintId();
    _startedAt = DateTime.now();
    _done = true;
    _snapDone = false;
    _tcp = null;
    _reached = stageProxyRequest;
    captureCoreLogSync();
    final payload = _basePayload('drop')
      ..['fail_stage'] = kind
      ..['reached_stage'] = stageProxyRequest;
    payload.remove('step_ms');
    if (_tcp != null) payload['tcp'] = _tcp;
    final errMsg = _errMsg(detail);
    if (errMsg.isNotEmpty) payload['err_msg'] = errMsg;
    ConnectFlowClock.log?.call('connection dropped ($kind): $detail');
    String? bundle;
    if (await _bundleRateLimitOk('drop|$kind|$_nodeTag')) bundle = await _buildBundle(kind);
    await _send(payload, bundle);
  }

  // -------------------------------------------------------------- payload

  // ---- 打开程序到线路就绪多久（体检修复 R7，boot_ms）：只跟打开程序后的第一次连接报一次 ----
  static DateTime appLaunchedAt = DateTime.now();   // bootstrap 一开头改成真正的启动时刻
  static int? _bootMs;
  static bool _bootSent = false;

  /// 打开程序后第一次「账号和线路都备好了」（开号 / 读账号跑完）。只记第一次。
  static void noteLinesReady() {
    _bootMs ??= DateTime.now().difference(appLaunchedAt).inMilliseconds;
  }

  Map<String, dynamic> _basePayload(String outcome) {
    final m = <String, dynamic>{
      'attempt_id': _attemptId,
      'outcome': outcome,
      // 事情发生的时间（排队几天后才补发的，服务器按这个记时间，不按到达时间）
      'occurred_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'platform': 'android',
      'app_ver': _version(),
      'os': '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      'apibase': _host(primaryApiBase()),
    };
    if ((outcome == 'ok' || outcome == 'fail') && conflictFix.isNotEmpty) {
      m['conflict_fix'] = conflictFix;
      conflictFix = '';
    }
    if ((outcome == 'ok' || outcome == 'fail') && _bootMs != null && !_bootSent) {
      m['boot_ms'] = _bootMs;
      _bootSent = true;
    }
    // 点连接那一刻手机上别的 VPN 在不在（体检修复 R7，以前只在诊断包里）。
    final otherVpn = _otherVpn;
    if ((outcome == 'ok' || outcome == 'fail') && otherVpn != null) m['other_vpn'] = otherVpn;
    if (_nodeTag.isNotEmpty) m['node_tag'] = _nodeTag;
    if (_subName.isNotEmpty) m['sub_name'] = _subName;
    final steps = ConnectFlowClock.text();
    if (steps.isNotEmpty) m['step_ms'] = steps;
    // Fallback only -- the server prefers the account resolved from the token.
    final e = _email();
    if (e != null) m['email'] = e;
    // 上报时的配额状态（GslInviteBonus 1.22.0）——让服务端把「流量用完 / 会员到期」
    // 这类失败单独归类，不计节点失败率、不触发告警。
    try {
      final acc = _ref.read(panelAuthProvider).account;
      if (acc != null) m['account_state'] = acc.stateSlug;
    } catch (_) {}
    return m;
  }

  String _mintId() {
    final r = Random();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    String h(int i) => b[i].toRadixString(16).padLeft(2, '0');
    return '${h(0)}${h(1)}${h(2)}${h(3)}-${h(4)}${h(5)}-${h(6)}${h(7)}-'
        '${h(8)}${h(9)}-${h(10)}${h(11)}${h(12)}${h(13)}${h(14)}${h(15)}';
  }

  // Raw observation, not a verdict. Trust a specific message; otherwise fall
  // back to the furthest stage reached.
  static String _mapFailStage(String err, int reached) {
    final e = err.toLowerCase();
    bool has(String s) => e.contains(s);

    if (has('missingvpnpermission') ||
        has('vpn permission') ||
        has('missingprivilege') ||
        has('permission denied') ||
        has('prepare') ||
        has('tun ') ||
        has('route')) {
      return 'tunnel';
    }
    if (has('missingnotificationpermission') ||
        has('backgroundcorenotavailable') ||
        has('start service') ||
        has('starting background core') ||
        has('foreground') ||
        has('panic') ||
        has('core') ||
        // gRPC UNAVAILABLE (code 14) = the core's gRPC endpoint is not up yet.
        // Happens on the very first connect of a fresh install, before the
        // Android VPN-permission grant lets the tunnel service start.
        has('grpc') ||
        has('unavailable') ||
        has('code: 14')) {
      // `_reached` already proves core_started fired (Connecting() event) -- a
      // core-flavored error string after that point can't still be "core never
      // started", it's the next stage (tunnel) misbehaving. Self-contradictory
      // otherwise: trace shows "core_started: ok" immediately followed by
      // "core_start: fail".
      return reached >= stageCoreStarted ? 'tunnel' : 'core_start';
    }
    if (has('invalidconfig') ||
        has('parse') ||
        has('unmarshal') ||
        has('invalid json') ||
        has('decode') ||
        has('no outbound') ||
        has('empty config')) {
      return 'sub_parse';
    }
    if (has('请先登录') || has('unauthor') || has('401') || has('403') || has('获取订阅失败')) {
      return 'sub_download';
    }
    if (has('no route to host') ||
        has('connection refused') ||
        has('dial tcp') ||
        has('network is unreachable')) {
      return 'node_tcp';
    }
    if (has('tls') || has('handshake') || has('certificate') || has('reality')) {
      return 'node_tls';
    }
    if (has('i/o timeout') || has('context deadline') || has('timeout')) {
      return reached >= stageNodeTls ? 'proxy_request' : 'node_tcp';
    }

    if (reached >= stageNodeTls) return 'proxy_request';
    if (reached >= stageNodeTcp) return 'node_tls';
    if (reached >= stageTunnelReady) return 'node_tcp';
    if (reached >= stageCoreStarted) return 'tunnel';
    return 'unknown';
  }

  // -------------------------------------------------------------- selected node

  /// Read the local profile config and work out which outbound this attempt
  /// will dial (and its host:port). Fully offline -- does not need the core.
  Future<({String tag, String? host, int? port})> resolveNode(String? preferred) async {
    final pref = (preferred ?? '').trim();
    final nodes = await configNodes();
    if (nodes.isEmpty) return (tag: pref, host: null, port: null);
    if (pref.isNotEmpty) {
      for (final n in nodes) {
        if (splitNodeName(n.tag).name == pref) return n;
      }
    }
    return nodes.first;
  }

  /// 订阅里的全部节点（按订阅里的顺序）。连接检查按名字精确找：找不到就是找不到，不拿第一条顶。
  Future<List<({String tag, String? host, int? port})>> configNodes() async {
    try {
      final profile = await _ref.read(activeProfileProvider.future);
      if (profile == null) return const [];
      final repo = await _ref.read(profileRepositoryProvider.future);
      final raw = await repo.getRawConfig(profile.id).getOrElse((_) => '').run();
      return _nodesFromConfig(raw);
    } catch (_) {
      return const [];
    }
  }

  static const _nonNodeTypes = {
    'selector', 'urltest', 'loadbalance', 'loadbalancer',
    'direct', 'block', 'dns', 'dns-out',
  };

  List<({String tag, String? host, int? port})> _nodesFromConfig(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return const [];

    // 1) sing-box JSON (hiddify-core stores the generated config here)
    try {
      final obj = jsonDecode(text);
      if (obj is Map && obj['outbounds'] is List) {
        final nodes = <({String tag, String? host, int? port})>[];
        for (final ob in obj['outbounds'] as List) {
          if (ob is! Map) continue;
          final type = (ob['type'] ?? '').toString().toLowerCase();
          final tag = (ob['tag'] ?? '').toString();
          if (tag.isEmpty || _nonNodeTypes.contains(type) || isAutoGroupTag(tag)) {
            continue;
          }
          final server = (ob['server'] ?? '').toString();
          final port = (ob['server_port'] is num) ? (ob['server_port'] as num).toInt() : null;
          nodes.add((tag: tag, host: server.isEmpty ? null : server, port: port));
        }
        return nodes;
      }
    } catch (_) {
      // not JSON -- fall through
    }

    // 2) base64 / plaintext proxy-URI list
    var lines = text;
    try {
      final decoded = utf8.decode(base64.decode(base64.normalize(text.replaceAll(RegExp(r'\s'), ''))));
      if (decoded.contains('://')) lines = decoded;
    } catch (_) {}
    final parsed = <({String tag, String? host, int? port})>[];
    for (final rawLine in const LineSplitter().convert(lines)) {
      final line = rawLine.trim();
      if (line.isEmpty || !line.contains('://')) continue;
      final uri = Uri.tryParse(line);
      if (uri == null || uri.host.isEmpty) continue;
      String frag = '';
      final hashIdx = line.indexOf('#');
      if (hashIdx >= 0 && hashIdx < line.length - 1) {
        try {
          frag = Uri.decodeComponent(line.substring(hashIdx + 1));
        } catch (_) {
          frag = line.substring(hashIdx + 1);
        }
      }
      parsed.add((tag: frag, host: uri.host, port: uri.hasPort ? uri.port : null));
    }
    return parsed;
  }

  // -------------------------------------------------------------- TCP probe

  /// Bare TCP connect to the node we were about to use. Records the exact dest,
  /// how long it took, and the OS error (code + text) verbatim. Runs only on
  /// failure. NB: with the TUN up this dials through the tunnel, so a node_tcp
  /// failure here reproduces the core's own dial -- the error code
  /// (ECONNREFUSED / ETIMEDOUT / EHOSTUNREACH) is the diagnostic value.
  Future<Map<String, dynamic>> probeTcp(String host, int port) async {
    final dest = '$host:$port';
    final sw = Stopwatch()..start();
    try {
      // 不自己计时：等系统给结论（连上 / 被拒 / 不可达 / 系统的 TCP 连接超时），跟 Windows 一样（10-19 运营：不按秒数判）。
      final s = await Socket.connect(host, port);
      sw.stop();
      s.destroy();
      return {'dest': dest, 'ms': sw.elapsedMilliseconds, 'ok': true, 'errno': 0};
    } on SocketException catch (e) {
      sw.stop();
      final msg = (e.osError?.message ?? e.message).trim();
      return {
        'dest': dest,
        'ms': sw.elapsedMilliseconds,
        'ok': false,
        'errno': e.osError?.errorCode ?? -1,
        'err': msg.length > 180 ? msg.substring(0, 180) : msg,
      };
    } catch (e) {
      sw.stop();
      final msg = e.toString();
      return {
        'dest': dest,
        'ms': sw.elapsedMilliseconds,
        'ok': false,
        'errno': -1,
        'err': msg.length > 180 ? msg.substring(0, 180) : msg,
      };
    }
  }

  // -------------------------------------------------------------- sub-fetch.json

  /// Written by ProfileParser._downloadProfile after a subscription pull.
  /// {ts, host, stage, ok, status, bytes, cache, ms}.
  /// Returns the "sub" object plus internal "_stage"/"_fail_stage" hints.
  ///
  /// 1.1.11：以前超过 10 分钟就整段丢掉 —— 这次连接压根没再拉一次订阅时（常见：按
  /// 现成的本地 profile 直接连），`sub.*` 就全是 null，运营看不出订阅那一步到底正不正常。
  /// 现在只要文件存在就带上（附 `age_s` 说明多久之前拉的），只有「拿它去推断这次连接
  /// 卡在订阅哪一步」（`_stage`/`_fail_stage`）才继续收紧到 120 秒内，避免把几分钟前
  /// 那次不相关的订阅结果误当成这次连接失败的原因。
  Future<Map<String, dynamic>> _readSubFetch() async {
    try {
      final dir = await _workingDir();
      if (dir == null) return {};
      final f = File(p.join(dir.path, 'sub-fetch.json'));
      if (!f.existsSync()) return {};
      final o = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final ts = (o['ts'] as num?)?.toInt() ?? 0;
      final ageSecs = DateTime.now().millisecondsSinceEpoch ~/ 1000 - ts;
      if (ageSecs < 0) return {};

      final stage = o['stage'] as String? ?? '';
      final ok = o['ok'] as bool? ?? true;
      final sub = <String, dynamic>{'age_s': ageSecs};
      if ((o['host'] as String?)?.isNotEmpty ?? false) sub['host'] = o['host'];
      if (o['status'] != null) sub['status'] = o['status'];
      if (o['bytes'] != null) sub['bytes'] = o['bytes'];
      if ((o['cache'] as String?)?.isNotEmpty ?? false) sub['cache'] = o['cache'];
      if (o['ttfb_ms'] != null) sub['ttfb_ms'] = o['ttfb_ms'];
      if (o['ms'] != null) sub['ms'] = o['ms'];

      if (ageSecs <= 120) {
        sub['_stage'] = switch (stage) {
          'sub_download' => stageSubRequested,
          'sub_parse' => stageSubDownloaded,
          'nodes_parsed' => stageNodesParsed,
          _ => 0,
        };
        if (!ok) {
          sub['_fail_stage'] = stage == 'sub_parse' ? 'sub_parse' : 'sub_download';
        }
      }
      return sub;
    } catch (_) {
      return {};
    }
  }

  // -------------------------------------------------------------- bundle

  Future<bool> _bundleRateLimitOk(String signature) async {
    try {
      final dir = await _workingDir();
      if (dir == null) return false;
      final f = File(p.join(dir.path, 'gsl-connect-bundle-log.json'));
      Map<String, dynamic> log = {};
      if (f.existsSync()) {
        log = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      }
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final dayAgo = now - 24 * 3600;
      final kept = <String, dynamic>{};
      log.forEach((k, v) {
        if ((v as num).toInt() >= dayAgo) kept[k] = v;
      });
      if (kept.length >= _bundleMaxPerDay || kept.containsKey(signature)) return false;
      kept[signature] = now;
      await f.writeAsString(jsonEncode(kept));
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<String?> _buildBundle(String failStage) async {
    try {
      final dir = await _workingDir();
      if (dir == null) return null;

      final trace = <Map<String, dynamic>>[];
      for (var s = stageSubRequested; s <= _reached; s++) {
        final step = <String, dynamic>{'stage': _stageSlug(s), 'ok': true};
        if (s == stageSubDownloaded && _sub.isNotEmpty) step.addAll(_sub);
        trace.add(step);
      }
      final failStep = <String, dynamic>{'stage': failStage, 'ok': false};
      if (_tcp != null) failStep['tcp'] = _tcp;
      if (_tunnel != null) failStep['tunnel'] = _tunnel;
      trace.add(failStep);

      // box.log: prefer the failure-time snapshot (a reconnect truncates the
      // live file). app.log is app-written and append-only, read live.
      final snap = File(p.join(dir.path, 'box.log.snap'));
      final boxPath = snap.existsSync() ? snap.path : LogPathResolver.corePath(dir);

      final text = StringBuffer()
        ..writeln('===== 光速雷达 连接轨迹 =====')
        ..writeln('time: ${_startedAt.toIso8601String()}')
        ..writeln('ver: ${_version()}  os: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}')
        ..writeln('fail_stage: $failStage  reached: $_reached')
        ..writeln('node: ${_nodeTag.isEmpty ? "-" : _nodeTag}'
            '${_nodeHost != null ? "  dest: $_nodeHost:${_nodePort ?? "?"}" : ""}')
        ..writeln('sub: ${_subName.isEmpty ? "-" : _subName}');
      if (_tcp != null) {
        text.writeln('tcp_probe: ${jsonEncode(_tcp)}');
      }
      if (_tunnel != null) {
        text.writeln('tunnel: ${jsonEncode(_tunnel)}');
      }
      text
        ..writeln('box.log source: ${snap.existsSync() ? "snapshot" : "live"}')
        ..writeln()
        ..writeln('--- box.log (tail) ---')
        ..writeln(await _tail(boxPath, 400, 180 * 1024))
        ..writeln()
        ..writeln('--- app.log (tail) ---')
        ..writeln(await _tail(p.join(dir.path, 'app.log'), 200, 80 * 1024));

      final bundle = {
        'fmt': '1',
        'attempt_id': _attemptId,
        'started_at': _startedAt.toUtc().toIso8601String(),
        'fail_stage': failStage,
        'node_tag': _nodeTag,
        'sub_name': _subName,
        if (_tcp != null) 'tcp': _tcp,
        if (_tunnel != null) 'tunnel': _tunnel,
        'trace': trace,
        'log_tail': text.toString(),
      };
      final gz = ZLibCodec(level: 9).encode(utf8.encode(jsonEncode(bundle)));
      return base64.encode(gz);
    } catch (_) {
      return null;
    }
  }

  static String _stageSlug(int s) => switch (s) {
        stageSubRequested => 'sub_requested',
        stageSubDownloaded => 'sub_downloaded',
        stageNodesParsed => 'nodes_parsed',
        stageCoreStarted => 'core_started',
        stageTunnelReady => 'tunnel_ready',
        stageNodeTcp => 'node_tcp',
        stageNodeTls => 'node_tls',
        stageProxyRequest => 'proxy_request',
        _ => 'unknown',
      };

  /// Tail of a text file, robust to a byte-offset landing mid-UTF-8 and to NUL
  /// padding (Android's rotated logs). Decodes leniently, drops NULs, and skips
  /// the partial first line when we did not start at offset 0.
  /// [from]：只读这个位置之后的（文件比它短 = 中间被清过，从头读）。
  Future<String> _tail(String path, int maxLines, int maxBytes, {int from = 0}) async {
    try {
      final f = File(path);
      if (!f.existsSync()) return '(none)';
      final len = await f.length();
      final floor = from <= len ? from : 0;
      final start = len - maxBytes > floor ? len - maxBytes : floor;
      final bytes = <int>[];
      await for (final chunk in f.openRead(start)) {
        bytes.addAll(chunk);
      }
      var raw = utf8.decode(bytes, allowMalformed: true).replaceAll('\x00', '');
      if (start > floor) {
        final nl = raw.indexOf('\n');
        if (nl >= 0) raw = raw.substring(nl + 1);
      }
      final lines = raw.split('\n');
      final tail = lines.length > maxLines ? lines.sublist(lines.length - maxLines) : lines;
      final out = tail.join('\n').trim();
      return out.isEmpty ? '(empty)' : out;
    } catch (e) {
      return '(read failed: $e)';
    }
  }

  // -------------------------------------------------------------- transport

  Future<void> _send(Map<String, dynamic> payload, String? bundleGzB64) async {
    if (bundleGzB64 != null) payload['bundle_gz'] = bundleGzB64;
    final token = await _panelToken();
    await PanelApiBase.resolve();

    final r1 = await _post(primaryApiBase(), payload, token);
    if (r1 == _PostResult.ok) {
      _setState('sent', bundleGzB64 != null ? (_attemptId ?? '').substring(0, 8) : '');
      return;
    }
    if (r1 == _PostResult.rejected) {
      _setState('failed', '');
      return;
    }
    final r2 = await _post(_fallbackApiBase, payload, token);
    if (r2 == _PostResult.ok) {
      _setState('sent', bundleGzB64 != null ? (_attemptId ?? '').substring(0, 8) : '');
      return;
    }
    if (r2 == _PostResult.rejected) {
      _setState('failed', '');
      return;
    }
    await _enqueue(payload);
    _setState('queued', '');
  }

  Future<_PostResult> _post(String baseUrl, Map<String, dynamic> payload, String? token) async {
    try {
      final opt = token != null
          ? Options(headers: {'Authorization': token, 'auth_data': token})
          : null;
      final res = await _dio(baseUrl).post<dynamic>(_reportPath, data: payload, options: opt);
      final s = res.statusCode ?? 0;
      if (s >= 200 && s < 300) return _PostResult.ok;
      // 服务器自己出错（5xx）不算被拒：跟网络不通一样换地址 / 排队补传，别把这次结果丢了（finecomb 审查 S-1）。
      if (s >= 400 && s < 500) return _PostResult.rejected;
      return _PostResult.network;
    } on DioException {
      return _PostResult.network;
    } catch (_) {
      return _PostResult.network;
    }
  }

  void _setState(String s, String c) {
    state = s;
    code = c;
  }

  // -------------------------------------------------------------- offline queue

  Future<File?> _queueFile() async {
    final dir = await _workingDir();
    if (dir == null) return null;
    return File(p.join(dir.path, 'gsl-connect-queue.json'));
  }

  /// 排队文件的「读 → 改 → 写回」一次只做一个（排队和补发最后那次重读写回不能交叉，不然新排进的被冲掉、
  /// 发过的又被写回去再发一遍）。
  Future<void> _queueLock = Future.value();

  Future<void> _withQueueLock(Future<void> Function() body) {
    final run = _queueLock.then((_) => body()).catchError((_) {});
    _queueLock = run;
    return run;
  }

  Future<void> _enqueue(Map<String, dynamic> payload) => _withQueueLock(() => _enqueueNow(payload));

  Future<void> _enqueueNow(Map<String, dynamic> payload) async {
    try {
      final f = await _queueFile();
      if (f == null) return;
      List<dynamic> queue = [];
      if (f.existsSync()) queue = jsonDecode(await f.readAsString()) as List<dynamic>;
      // qid：每一条自己的编号（原报和补报可能同一秒排进来、attempt_id 也一样，删的时候不能连带删掉）
      queue.add({'at': DateTime.now().millisecondsSinceEpoch ~/ 1000, 'qid': _mintId(), 'payload': payload});
      while (queue.length > _queueMax) {
        queue.removeAt(0);
      }
      await f.writeAsString(jsonEncode(queue));
    } catch (_) {}
  }

  /// 网通了（连上并确认）时补发排队的上报。以前只在下一次点连接时补，连上一次就一直用着的人永远补不上
  /// （10-21 查：有流量却一条连接记录都没有，两端统一，Windows ConnectReporter::flushQueue）。
  /// 上一轮还在发时这一轮不叠上去（两轮同时发会重复上报），记下来，上一轮完了再补一轮（不丢掉这次补发）。
  Future<void> flushQueue() async {
    if (_flushing) {
      _flushAgain = true;
      return;
    }
    _flushing = true;
    try {
      final f = await _queueFile();
      if (f == null) return;
      var queue = const <dynamic>[];
      await _withQueueLock(() async {
        if (f.existsSync()) queue = jsonDecode(await f.readAsString()) as List<dynamic>;
      });
      if (queue.isEmpty) return;

      final token = await _panelToken();
      await PanelApiBase.resolve();
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final finished = <String>{};
      for (final entry in queue) {
        final at = ((entry as Map)['at'] as num?)?.toInt() ?? 0;
        if (now - at <= _queueTtlSecs) {
          final payload = Map<String, dynamic>.from(entry['payload'] as Map);
          // 老版本排的没带事情发生的时间：用排进去的时间（不然服务器按补发这一刻记，算进「最近 15 分钟」）。
          // 带上时间服务器就按新规矩看 amend 了：老版本的补报不标 amend、带着 tcp，这里按老规矩替它标上。
          if (!payload.containsKey('occurred_at')) {
            payload['occurred_at'] = at;
            payload['amend'] ??= payload['tcp'] is Map && (payload['tcp'] as Map).isNotEmpty;
          }
          final r = await _post(primaryApiBase(), payload, token);
          if (r == _PostResult.network) continue; // keep; 2xx or rejection drops it
        }
        finished.add(_queueKey(entry));
      }
      // 按文件现在的内容删：这一轮在发的时候新排进来的留着。
      await _withQueueLock(() async {
        final current = f.existsSync() ? jsonDecode(await f.readAsString()) as List<dynamic> : const <dynamic>[];
        final keep = current.where((e) => !finished.contains(_queueKey(e as Map))).toList();
        if (keep.isEmpty) {
          if (f.existsSync()) await f.delete();
        } else {
          await f.writeAsString(jsonEncode(keep));
        }
      });
    } catch (_) {
    } finally {
      _flushing = false;
      if (_flushAgain) {
        _flushAgain = false;
        unawaited(flushQueue());
      }
    }
  }

  bool _flushing = false;
  bool _flushAgain = false;

  /// 排队条目的身份：每条自己的编号（qid）；老版本排的没有，退回「排进去的时间 + attempt_id」。
  static String _queueKey(Map entry) =>
      entry['qid'] is String ? entry['qid'] as String : '${entry['at']}|${(entry['payload'] as Map?)?['attempt_id']}';
}

enum _PostResult { ok, rejected, network }

final connectReporterProvider = Provider<ConnectReporter>((ref) => ConnectReporter(ref));

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/core/directories/directories_provider.dart';
import 'package:hiddify/core/model/constants.dart';
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

  static const String _fallbackApiBase = 'https://api-hk.meadowfoundry.com';
  static const String _reportPath = '/api/v1/guest/gsl_connect/report';
  static const int _queueMax = 10;
  static const int _queueTtlSecs = 3 * 24 * 3600;
  static const int _bundleMaxPerDay = 3;

  String? _attemptId;
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

  String _primaryApiBase() => Constants.panelApiBase;

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
    _subName = _truncateRunes(subName, 64);
    _startedAt = DateTime.now();
    _done = false;
    _snapDone = false;
    _tcp = null;
    _tunnel = null;
    state = '';
    code = '';

    final node = await _resolveSelectedNode(preferredLine);
    _nodeTag = _truncateRunes(node.tag, 64);
    _nodeHost = node.host;
    _nodePort = node.port;

    _sub = await _readSubFetch();
    final subStage = _sub.remove('_stage') as int? ?? 0;
    _reached = subStage > 0 ? subStage : stageNodesParsed;

    unawaited(_flushQueue());
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
      final src = File(p.join(dir.path, 'box.log'));
      final dst = File(p.join(dir.path, 'box.log.snap'));
      if (src.existsSync()) {
        src.copySync(dst.path);
      } else {
        dst.writeAsStringSync('');
      }
      _snapDone = true;
    } catch (_) {}
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
  }) async {
    if (!attemptOpen) return;
    _done = true;

    captureCoreLogSync();

    var failStage = forcedStage ?? _mapFailStage(engineError, _reached);

    // Active TCP probe: whenever we got at least as far as tunnel takeover, or
    // the mapped stage is node-level, probe the node ourselves so we record the
    // dest / latency / OS error code / text directly, not only via the core log.
    if (_tcp == null &&
        _nodeHost != null &&
        _nodePort != null &&
        (_reached >= stageTunnelReady ||
            failStage == 'node_tcp' ||
            failStage == 'node_tls' ||
            failStage == 'proxy_request')) {
      _tcp = await _probeTcp(_nodeHost!, _nodePort!);
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
    if (_sub.isNotEmpty) payload['sub'] = _sub;
    if (_tcp != null) payload['tcp'] = _tcp;

    String? bundle;
    final sig = '$failStage|$_nodeTag|${_host(_primaryApiBase())}';
    if (await _bundleRateLimitOk(sig)) {
      bundle = await _buildBundle(failStage);
    }
    await _send(payload, bundle);
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
  Future<void> reportNoRoute() async {
    _attemptId = _mintId();
    _startedAt = DateTime.now();
    _done = true;
    _snapDone = false;
    _tcp = null;
    _nodeTag = '';
    _nodeHost = null;
    _nodePort = null;
    _sub = await _readSubFetch();
    final subStage = _sub.remove('_stage') as int? ?? 0;
    final subFail = _sub.remove('_fail_stage') as String?;

    final payload = _basePayload('fail')
      ..['fail_stage'] = subFail ?? 'sub_download'
      ..['reached_stage'] = max(1, subStage);
    if (_sub.isNotEmpty) payload['sub'] = _sub;
    await _send(payload, null);
  }

  // -------------------------------------------------------------- payload

  Map<String, dynamic> _basePayload(String outcome) {
    final m = <String, dynamic>{
      'attempt_id': _attemptId,
      'outcome': outcome,
      'platform': 'android',
      'app_ver': _version(),
      'os': '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      'apibase': _host(_primaryApiBase()),
    };
    if (_nodeTag.isNotEmpty) m['node_tag'] = _nodeTag;
    if (_subName.isNotEmpty) m['sub_name'] = _subName;
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
  Future<({String tag, String? host, int? port})> _resolveSelectedNode(String? preferred) async {
    final pref = (preferred ?? '').trim();
    try {
      final profile = await _ref.read(activeProfileProvider.future);
      if (profile == null) return (tag: pref, host: null, port: null);
      final repo = await _ref.read(profileRepositoryProvider.future);
      final raw = await repo.getRawConfig(profile.id).getOrElse((_) => '').run();
      final picked = _pickNodeFromConfig(raw, pref);
      if (picked != null) return picked;
    } catch (_) {}
    return (tag: pref, host: null, port: null);
  }

  static const _nonNodeTypes = {
    'selector', 'urltest', 'loadbalance', 'loadbalancer',
    'direct', 'block', 'dns', 'dns-out',
  };

  ({String tag, String? host, int? port})? _pickNodeFromConfig(String raw, String preferred) {
    final text = raw.trim();
    if (text.isEmpty) return null;

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
        if (nodes.isEmpty) return null;
        if (preferred.isNotEmpty) {
          for (final n in nodes) {
            if (splitNodeName(n.tag).name == preferred) return n;
          }
        }
        return nodes.first;
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
    if (parsed.isEmpty) return null;
    if (preferred.isNotEmpty) {
      for (final n in parsed) {
        if (splitNodeName(n.tag).name == preferred) return n;
      }
    }
    return parsed.first;
  }

  // -------------------------------------------------------------- TCP probe

  /// Bare TCP connect to the node we were about to use. Records the exact dest,
  /// how long it took, and the OS error (code + text) verbatim. Runs only on
  /// failure. NB: with the TUN up this dials through the tunnel, so a node_tcp
  /// failure here reproduces the core's own dial -- the error code
  /// (ECONNREFUSED / ETIMEDOUT / EHOSTUNREACH) is the diagnostic value.
  Future<Map<String, dynamic>> _probeTcp(String host, int port) async {
    final dest = '$host:$port';
    final sw = Stopwatch()..start();
    try {
      final s = await Socket.connect(host, port, timeout: const Duration(seconds: 6));
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
      final boxPath = snap.existsSync() ? snap.path : p.join(dir.path, 'box.log');

      final text = StringBuffer()
        ..writeln('===== 光速 连接轨迹 =====')
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
  Future<String> _tail(String path, int maxLines, int maxBytes) async {
    try {
      final f = File(path);
      if (!f.existsSync()) return '(none)';
      final len = await f.length();
      final start = len > maxBytes ? len - maxBytes : 0;
      final bytes = <int>[];
      await for (final chunk in f.openRead(start)) {
        bytes.addAll(chunk);
      }
      var raw = utf8.decode(bytes, allowMalformed: true).replaceAll('\x00', '');
      if (start > 0) {
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

    final r1 = await _post(_primaryApiBase(), payload, token);
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
      if (s >= 400 && s < 600) return _PostResult.rejected;
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

  Future<void> _enqueue(Map<String, dynamic> payload) async {
    try {
      final f = await _queueFile();
      if (f == null) return;
      List<dynamic> queue = [];
      if (f.existsSync()) queue = jsonDecode(await f.readAsString()) as List<dynamic>;
      queue.add({'at': DateTime.now().millisecondsSinceEpoch ~/ 1000, 'payload': payload});
      while (queue.length > _queueMax) {
        queue.removeAt(0);
      }
      await f.writeAsString(jsonEncode(queue));
    } catch (_) {}
  }

  Future<void> _flushQueue() async {
    try {
      final f = await _queueFile();
      if (f == null || !f.existsSync()) return;
      final queue = jsonDecode(await f.readAsString()) as List<dynamic>;
      if (queue.isEmpty) return;

      final token = await _panelToken();
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final remaining = <dynamic>[];
      for (final entry in queue) {
        final at = ((entry as Map)['at'] as num?)?.toInt() ?? 0;
        if (now - at > _queueTtlSecs) continue;
        final payload = Map<String, dynamic>.from(entry['payload'] as Map);
        final r = await _post(_primaryApiBase(), payload, token);
        if (r == _PostResult.network) remaining.add(entry); // keep; 2xx or rejection drops it
      }
      if (remaining.isEmpty) {
        if (f.existsSync()) await f.delete();
      } else {
        await f.writeAsString(jsonEncode(remaining));
      }
    } catch (_) {}
  }
}

enum _PostResult { ok, rejected, network }

final connectReporterProvider = Provider<ConnectReporter>((ref) => ConnectReporter(ref));

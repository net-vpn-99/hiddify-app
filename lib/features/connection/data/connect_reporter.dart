import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/core/directories/directories_provider.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path/path.dart' as p;

/// Reports one row per connect attempt to the panel (GslInviteBonus 1.17.0's
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
  String _nodeTag = '';
  int _reached = 0;
  bool _done = false;
  DateTime _startedAt = DateTime.now();
  Map<String, dynamic> _sub = {};

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

  Future<Directory?> _workingDir() async {
    try {
      return _ref.read(appDirectoriesProvider).requireValue.workingDir;
    } catch (_) {
      return null;
    }
  }

  String? _email() {
    try {
      final e = _ref.read(panelAuthProvider).email;
      return (e != null && e.isNotEmpty) ? e : null;
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

  Future<void> beginAttempt(String nodeTag) async {
    _attemptId = _mintId();
    _nodeTag = nodeTag.length > 64 ? nodeTag.substring(0, 64) : nodeTag;
    _startedAt = DateTime.now();
    _done = false;
    state = '';
    code = '';

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

  Future<void> reportFailure(String engineError) async {
    if (!attemptOpen) return;
    _done = true;

    final failStage = _mapFailStage(engineError, _reached);
    final payload = _basePayload('fail')
      ..['fail_stage'] = failStage
      ..['reached_stage'] = _reached;
    if (_sub.isNotEmpty) payload['sub'] = _sub;

    String? bundle;
    final sig = '$failStage|$_nodeTag|${_host(_primaryApiBase())}';
    if (await _bundleRateLimitOk(sig)) {
      bundle = await _buildBundle(failStage);
    }
    await _send(payload, bundle);
  }

  /// Connect was pressed but there is no profile and a resync did not fix it.
  /// The last subscription fetch is why.
  Future<void> reportNoRoute() async {
    _attemptId = _mintId();
    _startedAt = DateTime.now();
    _done = true;
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
    final e = _email();
    if (e != null) m['email'] = e;
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
      return 'core_start';
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

  // -------------------------------------------------------------- sub-fetch.json

  /// Written by ProfileParser._downloadProfile after a subscription pull.
  /// {ts, host, stage, ok, status, bytes, cache, ms}. Ignored if > 10 min old.
  /// Returns the "sub" object plus internal "_stage"/"_fail_stage" hints.
  Future<Map<String, dynamic>> _readSubFetch() async {
    try {
      final dir = await _workingDir();
      if (dir == null) return {};
      final f = File(p.join(dir.path, 'sub-fetch.json'));
      if (!f.existsSync()) return {};
      final o = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final ts = (o['ts'] as num?)?.toInt() ?? 0;
      final ageSecs = DateTime.now().millisecondsSinceEpoch ~/ 1000 - ts;
      if (ageSecs < 0 || ageSecs > 600) return {};

      final stage = o['stage'] as String? ?? '';
      final ok = o['ok'] as bool? ?? true;
      final sub = <String, dynamic>{};
      if (o['status'] != null) sub['status'] = o['status'];
      if (o['bytes'] != null) sub['bytes'] = o['bytes'];
      if ((o['cache'] as String?)?.isNotEmpty ?? false) sub['cache'] = o['cache'];
      if (o['ttfb_ms'] != null) sub['ttfb_ms'] = o['ttfb_ms'];
      if (o['ms'] != null) sub['ms'] = o['ms'];

      sub['_stage'] = switch (stage) {
        'sub_download' => stageSubRequested,
        'sub_parse' => stageSubDownloaded,
        'nodes_parsed' => stageNodesParsed,
        _ => 0,
      };
      if (!ok) {
        sub['_fail_stage'] = stage == 'sub_parse' ? 'sub_parse' : 'sub_download';
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
      trace.add({'stage': failStage, 'ok': false});

      final text = StringBuffer()
        ..writeln('===== 光速 连接轨迹 =====')
        ..writeln('time: ${_startedAt.toIso8601String()}')
        ..writeln('ver: ${_version()}  os: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}')
        ..writeln('fail_stage: $failStage  reached: $_reached')
        ..writeln()
        ..writeln('--- box.log (tail) ---')
        ..writeln(await _tail(p.join(dir.path, 'box.log'), 400, 180 * 1024))
        ..writeln()
        ..writeln('--- app.log (tail) ---')
        ..writeln(await _tail(p.join(dir.path, 'app.log'), 200, 80 * 1024));

      final bundle = {
        'fmt': '1',
        'attempt_id': _attemptId,
        'started_at': _startedAt.toUtc().toIso8601String(),
        'fail_stage': failStage,
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

  Future<String> _tail(String path, int maxLines, int maxBytes) async {
    try {
      final f = File(path);
      if (!f.existsSync()) return '(none)';
      final len = await f.length();
      final start = len > maxBytes ? len - maxBytes : 0;
      final raw = await f.openRead(start).transform(utf8.decoder).join();
      final lines = raw.split('\n');
      final tail = lines.length > maxLines ? lines.sublist(lines.length - maxLines) : lines;
      return tail.join('\n');
    } catch (e) {
      return '(read failed: $e)';
    }
  }

  // -------------------------------------------------------------- transport

  Future<void> _send(Map<String, dynamic> payload, String? bundleGzB64) async {
    if (bundleGzB64 != null) payload['bundle_gz'] = bundleGzB64;

    final r1 = await _post(_primaryApiBase(), payload);
    if (r1 == _PostResult.ok) {
      _setState('sent', bundleGzB64 != null ? (_attemptId ?? '').substring(0, 8) : '');
      return;
    }
    if (r1 == _PostResult.rejected) {
      _setState('failed', '');
      return;
    }
    final r2 = await _post(_fallbackApiBase, payload);
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

  Future<_PostResult> _post(String baseUrl, Map<String, dynamic> payload) async {
    try {
      final res = await _dio(baseUrl).post<dynamic>(_reportPath, data: payload);
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

      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final remaining = <dynamic>[];
      for (final entry in queue) {
        final at = ((entry as Map)['at'] as num?)?.toInt() ?? 0;
        if (now - at > _queueTtlSecs) continue;
        final payload = Map<String, dynamic>.from(entry['payload'] as Map);
        final r = await _post(_primaryApiBase(), payload);
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

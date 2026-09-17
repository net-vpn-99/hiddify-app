import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 运行时解析 Xboard API 根地址。
///
/// 自有指针（api-hk `/rules/` 与 gsldone `/dengta/`）决定主备顺序；第三方
/// 阿里 OSS 只补充救援候选。上次成功地址加快故障期间启动，不能升成配置主入口。
class PanelApiBase {
  PanelApiBase._();

  static const _prefKey = 'oneray_panel_api_base';
  static const _domainPrefKey = 'oneray_panel_api_domain';
  static const _configPrefKey = 'oneray_panel_api_config';
  static const _primaryPrefKey = 'oneray_panel_api_primary';

  static String? _cached;
  static Future<String>? _inflight;
  static DateTime? _cachedAt;
  static DateTime? _lastAttemptAt;
  static const _retryCooldown = Duration(seconds: 15);
  static const _configRefresh = Duration(minutes: 5);
  static DateTime? _configFetchedAt;
  static Duration? _configRefreshJitter;
  static List<String> _configOrder = List<String>.from(Constants.panelApiFallbacks);
  static String? _configPrimary = Constants.panelApiBase;
  static final List<String> _rescue = [];
  static bool _ownConfigValid = false;

  static String? _avoidedBase;
  static DateTime? _avoidedUntil;
  static const _avoidWindow = Duration(minutes: 2);
  static const _avoidExtend = Duration(minutes: 10);
  static DateTime? _lastFailbackAt;
  static String? _lastFailbackBase;
  static DateTime? _lastPrimaryProbe;
  static DateTime? _lastPrimaryHit;
  static int _primaryHits = 0;
  static Duration? _primaryProbeJitter;
  static DateTime? _lastAllFailAt;
  static bool _configRefreshPending = false;
  static bool _configRefreshBusy = false;

  static final _rng = Random();

  static final Dio _http = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 3),
      receiveTimeout: const Duration(seconds: 3),
      sendTimeout: const Duration(seconds: 3),
      validateStatus: (_) => true,
      headers: {'User-Agent': 'OneRay-Android'},
    ),
  );

  /// 上次探活成功的地址；还没探过就用打包默认值。
  static String get current => _cached ?? Constants.panelApiBase;

  static List<String> get configHosts => [
        if (_configPrimary != null) _configPrimary!,
        ..._configOrder,
        ..._rescue,
        current,
      ];

  static String get _primary =>
      (_configPrimary != null && _configPrimary!.isNotEmpty) ? _configPrimary! : Constants.panelApiBase;

  static Future<String> resolve({bool force = false}) {
    if (!force && _cached != null && _cachedAt != null && !_skipped(_cached!)) {
      unawaited(_backgroundMaintain());
      return Future.value(_cached!);
    }
    if (!force && _inAllFailBackoff()) {
      _configRefreshPending = true;
      return Future.value(_cached!);
    }
    if (!force &&
        _cached != null &&
        _lastAttemptAt != null &&
        DateTime.now().difference(_lastAttemptAt!) < _retryCooldown &&
        _cachedAt == null) {
      return Future.value(_cached!);
    }
    return _inflight ??= _resolve(force: force).whenComplete(() => _inflight = null);
  }

  static bool _inAllFailBackoff() =>
      _cached != null &&
      _lastAllFailAt != null &&
      DateTime.now().difference(_lastAllFailAt!) < _retryCooldown;

  static Future<void> _backgroundMaintain() async {
    try {
      if (_inAllFailBackoff()) {
        _configRefreshPending = true;
        return;
      }
      await _refreshRemoteConfig(force: false);
      final prefs = await SharedPreferences.getInstance();
      if (_cached != null && _cached != _primary) {
        await _maybeFailback(prefs, _primary);
      }
    } catch (_) {}
  }

  /// 回前台时补一次：系统冻结期间错过的回切在这里补。
  static Future<void> onForeground() => resolve(force: false);

  static void _invalidate() {
    noteFailure(_cached ?? current);
  }

  /// [usedBase] 必须是这次实际发出请求的地址，不能用之后已经切走的 current。
  static void noteFailure(String usedBase, {int? status, DioExceptionType? type}) {
    if (status != null || type != null) {
      const connectionErrors = {
        DioExceptionType.connectionError,
        DioExceptionType.connectionTimeout,
        DioExceptionType.receiveTimeout,
        DioExceptionType.sendTimeout,
      };
      final gateway = status == 502 || status == 503 || status == 504 || status == 521 || status == 525;
      final transport = type != null && connectionErrors.contains(type);
      if (!gateway && !transport) return;
    }
    final u = _normalize(usedBase);
    if (u == null) return;
    _avoidedBase = u;
    var window = _avoidWindow;
    if (_lastFailbackBase == u &&
        _lastFailbackAt != null &&
        DateTime.now().difference(_lastFailbackAt!) < _avoidExtend) {
      window = _avoidExtend;
    }
    _avoidedUntil = DateTime.now().add(window);
    if (_cached == u) _cachedAt = null;
  }

  static Dio dio({String userAgent = 'OneRay-Android'}) {
    final client = Dio(
      BaseOptions(
        baseUrl: current,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 20),
        validateStatus: (_) => true,
        headers: {'User-Agent': userAgent},
      ),
    );
    client.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          if (_cached != null && _cachedAt != null && !_skipped(_cached!)) {
            options.baseUrl = _cached!;
            unawaited(resolve());
            handler.next(options);
            return;
          }
          options.baseUrl = await resolve();
          handler.next(options);
        },
        onResponse: (res, handler) {
          final code = res.statusCode ?? 0;
          if (code == 502 || code == 503 || code == 504 || code == 521 || code == 525) {
            noteFailure(res.requestOptions.baseUrl, status: code);
          }
          handler.next(res);
        },
        onError: (e, handler) {
          noteFailure(e.requestOptions.baseUrl, status: e.response?.statusCode, type: e.type);
          handler.next(e);
        },
      ),
    );
    return client;
  }

  static Duration _jitter(Duration base, [int pct = 20]) {
    final ms = base.inMilliseconds;
    final delta = (ms * pct / 100).round();
    final off = _rng.nextInt(delta * 2 + 1) - delta;
    return Duration(milliseconds: (ms + off).clamp(1, 1 << 30));
  }

  static bool _skipped(String base) =>
      _avoidedBase == base && _avoidedUntil != null && DateTime.now().isBefore(_avoidedUntil!);

  static Future<String> _resolve({required bool force}) async {
    final prefs = await SharedPreferences.getInstance();
    await _loadPersistedConfig(prefs);
    if (!force && _inAllFailBackoff()) {
      _configRefreshPending = true;
      return _cached!;
    }
    await _refreshRemoteConfig(force: force);

    final now = DateTime.now();
    if (_inAllFailBackoff()) {
      return _cached!;
    }
    _lastAttemptAt = now;

    final primary = _primary;
    final onPrimary = _cached != null && _cached == primary && _cachedAt != null && !_skipped(primary);
    if (!force && onPrimary) return _cached!;

    if (!force && _cached != null && _cachedAt != null && _cached != primary && !_skipped(_cached!)) {
      await _maybeFailback(prefs, primary);
      if (_cached != null && _cachedAt != null) return _cached!;
    }

    final candidates = _probeOrder();
    for (final base in candidates) {
      if (_skipped(base)) continue;
      if (await _probe(base)) {
        await _latch(prefs, base);
        return base;
      }
    }
    for (final base in candidates) {
      if (!_skipped(base)) continue;
      if (await _probe(base)) {
        await _latch(prefs, base);
        return base;
      }
    }

    _lastAllFailAt = DateTime.now();
    _cachedAt = null;
    _configRefreshPending = true;
    final fallback = _cached ??
        (prefs.getString(_prefKey)?.trim().isNotEmpty == true ? prefs.getString(_prefKey)!.trim() : primary);
    _cached = fallback;
    return fallback;
  }

  static List<String> _probeOrder() {
    final out = <String>[];
    void add(String? raw) {
      final u = _normalize(raw);
      if (u == null || out.contains(u)) return;
      out.add(u);
    }

    for (final u in _configOrder) {
      add(u);
    }
    add(_configPrimary);
    for (final u in _rescue) {
      add(u);
    }
    for (final u in Constants.panelApiFallbacks) {
      add(u);
    }
    add(Constants.panelApiBase);
    return out;
  }

  static Future<void> _loadPersistedConfig(SharedPreferences prefs) async {
    final raw = prefs.getStringList(_configPrefKey);
    if (raw != null && raw.isNotEmpty) {
      _configOrder = raw.map(_normalize).whereType<String>().toList();
      _ownConfigValid = true;
    } else if (_configOrder.isEmpty) {
      _configOrder = [
        Constants.panelApiBase,
        ...Constants.panelApiFallbacks.where((u) => u != Constants.panelApiBase),
      ];
    }
    final p = _normalize(prefs.getString(_primaryPrefKey));
    if (p != null) {
      _configPrimary = p;
    } else if (_configOrder.isNotEmpty) {
      _configPrimary = _configOrder.first;
    }
    final last = _normalize(prefs.getString(_prefKey));
    if (last != null && !_configOrder.contains(last) && !_rescue.contains(last)) {
      _rescue.add(last);
    }
  }

  static Future<void> _refreshRemoteConfig({required bool force}) async {
    if (!force && _inAllFailBackoff()) {
      _configRefreshPending = true;
      return;
    }
    _configRefreshJitter ??= _jitter(_configRefresh);
    final now = DateTime.now();
    if (!force &&
        !_configRefreshPending &&
        _configFetchedAt != null &&
        now.difference(_configFetchedAt!) < _configRefreshJitter!) {
      return;
    }
    _configRefreshPending = false;
    _configFetchedAt = now;
    _configRefreshJitter = _jitter(_configRefresh);
    if (_configRefreshBusy) return;
    _configRefreshBusy = true;
    try {
      final fetched = await _fetchPointers();
      if (fetched.own.isNotEmpty) {
        _applyOwnConfig(fetched.own);
      }
      for (final u in fetched.rescue) {
        if (!_configOrder.contains(u) && !_rescue.contains(u)) _rescue.add(u);
      }
    } finally {
      _configRefreshBusy = false;
    }
  }

  static void _applyOwnConfig(List<String> order) {
    if (order.isEmpty) return;
    var next = List<String>.from(order);
    if (next.length == 1) {
      for (final u in _configOrder) {
        if (!next.contains(u)) next.add(u);
      }
    }
    _configOrder = next;
    _configPrimary = next.first;
    _ownConfigValid = true;
    unawaited(_persistConfig());
  }

  static Future<void> _persistConfig() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_configPrefKey, _configOrder);
    if (_configPrimary != null) await prefs.setString(_primaryPrefKey, _configPrimary!);
  }

  static Future<void> _maybeFailback(SharedPreferences prefs, String primary) async {
    if (_skipped(primary)) return;
    final now = DateTime.now();
    final interval = _primaryHits == 1
        ? const Duration(seconds: 15)
        : (_primaryProbeJitter ??= _jitter(const Duration(minutes: 3)));
    if (_lastPrimaryProbe != null && now.difference(_lastPrimaryProbe!) < interval) return;
    _lastPrimaryProbe = now;
    if (!await _probe(primary)) {
      _primaryHits = 0;
      return;
    }
    if (_primaryHits == 0) {
      _primaryHits = 1;
      _lastPrimaryHit = now;
      return;
    }
    if (_lastPrimaryHit != null && now.difference(_lastPrimaryHit!) < const Duration(seconds: 15)) {
      return;
    }
    _primaryHits = 0;
    _primaryProbeJitter = _jitter(const Duration(minutes: 3));
    _lastFailbackAt = now;
    _lastFailbackBase = primary;
    await _latch(prefs, primary);
  }

  static Future<void> _latch(SharedPreferences prefs, String base) async {
    _cached = base;
    _cachedAt = DateTime.now();
    await prefs.setString(_prefKey, base);
    await _persistConfig();
    await _maybeBeaconFailover(prefs, base);
  }

  static Future<void> _maybeBeaconFailover(SharedPreferences prefs, String base) async {
    final to = _registrableDomain(base);
    if (to == null) return;
    final from = prefs.getString(_domainPrefKey);
    if (from != null && from != to) {
      unawaited(
        () async {
          try {
            await _http.post<dynamic>(
              '$base/api/v1/guest/gsl_monitor/failover',
              data: jsonEncode({'from': from, 'to': to}),
              options: Options(contentType: 'application/json'),
            );
          } catch (_) {}
        }(),
      );
    }
    if (from != to) {
      await prefs.setString(_domainPrefKey, to);
    }
  }

  static String? _registrableDomain(String url) {
    try {
      final host = Uri.parse(url).host;
      if (host.isEmpty) return null;
      final parts = host.split('.');
      if (parts.length < 2) return host;
      return parts.sublist(parts.length - 2).join('.');
    } catch (_) {
      return null;
    }
  }

  static bool _isOwnPointer(String url) =>
      url.contains('inkspindle.com/rules/') ||
      url.contains('gsldone.com/dengta/') ||
      url.contains('guangsuleida.com/dengta/');

  static Future<({List<String> own, List<String> rescue})> _fetchPointers() async {
    final own = <String>[];
    final rescue = <String>[];
    final ownUrls = Constants.ossPointerUrls.where(_isOwnPointer).toList();
    final thirdUrls = Constants.ossPointerUrls.where((u) => !_isOwnPointer(u)).toList();
    for (final pointer in ownUrls) {
      final parsed = await _fetchOnePointer(pointer);
      if (parsed.isEmpty) continue;
      own.addAll(parsed);
      break;
    }
    if (own.isNotEmpty) {
      unawaited(() async {
        for (final pointer in thirdUrls) {
          final parsed = await _fetchOnePointer(pointer);
          if (parsed.isEmpty) continue;
          for (final u in parsed) {
            if (!_configOrder.contains(u) && !_rescue.contains(u)) _rescue.add(u);
          }
          break;
        }
      }());
      return (own: own, rescue: rescue);
    }
    for (final pointer in thirdUrls) {
      final parsed = await _fetchOnePointer(pointer);
      if (parsed.isEmpty) continue;
      rescue.addAll(parsed);
      break;
    }
    if (own.isEmpty && !_ownConfigValid) {
      // 没有自有配置时，安卓用内置列表引导；第三方结果只当救援。
    }
    return (own: own, rescue: rescue);
  }

  static Future<List<String>> _fetchOnePointer(String pointer) async {
    try {
      final res = await _http.get<dynamic>(pointer);
      if (res.statusCode != 200 || res.data == null) return const [];
      final body = res.data is String ? res.data as String : jsonEncode(res.data);
      return _parsePointer(body);
    } catch (_) {
      return const [];
    }
  }

  static const _maxCandidates = 8;

  static List<String> _parsePointer(String body) {
    final out = <String>[];
    void add(String? raw) {
      final u = _normalize(raw);
      if (u == null || out.contains(u) || !u.startsWith('https://')) return;
      out.add(u);
    }

    try {
      final decoded = jsonDecode(body.trim());
      if (decoded is Map) {
        final api = decoded['api'];
        if (api is List) {
          for (final item in api) {
            add(item is String ? item : '$item');
            if (out.length >= _maxCandidates) return out;
          }
        }
        if (out.isEmpty) {
          final raw = decoded['uttll'];
          if (raw is String) {
            add(raw);
          } else if (raw is List) {
            for (final item in raw) {
              add(item is String ? item : '$item');
              if (out.length >= _maxCandidates) return out;
            }
          }
        }
      } else if (decoded is String) {
        add(decoded);
      }
    } catch (_) {
      add(body.trim());
    }
    return out;
  }

  static Future<bool> _probe(String base) async {
    try {
      final res = await _http.get<dynamic>('$base/api/v1/guest/comm/config');
      if (res.statusCode != 200) return false;
      final data = res.data;
      if (data is Map) return data.containsKey('status') || data.containsKey('data');
      if (data is String) return data.contains('"status"') || data.contains('"data"');
      return false;
    } catch (_) {
      return false;
    }
  }

  static String? _normalize(String? raw) {
    if (raw == null) return null;
    var s = raw.trim();
    if (s.isEmpty) return null;
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    if (!(s.startsWith('https://') || s.startsWith('http://'))) return null;
    return s;
  }
}

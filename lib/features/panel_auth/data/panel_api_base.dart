import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 运行时解析 Xboard API 根地址。
///
/// 渠道 OSS 只下发 `{uttll: "https://api…"}`，不是安装包。客户端把这个地址
/// 插到候选最前，探活 `/api/v1/guest/comm/config` 后写入本地。品牌域被墙时
/// 换 OSS 里的 uttll 即可，不用再发版。OSS 自己挂了还有灰云 / 源站那两份同名 txt。
class PanelApiBase {
  PanelApiBase._();

  static const _prefKey = 'oneray_panel_api_base';

  static String? _cached;
  static Future<String>? _inflight;

  static final Dio _http = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 6),
      receiveTimeout: const Duration(seconds: 8),
      validateStatus: (_) => true,
      headers: {'User-Agent': 'OneRay-Android'},
    ),
  );

  /// 上次探活成功的地址；还没探过就用打包默认值。
  static String get current => _cached ?? Constants.panelApiBase;

  static Future<String> resolve({bool force = false}) {
    if (!force && _cached != null) return Future.value(_cached!);
    return _inflight ??= _resolve(force: force).whenComplete(() => _inflight = null);
  }

  /// 登录 / 购买 / 诊断共用。第一次请求前会把 baseUrl 换成探活结果。
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
          options.baseUrl = await resolve();
          handler.next(options);
        },
      ),
    );
    return client;
  }

  static Future<String> _resolve({required bool force}) async {
    final prefs = await SharedPreferences.getInstance();
    final persisted = prefs.getString(_prefKey)?.trim();
    final candidates = <String>[];

    void add(String? raw) {
      final u = _normalize(raw);
      if (u != null && !candidates.contains(u)) candidates.add(u);
    }

    if (!force) add(persisted);
    for (final u in await _fetchOssPointers()) {
      add(u);
    }
    for (final u in Constants.panelApiFallbacks) {
      add(u);
    }
    add(Constants.panelApiBase);

    for (final base in candidates) {
      if (await _probe(base)) {
        _cached = base;
        await prefs.setString(_prefKey, base);
        return base;
      }
    }

    final fallback = (persisted != null && persisted.isNotEmpty) ? persisted : Constants.panelApiBase;
    _cached = fallback;
    return fallback;
  }

  static Future<List<String>> _fetchOssPointers() async {
    final out = <String>[];
    for (final pointer in Constants.ossPointerUrls) {
      try {
        final res = await _http.get<dynamic>(pointer);
        if (res.statusCode != 200 || res.data == null) continue;
        final body = res.data is String ? res.data as String : jsonEncode(res.data);
        for (final u in _parseUttll(body)) {
          if (!out.contains(u)) out.add(u);
        }
        if (out.isNotEmpty) return out;
      } catch (_) {
        // 下一份指针
      }
    }
    return out;
  }

  static List<String> _parseUttll(String body) {
    final out = <String>[];
    try {
      final decoded = jsonDecode(body.trim());
      if (decoded is Map) {
        final raw = decoded['uttll'];
        if (raw is String) {
          final u = _normalize(raw);
          if (u != null) out.add(u);
        } else if (raw is List) {
          for (final item in raw) {
            final u = _normalize(item is String ? item : '$item');
            if (u != null && !out.contains(u)) out.add(u);
          }
        }
      } else if (decoded is String) {
        final u = _normalize(decoded);
        if (u != null) out.add(u);
      }
    } catch (_) {
      // 不是 JSON 就当整段是 URL
      final u = _normalize(body.trim());
      if (u != null) out.add(u);
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

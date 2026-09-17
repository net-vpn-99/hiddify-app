import 'dart:async';

import 'package:hiddify/features/panel_auth/data/panel_api_base.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// `comm/config` 里 `gsl_invite` 下发的几个「可被后台覆盖、不用发版」的地址：
/// 设备闸、会员中心、帮助页。留空（后台没配）就是 `null`，调用方回落到自己的
/// 默认值/推导逻辑。跟 `SupportChatService` 的 kf 解析是同一个思路，但各管
/// 各的缓存和请求——两边任何一个挂了，不影响另一个。
class RemoteSiteConfig {
  RemoteSiteConfig._();

  static const _ttl = Duration(hours: 6);
  static const _deviceApiKey = 'oneray_site_device_api';
  static const _accountUrlKey = 'oneray_site_account_url';
  static const _helpUrlKey = 'oneray_site_help_url';

  static String? _deviceApi;
  static String? _accountUrl;
  static String? _helpUrl;
  static Duration _quotaPoll = const Duration(seconds: 45);
  static Duration _nodesPoll = const Duration(seconds: 720);
  static DateTime? _fetchedAt;
  static Future<void>? _inflight;

  static bool get _fresh =>
      _fetchedAt != null && DateTime.now().difference(_fetchedAt!) < _ttl;

  /// 设备闸显式地址；后台没配就是 `null`，调用方自己按当前 API 域名推导兜底。
  static String? get deviceApi => _deviceApi;

  /// 会员中心 / 帮助页地址，`fallback` 是内置默认值（`Constants` 里那些）。
  static String accountUrlOr(String fallback) => _accountUrl ?? fallback;
  static String helpUrlOr(String fallback) => _helpUrl ?? fallback;

  /// 连着时查额度的间隔（插件 `poll_quota_secs`，已夹在 20–90 秒）。
  static Duration get quotaPoll => _quotaPoll;

  /// 节点/订阅刷新间隔（插件 `poll_nodes_secs`，已夹在 5–30 分钟）。
  static Duration get nodesPoll => _nodesPoll;

  /// 首页/设置页等进入时顺手调一次，让后面用到这些值时大概率已经是新的；
  /// 不调也没事，各个 getter 本来就有内置默认值兜底，只是可能慢一版。
  static Future<void> ensureLoaded() {
    if (_fresh) return Future.value();
    return _inflight ??= _load().whenComplete(() => _inflight = null);
  }

  static Future<void> _load() async {
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
      _deviceApi ??= _nonEmpty(prefs.getString(_deviceApiKey));
      _accountUrl ??= _nonEmpty(prefs.getString(_accountUrlKey));
      _helpUrl ??= _nonEmpty(prefs.getString(_helpUrlKey));
    } catch (_) {
      // 读本地缓存失败不影响去问服务器
    }
    try {
      final res = await PanelApiBase.dio().get<dynamic>('/api/v1/guest/comm/config');
      final body = res.data;
      final data = (body is Map && body['data'] is Map) ? body['data'] as Map : null;
      final gsl = data != null ? data['gsl_invite'] : null;
      if (gsl is Map) {
        // 空串代表「后台没配置这一项」，不要用它覆盖掉已经缓存的好值。字段类型
        // 用 is 判断而不是硬转换，一个字段格式不对不该拖累另外两个。
        String? field(String key) {
          final v = gsl[key];
          return v is String ? v : null;
        }

        _deviceApi = _nonEmpty(field('device_api')) ?? _deviceApi;
        _accountUrl = _nonEmpty(field('account_url')) ?? _accountUrl;
        _helpUrl = _nonEmpty(field('help_url')) ?? _helpUrl;
        _quotaPoll = _clampSecs(gsl['poll_quota_secs'], 45, 20, 90);
        _nodesPoll = _clampSecs(gsl['poll_nodes_secs'], 720, 300, 1800);
        unawaited(_persist(prefs));
      }
      _fetchedAt = DateTime.now();
    } catch (_) {
      // 拿不到就继续用已有缓存/调用方自己的默认值，不阻塞任何 UI
    }
  }

  static Future<void> _persist(SharedPreferences? prefsIn) async {
    try {
      final prefs = prefsIn ?? await SharedPreferences.getInstance();
      if (_deviceApi != null) await prefs.setString(_deviceApiKey, _deviceApi!);
      if (_accountUrl != null) await prefs.setString(_accountUrlKey, _accountUrl!);
      if (_helpUrl != null) await prefs.setString(_helpUrlKey, _helpUrl!);
    } catch (_) {}
  }

  static String? _nonEmpty(String? raw) {
    final v = raw?.trim();
    return (v == null || v.isEmpty) ? null : v;
  }

  static Duration _clampSecs(dynamic raw, int fallback, int min, int max) {
    int? n;
    if (raw is int) {
      n = raw;
    } else if (raw is num) {
      n = raw.toInt();
    } else if (raw is String) {
      n = int.tryParse(raw.trim());
    }
    final v = (n == null || n <= 0) ? fallback : n;
    final clamped = v < min ? min : (v > max ? max : v);
    return Duration(seconds: clamped);
  }
}

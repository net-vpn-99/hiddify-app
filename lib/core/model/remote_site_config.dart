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
  static const _tgGroupKey = 'oneray_site_tg_group';
  static const _sitesUrlKey = 'oneray_site_sites_url';
  static const _aiRegionsKey = 'oneray_site_ai_regions';
  static const _aiTextKey = 'oneray_site_ai_text';
  static const _aiTagKey = 'oneray_site_ai_tag';
  static const _customUrlKey = 'oneray_site_custom_url';
  static const _customOnKey = 'oneray_site_custom_on';

  static String? _deviceApi;
  static String? _accountUrl;
  static String? _helpUrl;
  static String? _tgGroup;
  static String? _sitesUrl;
  static Set<String> _aiTipRegions = {};
  static String? _aiTipText;
  static String? _aiTipTag;
  static String? _customUrl;
  static bool _customEnabled = false;
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

  /// Telegram 交流群。后台没配或清空就是 null，入口整行不显示。
  static String? get telegramGroup => _tgGroup;

  /// 只接受 https 的 t.me / telegram.me。别的写法当没配。
  static Uri? get telegramGroupUri {
    final raw = _tgGroup;
    if (raw == null) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.scheme != 'https') return null;
    if (uri.host != 't.me' && uri.host != 'telegram.me') return null;
    return uri;
  }

  /// 「常用网站」页。只接受 https；空 = 不显示入口。
  static String? get sitesUrl => _sitesUrl;

  /// 哪些地区的线路要提示，两位小写国家代码。空 = 不提示。
  static Set<String> get aiTipRegions => _aiTipRegions;

  /// 连着这些地区时首页那一行。空 = 不显示。
  static String? get aiTipText => _aiTipText;

  /// 线路列表里这些地区名字后面的小灰字。空 = 不显示。
  static String? get aiTipTag => _aiTipTag;

  /// 「专属定制」网页。只接受 https。还要 [customEnabled] 才显示入口。
  static String? get customUrl => _customUrl;

  /// GslShop 的总开关。关着时不显示专属定制入口。
  static bool get customEnabled => _customEnabled;

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
      _tgGroup ??= _nonEmpty(prefs.getString(_tgGroupKey));
      _sitesUrl ??= _https(prefs.getString(_sitesUrlKey));
      _aiTipRegions = _regionsOf(prefs.getString(_aiRegionsKey));
      _aiTipText ??= _nonEmpty(prefs.getString(_aiTextKey));
      _aiTipTag ??= _nonEmpty(prefs.getString(_aiTagKey));
      _customUrl ??= _https(prefs.getString(_customUrlKey));
      _customEnabled = prefs.getBool(_customOnKey) ?? _customEnabled;
    } catch (_) {
      // 读本地缓存失败不影响去问服务器
    }
    try {
      final res = await PanelApiBase.dio().get<dynamic>('/api/v1/guest/comm/config');
      final body = res.data;
      final data = (body is Map && body['data'] is Map) ? body['data'] as Map : null;
      final gsl = data != null ? data['gsl_invite'] : null;
      final shop = data != null ? data['gsl_shop'] : null;
      if (shop is Map && shop['custom_enabled'] is bool) {
        _customEnabled = shop['custom_enabled'] as bool;
      }
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
        final tg = field('support_telegram_group');
        if (tg != null) _tgGroup = _nonEmpty(tg);
        final sites = field('sites_url');
        if (sites != null) _sitesUrl = _https(sites);
        final regions = gsl['ai_tip_regions'];
        if (regions is List) _aiTipRegions = _regionsOfList(regions);
        final tip = field('ai_tip_text');
        if (tip != null) _aiTipText = _nonEmpty(tip);
        final tag = field('ai_tip_tag');
        if (tag != null) _aiTipTag = _nonEmpty(tag);
        final custom = field('custom_url');
        if (custom != null) _customUrl = _https(custom);
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
      if (_tgGroup != null) {
        await prefs.setString(_tgGroupKey, _tgGroup!);
      } else {
        await prefs.remove(_tgGroupKey);
      }
      await _putOrRemove(prefs, _sitesUrlKey, _sitesUrl);
      if (_aiTipRegions.isEmpty) {
        await prefs.remove(_aiRegionsKey);
      } else {
        await prefs.setString(_aiRegionsKey, (_aiTipRegions.toList()..sort()).join(','));
      }
      await _putOrRemove(prefs, _aiTextKey, _aiTipText);
      await _putOrRemove(prefs, _aiTagKey, _aiTipTag);
      await _putOrRemove(prefs, _customUrlKey, _customUrl);
      await prefs.setBool(_customOnKey, _customEnabled);
    } catch (_) {}
  }

  static String? _nonEmpty(String? raw) {
    final v = raw?.trim();
    return (v == null || v.isEmpty) ? null : v;
  }

  /// 只留 https。http 或其他写法当没配。
  static String? _https(String? raw) {
    final v = _nonEmpty(raw);
    if (v == null) return null;
    final uri = Uri.tryParse(v);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
    return v;
  }

  static Future<void> _putOrRemove(SharedPreferences prefs, String key, String? value) async {
    if (value != null) {
      await prefs.setString(key, value);
    } else {
      await prefs.remove(key);
    }
  }

  static Set<String> _regionsOf(String? raw) {
    if (raw == null || raw.trim().isEmpty) return {};
    return _regionsOfList(raw.split(','));
  }

  static Set<String> _regionsOfList(List<dynamic> raw) {
    final out = <String>{};
    for (final item in raw) {
      if (item is! String) continue;
      final code = item.trim().toLowerCase();
      if (RegExp(r'^[a-z]{2}$').hasMatch(code)) out.add(code);
    }
    return out;
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

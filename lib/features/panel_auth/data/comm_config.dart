import 'package:hiddify/features/panel_auth/data/panel_api_base.dart';

/// 服务器回了，但不是 2xx（被墙页 / 网关错误）。调用方按「连不上服务器」处理。
class CommConfigUnavailable implements Exception {
  const CommConfigUnavailable(this.statusCode);
  final int? statusCode;
}

/// 免登录配置 `guest/comm/config` 只拉一份、大家共用（体检修复 A3）。
///
/// 以前 6 处各拉各的：注册选项、游客开关、邀请文案、站点地址、购买推荐档、版本卡片、客服地址，
/// 一打开 App 就同一个请求发好几遍。现在同一时间只有一个在飞，拉到的结果 10 分钟内直接用；
/// 拉失败不记（下一个调用方会重新拉），各调用方自己的兜底照旧。
class CommConfig {
  CommConfig._();

  static const _fresh = Duration(minutes: 10);
  static Map<String, dynamic>? _data;
  static DateTime? _at;
  static Future<Map<String, dynamic>>? _inflight;

  /// 返回 `data` 对象。网络错误原样抛 DioException；回了非 2xx 抛 [CommConfigUnavailable]。
  static Future<Map<String, dynamic>> get() {
    final data = _data;
    final at = _at;
    if (data != null && at != null && DateTime.now().difference(at) < _fresh) return Future.value(data);
    return _inflight ??= _fetch().whenComplete(() => _inflight = null);
  }

  static Future<Map<String, dynamic>> _fetch() async {
    final res = await PanelApiBase.dio().get<dynamic>('/api/v1/guest/comm/config');
    final code = res.statusCode;
    if (code == null || code < 200 || code >= 300) throw CommConfigUnavailable(code);
    final body = res.data;
    final raw = body is Map ? body['data'] : null;
    final data = raw is Map ? raw.cast<String, dynamic>() : <String, dynamic>{};
    _data = data;
    _at = DateTime.now();
    return data;
  }
}

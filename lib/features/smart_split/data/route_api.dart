import 'package:dio/dio.dart';
import 'package:hiddify/features/panel_auth/data/panel_api_base.dart';
import 'package:hiddify/features/smart_split/model/split_choices.dart';

/// 发一个请求，回 (状态码, 回答原文)。网络错误抛出，RouteApi 当失败处理。
typedef RouteTransport = Future<(int, String)> Function(String method, String path, {Object? data});

/// 智能分流的面板接口（GslStats RouteController）：账号里的网站、名单、服务器默认。
/// 任何失败都回 null / false，调用方用上次存的。
class RouteApi {
  RouteApi(this._send);

  /// 走面板「当前可用 API」（跟登录、拉订阅同一套候选域名）；[token] 为空时只能调游客接口。
  factory RouteApi.panel({String? token}) {
    final dio = PanelApiBase.dio();
    return RouteApi((method, path, {data}) async {
      final res = await dio.request<String>(
        path,
        data: data,
        options: Options(
          method: method,
          responseType: ResponseType.plain,
          contentType: Headers.jsonContentType,
          headers: {if (token != null && token.isNotEmpty) ...{'auth_data': token, 'Authorization': token}},
        ),
      );
      return (res.statusCode ?? 0, res.data ?? '');
    });
  }

  final RouteTransport _send;

  Future<String?> _ok(String method, String path, {Object? data}) async {
    try {
      final (code, body) = await _send(method, path, data: data);
      return code >= 200 && code < 300 ? body : null;
    } catch (_) {
      return null;
    }
  }

  /// 账号里的网站；拉不到 null。
  Future<List<SplitChoice>?> list() async {
    final body = await _ok('GET', '/api/v1/user/gsl_route/list');
    return body == null ? null : parseAccountList(body);
  }

  Future<bool> set(String body) async => await _ok('POST', '/api/v1/user/gsl_route/set', data: body) != null;

  Future<bool> del(String key) async => await _ok('POST', '/api/v1/user/gsl_route/del', data: {'key': key}) != null;

  Future<bool> reset() async => await _ok('POST', '/api/v1/user/gsl_route/reset') != null;

  /// 名单原文；跟手上的版本一样（服务器回 {"same":true}）或拉不到回 null。
  Future<String?> things(int haveVersion) async {
    final body = await _ok('GET', '/api/v1/guest/gsl_route/things?have=$haveVersion');
    if (body == null || body.contains('"same":true')) return null;
    return body;
  }

  /// 服务器默认（锁住的、必须的、改成默认的）；拉不到 null。
  Future<RouteDefaults?> defaults() async {
    final body = await _ok('GET', '/api/v1/guest/gsl_route/defaults');
    return body == null ? null : parseRouteDefaults(body);
  }
}

import 'package:dio/dio.dart';
import 'package:hiddify/core/model/constants.dart';

/// 对接 Xboard 会员系统。接口与桌面版 OneRay 保持一致
/// （见 VPN 仓库 src/control/XboardControlPlane.cpp）。
class PanelApi {
  PanelApi({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: Constants.panelApiBase,
                connectTimeout: const Duration(seconds: 15),
                receiveTimeout: const Duration(seconds: 20),
                // 任何状态码都不抛，交给调用方按 body 判断
                validateStatus: (_) => true,
                headers: {'User-Agent': 'OneRay-Android'},
              ),
            );

  final Dio _dio;

  /// 登录，成功返回 auth 令牌（用于后续请求头 `auth_data`）。
  /// 失败抛 [PanelApiException]，message 为可直接展示给用户的中文。
  Future<String> login(String email, String password) async {
    Response<dynamic> res;
    try {
      res = await _dio.post<dynamic>(
        '/api/v1/passport/auth/login',
        data: {'email': email, 'password': password},
      );
    } on DioException catch (e) {
      throw PanelApiException(_networkMessage(e));
    }
    final token = _extractToken(res.data);
    if (token != null && token.isNotEmpty) return token;

    final msg = _messageOf(res.data) ?? '登录失败，请检查邮箱和密码';
    throw PanelApiException(msg);
  }

  /// 拉当前账号的订阅地址。需要登录令牌。
  Future<PanelSubscribe> getSubscribe(String token) async {
    Response<dynamic> res;
    try {
      res = await _dio.get<dynamic>(
        '/api/v1/user/getSubscribe',
        options: Options(headers: {'auth_data': token, 'Authorization': token}),
      );
    } on DioException catch (e) {
      throw PanelApiException(_networkMessage(e));
    }
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw PanelApiException('登录已过期，请重新登录', unauthorized: true);
    }
    final data = _dataOf(res.data);
    if (data == null) {
      throw PanelApiException(_messageOf(res.data) ?? '获取订阅失败');
    }
    var url = (data['subscribe_url'] as String?)?.trim() ?? '';
    final subToken = (data['token'] as String?)?.trim() ?? '';
    if (url.isEmpty && subToken.isNotEmpty) {
      url = '${Constants.panelApiBase}/api/v1/client/subscribe?token=$subToken';
    }
    if (url.isEmpty) {
      throw PanelApiException('该账号还没有可用套餐，请先在会员中心购买');
    }
    return PanelSubscribe(
      subscribeUrl: url,
      email: (data['email'] as String?)?.trim(),
    );
  }

  // --- helpers ---

  String? _extractToken(dynamic body) {
    final data = _dataOf(body);
    return _str(data?['auth_data']) ??
        _str(data?['token']) ??
        _str((body is Map) ? body['auth_data'] : null) ??
        _str((body is Map) ? body['token'] : null);
  }

  Map<String, dynamic>? _dataOf(dynamic body) {
    if (body is Map && body['data'] is Map) {
      return (body['data'] as Map).cast<String, dynamic>();
    }
    return null;
  }

  String? _messageOf(dynamic body) {
    if (body is Map) {
      final m = body['message'] ?? body['error'];
      if (m is String && m.trim().isNotEmpty) return m.trim();
    }
    return null;
  }

  String? _str(dynamic v) => (v is String && v.isNotEmpty) ? v : null;

  String _networkMessage(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return '连接超时，请检查网络后重试';
      default:
        return '无法连接服务器，请检查网络';
    }
  }
}

class PanelSubscribe {
  const PanelSubscribe({required this.subscribeUrl, this.email});
  final String subscribeUrl;
  final String? email;
}

class PanelApiException implements Exception {
  PanelApiException(this.message, {this.unauthorized = false});
  final String message;
  final bool unauthorized;
  @override
  String toString() => message;
}

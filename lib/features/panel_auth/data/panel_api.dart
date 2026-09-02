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
      account: _accountOf(data),
    );
  }

  /// 单独拉账号信息（会员页刷新用）。
  Future<PanelAccount> getAccount(String token) async {
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
    if (data == null) throw PanelApiException(_messageOf(res.data) ?? '获取账号信息失败');
    return _accountOf(data);
  }

  PanelAccount _accountOf(Map<String, dynamic> data) {
    num n(dynamic v) => v is num ? v : num.tryParse('$v') ?? 0;
    final plan = data['plan'];
    return PanelAccount(
      email: (data['email'] as String?)?.trim(),
      planName: (plan is Map ? plan['name'] as String? : null)?.trim() ?? (data['plan_name'] as String?)?.trim(),
      expiredAt: data['expired_at'] == null ? null : n(data['expired_at']).toInt(),
      transferEnable: n(data['transfer_enable']).toInt(),
      used: (n(data['u']) + n(data['d'])).toInt(),
      deviceLimit: n(data['device_limit']).toInt(),
    );
  }

  /// 发邮箱验证码（注册 / 找回密码用）。
  Future<void> sendEmailCode(String email) async {
    Response<dynamic> res;
    try {
      res = await _dio.post<dynamic>(
        '/api/v1/passport/comm/sendEmailVerify',
        data: {'email': email.trim()},
      );
    } on DioException catch (e) {
      throw PanelApiException(_networkMessage(e));
    }
    final data = _dataOf(res.data);
    if (data != null || res.statusCode == 200) return;
    throw PanelApiException(_messageOf(res.data) ?? '验证码发送失败，请稍后再试');
  }

  /// 用邮箱验证码重置密码。
  Future<void> resetPassword(String email, String newPassword, String code) async {
    Response<dynamic> res;
    try {
      res = await _dio.post<dynamic>(
        '/api/v1/passport/auth/forget',
        data: {'email': email.trim(), 'password': newPassword, 'email_code': code.trim()},
      );
    } on DioException catch (e) {
      throw PanelApiException(_networkMessage(e));
    }
    if (_dataOf(res.data) != null || res.statusCode == 200) return;
    throw PanelApiException(_messageOf(res.data) ?? '重置失败，请检查验证码');
  }

  /// 拿邀请码（没有就让面板生成一个），返回 (code, link)。
  Future<({String code, String link})> getInvite(String token) async {
    final opt = Options(headers: {'auth_data': token, 'Authorization': token});
    String? readCode(dynamic body) {
      final data = _dataOf(body);
      final codes = data?['codes'];
      if (codes is List) {
        for (final c in codes) {
          if (c is Map && c['code'] is String && (c['code'] as String).isNotEmpty) {
            return c['code'] as String;
          }
        }
      }
      return null;
    }

    Response<dynamic> res;
    try {
      res = await _dio.get<dynamic>('/api/v1/user/invite/fetch', options: opt);
      if (res.statusCode == 401 || res.statusCode == 403) {
        throw PanelApiException('登录已过期，请重新登录', unauthorized: true);
      }
      var code = readCode(res.data);
      if (code == null) {
        await _dio.get<dynamic>('/api/v1/user/invite/save', options: opt);
        res = await _dio.get<dynamic>('/api/v1/user/invite/fetch', options: opt);
        code = readCode(res.data);
      }
      if (code == null) throw PanelApiException('面板没有返回邀请码');
      return (code: code, link: 'https://www.guangsuleida.com/i/?c=$code');
    } on DioException catch (e) {
      throw PanelApiException(_networkMessage(e));
    }
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
  const PanelSubscribe({required this.subscribeUrl, this.email, this.account});
  final String subscribeUrl;
  final String? email;
  final PanelAccount? account;
}

class PanelAccount {
  const PanelAccount({
    this.email,
    this.planName,
    this.expiredAt,
    this.transferEnable = 0,
    this.used = 0,
    this.deviceLimit = 0,
  });

  final String? email;
  final String? planName;
  final int? expiredAt; // unix 秒；null = 长期有效
  final int transferEnable; // 总流量字节
  final int used; // 已用字节
  final int deviceLimit; // 0 = 不限

  bool get lifetime => expiredAt == null || expiredAt == 0;
  int get remainingBytes => (transferEnable - used).clamp(0, transferEnable);
}

class PanelApiException implements Exception {
  PanelApiException(this.message, {this.unauthorized = false});
  final String message;
  final bool unauthorized;
  @override
  String toString() => message;
}

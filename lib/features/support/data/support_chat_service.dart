import 'dart:io';

import 'package:dio/dio.dart';
import 'package:hiddify/features/support/model/support_message.dart';

/// 在线客服：直接调 Chatwoot 官网小组件用的那套公开接口（/api/v1/widget/*），
/// 后台是同一个 Chatwoot（kf.guangsuleida.com）—— 客服在网页后台 / 手机 App 看到的
/// 是同一条会话，跟官网气泡、chat.html 完全等价，只是这边用原生界面画出来。
///
/// 认证：从 GET /widget?website_token=... 这张网页里嵌的 <script> 解析出 authToken
/// （一个有效期很长的 JWT，带 source_id / inbox_id），拿到一次存本机长期复用；
/// 之后所有 /api/v1/widget/* 请求都带 `X-Auth-Token` 头 + `website_token` 查询参数。
class SupportChatService {
  SupportChatService()
      : _dio = Dio(
          BaseOptions(
            baseUrl: _base,
            connectTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 20),
            sendTimeout: const Duration(seconds: 30),
            validateStatus: (_) => true,
            headers: {'User-Agent': 'OneRay-Android'},
          ),
        );

  // 官网「在线客服」用的同一串（website/assets/site.js、website/chat.html 里那个），
  // 本来就写在网页源码里公开可见，不是密钥。
  static const _base = 'https://kf.guangsuleida.com';
  static const _websiteToken = '6EDJYPA8bcduF3GjoFTCEvdZ';

  final Dio _dio;

  Map<String, dynamic> get _q => {'website_token': _websiteToken};

  Options _auth(String token, {bool json = false}) => Options(
        headers: {
          'X-Auth-Token': token,
          if (json) Headers.contentTypeHeader: Headers.jsonContentType,
        },
      );

  /// 访问 /widget 这张网页，从 `window.authToken='...'` 里抠出访客身份。
  /// 第一次访问会顺带在 Chatwoot 里建一个新联系人。
  Future<String?> fetchAuthToken() async {
    final res = await _dio.get<String>(
      '/widget',
      queryParameters: _q,
      options: Options(responseType: ResponseType.plain),
    );
    if (res.statusCode != 200 || res.data == null) return null;
    final m = RegExp(r"window\.authToken\s*=\s*'([^']+)'").firstMatch(res.data!);
    return m?.group(1);
  }

  /// 这台设备有没有建过会话。返回 (存在, http 状态码)。
  /// 状态码 401/404 = 缓存的 token 被服务器拒了，调用方应清掉重来。
  Future<({bool exists, int status})> conversationStatus(String token) async {
    final res = await _dio.get<dynamic>(
      '/api/v1/widget/conversations',
      queryParameters: _q,
      options: _auth(token),
    );
    final status = res.statusCode ?? 0;
    final body = res.data;
    final exists = body is Map && body['id'] != null;
    return (exists: exists, status: status);
  }

  /// 拉全部消息。失败返回 null（轮询静默重试下一轮）。
  Future<List<SupportMessage>?> fetchMessages(String token) async {
    final res = await _dio.get<dynamic>(
      '/api/v1/widget/messages',
      queryParameters: _q,
      options: _auth(token),
    );
    if (res.statusCode != 200) return null;
    final body = res.data;
    final List<dynamic> arr;
    if (body is Map && body['payload'] is List) {
      arr = body['payload'] as List<dynamic>;
    } else if (body is List) {
      arr = body;
    } else {
      return const [];
    }

    final out = <SupportMessage>[];
    for (final e in arr) {
      if (e is! Map) continue;
      final content = (e['content'] as String?) ?? '';

      var imageUrl = '';
      final atts = e['attachments'];
      if (atts is List && atts.isNotEmpty && atts.first is Map) {
        final a = atts.first as Map;
        if (a['file_type'] == 'image') imageUrl = (a['data_url'] as String?) ?? '';
      }
      if (content.isEmpty && imageUrl.isEmpty) continue;

      final type = (e['message_type'] as num?)?.toInt() ?? -1;
      final createdAt = (e['created_at'] as num?)?.toDouble() ?? 0;
      out.add(
        SupportMessage(
          id: (e['id'] as num?)?.toInt() ?? 0,
          text: content,
          imageUrl: imageUrl,
          mine: type == 0,
          system: type == 2 || type == 3,
          timeMs: createdAt > 0 ? (createdAt * 1000).toInt() : 0,
        ),
      );
    }
    out.sort((a, b) => a.id.compareTo(b.id));
    return out;
  }

  /// 发一条文字。[createConversation] = 这台设备第一次发消息（顺带建会话 + 记邮箱/套餐/版本）。
  /// 返回 http 状态码；调用方按 2xx / 401 / 404 / 其它 处理。
  Future<int> sendText(
    String token,
    String text, {
    required bool createConversation,
    String? email,
    String? plan,
    String? version,
  }) async {
    final message = {'content': text};
    final Response<dynamic> res;
    if (createConversation) {
      final contact = <String, dynamic>{
        if (email != null && email.isNotEmpty) 'email': email,
        'custom_attributes': {
          '平台': 'android',
          if (plan != null && plan.isNotEmpty) '套餐': plan,
          if (version != null && version.isNotEmpty) '版本': version,
        },
      };
      res = await _dio.post<dynamic>(
        '/api/v1/widget/conversations',
        queryParameters: _q,
        options: _auth(token, json: true),
        data: {'contact': contact, 'message': message},
      );
    } else {
      res = await _dio.post<dynamic>(
        '/api/v1/widget/messages',
        queryParameters: _q,
        options: _auth(token, json: true),
        data: {'message': message},
      );
    }
    return res.statusCode ?? 0;
  }

  /// 发一张图（multipart）。附件接口不支持带联系人资料，所以第一次发图建的会话
  /// 不带邮箱/套餐 —— 属于可接受的小遗憾（之后发文字时也补不上）。
  Future<int> sendImage(String token, File file) async {
    final form = FormData.fromMap({
      'message[attachments][]': await MultipartFile.fromFile(file.path, filename: _basename(file.path)),
    });
    final res = await _dio.post<dynamic>(
      '/api/v1/widget/messages',
      queryParameters: _q,
      options: _auth(token),
      data: form,
    );
    return res.statusCode ?? 0;
  }

  String _basename(String path) {
    final i = path.lastIndexOf(RegExp(r'[/\\]'));
    return i >= 0 ? path.substring(i + 1) : path;
  }
}

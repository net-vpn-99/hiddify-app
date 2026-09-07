import 'package:dio/dio.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/features/purchase/model/plan_offer.dart';

/// App 内购买 —— 对接 Xboard 订单接口，跟桌面版 OneRay 同一套
/// （见 VPN 仓库 src/control/XboardControlPlane.cpp 的 purchasePlan）。
///
/// 流程：清理旧的未付订单 → order/save 建单 → getPaymentMethod → order/checkout
/// 拿到易支付收银台地址 → 用系统浏览器打开付款 → 回 App 后 order/check 查状态。
class PurchaseService {
  PurchaseService()
      : _dio = Dio(
          BaseOptions(
            baseUrl: Constants.panelApiBase,
            connectTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 20),
            validateStatus: (_) => true,
            headers: {'User-Agent': 'OneRay-Android'},
          ),
        );

  final Dio _dio;

  Options _opt(String token) => Options(headers: {'auth_data': token, 'Authorization': token});

  Map<String, dynamic>? _data(dynamic body) =>
      (body is Map && body['data'] is Map) ? (body['data'] as Map).cast<String, dynamic>() : null;

  String? _message(dynamic body) {
    if (body is Map) {
      final m = body['message'] ?? body['error'];
      if (m is String && m.trim().isNotEmpty) return m.trim();
    }
    return null;
  }

  /// 拉可购买的套餐（已展开成「套餐 × 周期」，推荐位在 expand 里按运营常量标好）。
  Future<List<PlanOffer>> fetchPlans(String token) async {
    final res = await _dio.get<dynamic>('/api/v1/user/plan/fetch', options: _opt(token));
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw PurchaseException('登录已过期，请重新登录', unauthorized: true);
    }
    final body = res.data;
    final list = (body is Map && body['data'] is List) ? body['data'] as List<dynamic> : const [];
    final offers = <PlanOffer>[];
    for (final p in list) {
      if (p is Map) offers.addAll(PlanOffer.expand(p.cast<String, dynamic>()));
    }
    return offers;
  }

  /// 清理这个账号所有「未支付」的旧订单，避免「上一笔订单未完成」挡住新下单。
  Future<void> cancelStaleUnpaid(String token) async {
    for (final url in ['/api/v1/user/order/fetch?status=0', '/api/v1/user/order/fetch']) {
      try {
        final res = await _dio.get<dynamic>(url, options: _opt(token));
        final body = res.data;
        final list = (body is Map && body['data'] is List) ? body['data'] as List<dynamic> : const [];
        for (final o in list) {
          if (o is! Map) continue;
          final trade = o['trade_no'] as String?;
          if (trade == null || trade.isEmpty) continue;
          final status = (o['status'] as num?)?.toInt();
          // status==0 = 待支付。第一个接口已按 status=0 过滤，第二个要自己判断。
          if (url.endsWith('status=0') || status == 0) {
            await cancelOrder(token, trade);
          }
        }
      } catch (_) {}
    }
  }

  Future<void> cancelOrder(String token, String tradeNo) async {
    try {
      await _dio.post<dynamic>(
        '/api/v1/user/order/cancel',
        data: {'trade_no': tradeNo},
        options: _opt(token),
      );
    } catch (_) {}
  }

  /// 建订单，返回 trade_no。
  Future<String> createOrder(String token, int planId, String period) async {
    final res = await _dio.post<dynamic>(
      '/api/v1/user/order/save',
      data: {'plan_id': planId, 'period': period},
      options: _opt(token),
    );
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw PurchaseException('登录已过期，请重新登录', unauthorized: true);
    }
    final body = res.data;
    // data 可能直接是 trade_no 字符串，也可能是 {trade_no: ...}
    String? trade;
    if (body is Map && body['data'] is String) trade = body['data'] as String;
    trade ??= _data(body)?['trade_no'] as String?;
    if (trade == null || trade.isEmpty) {
      throw PurchaseException(_message(body) ?? '下单失败，请重试', unpaidBlocker: _looksLikeUnpaidBlocker(_message(body)));
    }
    return trade;
  }

  /// 结账。返回：paid=true 表示余额抵扣已开通；否则 payUrl 是易支付收银台地址。
  Future<({bool paid, String? payUrl})> checkout(String token, String tradeNo) async {
    int? methodId;
    try {
      final mRes = await _dio.get<dynamic>('/api/v1/user/order/getPaymentMethod', options: _opt(token));
      final mBody = mRes.data;
      final methods = (mBody is Map && mBody['data'] is List) ? mBody['data'] as List<dynamic> : const [];
      if (methods.isNotEmpty && methods.first is Map) {
        methodId = ((methods.first as Map)['id'] as num?)?.toInt();
      }
    } catch (_) {}

    final res = await _dio.post<dynamic>(
      '/api/v1/user/order/checkout',
      data: {'trade_no': tradeNo, if (methodId != null && methodId > 0) 'method': methodId},
      options: _opt(token),
    );
    final body = res.data;
    if (res.statusCode != 200) {
      var msg = _message(body) ?? '发起支付失败，请重试';
      if (methodId == null || msg.contains('Payment method') || msg.contains('not available')) {
        msg = '面板还没配置支付方式，请联系客服';
      }
      throw PurchaseException(msg);
    }

    final type = (body is Map ? body['type'] : null) as num? ?? _data(body)?['type'] as num?;
    if (type?.toInt() == -1) return (paid: true, payUrl: null);

    var pay = (body is Map ? body['data'] : null);
    if (pay is! String) pay = _data(body)?['data'];
    final payUrl = pay is String ? pay : null;
    if (payUrl == null || payUrl.isEmpty) {
      throw PurchaseException('没拿到支付链接，请重试或联系客服');
    }
    return (paid: false, payUrl: payUrl);
  }

  /// 查订单是否已支付。status: 0 待支付 / 1 开通中 / 3 已完成。
  Future<bool> isPaid(String token, String tradeNo) async {
    final res = await _dio.get<dynamic>(
      '/api/v1/user/order/check',
      queryParameters: {'trade_no': tradeNo},
      options: _opt(token),
    );
    final body = res.data;
    final status = (_data(body)?['data'] as num?)?.toInt() ?? (body is Map ? (body['data'] as num?)?.toInt() : null);
    return status == 1 || status == 3;
  }

  bool _looksLikeUnpaidBlocker(String? msg) {
    if (msg == null) return false;
    const needles = ['未完成', '未支付', '未付款', '待支付', '开通中', '将其取消', 'unpaid', 'pending order'];
    return needles.any(msg.contains);
  }
}

class PurchaseException implements Exception {
  PurchaseException(this.message, {this.unauthorized = false, this.unpaidBlocker = false});
  final String message;
  final bool unauthorized;
  final bool unpaidBlocker;
  @override
  String toString() => message;
}

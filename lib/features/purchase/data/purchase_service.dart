import 'package:dio/dio.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/features/purchase/model/plan_offer.dart';

/// App 内购买 —— 对接 Xboard 订单接口，跟桌面版 OneRay 同一套
/// （见 VPN 仓库 src/control/XboardControlPlane.cpp + docs/充值续费/数据契约-v2-实测修正.md §4）。
///
/// 流程：识别未完成订单 → order/save 建单 → order/detail 拿后端应付 →
/// getPaymentMethod → order/checkout 拿收银台地址 → 系统浏览器付款 →
/// 回 App 后 order/check 查状态（0 待支付 / 1 开通中 / 3 已完成 / 2 已取消）。
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

  int? _int(dynamic v) => v is num ? v.toInt() : (v is String ? int.tryParse(v) : null);

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

  /// 找出本账号「还没完成」的订单（status 0 待支付 / 1 开通中），返回最近一笔。
  /// **不取消任何订单** —— Xboard 的 order/save 有未完成订单时会直接报错，
  /// 所以下新单前先认这一笔：同档就续用，不同档让用户自己决定。
  Future<RecoverableOrder?> findRecoverableOrder(String token) async {
    try {
      final res = await _dio.get<dynamic>('/api/v1/user/order/fetch', options: _opt(token));
      final body = res.data;
      final list = (body is Map && body['data'] is List) ? body['data'] as List<dynamic> : const [];
      for (final o in list) {
        if (o is! Map) continue;
        final st = orderStatusFrom(_int(o['status']));
        if (st != OrderStatus.pending && st != OrderStatus.activating) continue;
        final trade = o['trade_no'] as String?;
        if (trade == null || trade.isEmpty) continue;
        final plan = o['plan'];
        return RecoverableOrder(
          tradeNo: trade,
          status: st,
          planId: _int(plan is Map ? plan['id'] : null) ?? _int(o['plan_id']) ?? 0,
          period: (o['period'] as String?) ?? '',
          planName: (plan is Map ? plan['name'] as String? : null)?.trim(),
          amountCents: _int(o['total_amount']),
        );
      }
    } catch (_) {}
    return null;
  }

  /// 取消单笔订单 —— 只在用户明确点了「放弃这笔」时调用。
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

  /// 订单详情 —— 拿后端核算后的应付金额（续费按比例、升级抵扣旧套餐都体现在这里）。
  Future<OrderQuote> orderDetail(String token, String tradeNo) async {
    final res = await _dio.get<dynamic>(
      '/api/v1/user/order/detail',
      queryParameters: {'trade_no': tradeNo},
      options: _opt(token),
    );
    final d = _data(res.data);
    return OrderQuote(
      totalCents: _int(d?['total_amount']) ?? 0,
      handlingCents: _int(d?['handling_amount']) ?? 0,
      discountCents: _int(d?['discount_amount']) ?? 0,
      surplusCents: _int(d?['surplus_amount']) ?? 0,
      balanceCents: _int(d?['balance_amount']) ?? 0,
    );
  }

  /// 结账。返回：paid=true 表示余额抵扣已开通；否则 payUrl 是收银台地址。
  Future<({bool paid, String? payUrl})> checkout(String token, String tradeNo) async {
    int? methodId;
    try {
      final mRes = await _dio.get<dynamic>('/api/v1/user/order/getPaymentMethod', options: _opt(token));
      final mBody = mRes.data;
      final methods = (mBody is Map && mBody['data'] is List) ? mBody['data'] as List<dynamic> : const [];
      // 目前面板只有一个支付方式；多于一个时仍取第一个（sort 最小），
      // 真要多方式选择得加个选择器（见 docs/充值续费/实施计划.md）。
      if (methods.isNotEmpty && methods.first is Map) {
        methodId = _int((methods.first as Map)['id']);
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

  /// 查订单状态。data 是裸整数：0 待支付 / 1 开通中 / 2 已取消 / 3 已完成 / 4 已折抵。
  Future<OrderStatus> checkStatus(String token, String tradeNo) async {
    final res = await _dio.get<dynamic>(
      '/api/v1/user/order/check',
      queryParameters: {'trade_no': tradeNo},
      options: _opt(token),
    );
    final body = res.data;
    final s = _int(_data(body)?['data']) ?? (body is Map ? _int(body['data']) : null);
    return orderStatusFrom(s);
  }

  bool _looksLikeUnpaidBlocker(String? msg) {
    if (msg == null) return false;
    const needles = ['未完成', '未支付', '未付款', '待支付', '开通中', '将其取消', 'unpaid', 'pending order'];
    return needles.any(msg.contains);
  }
}

/// 订单状态（数据契约 §4）。activating(1) 和 fulfilled(3) 必须分开：
/// 前者是「已付款、权益开通中」，后者才是「已开通」。
enum OrderStatus { pending, activating, fulfilled, cancelled, unknown }

OrderStatus orderStatusFrom(int? s) => switch (s) {
      0 => OrderStatus.pending,
      1 => OrderStatus.activating,
      3 => OrderStatus.fulfilled,
      2 || 4 => OrderStatus.cancelled, // 4 = 已折抵，对用户等同「这单不用管了」
      _ => OrderStatus.unknown,
    };

class RecoverableOrder {
  const RecoverableOrder({
    required this.tradeNo,
    required this.status,
    required this.planId,
    required this.period,
    this.planName,
    this.amountCents,
  });

  final String tradeNo;
  final OrderStatus status;
  final int planId;
  final String period;
  final String? planName;
  final int? amountCents;

  bool matches(PlanOffer offer) => planId == offer.planId && period == offer.period;

  String get amountLabel =>
      amountCents == null ? '' : '¥${(amountCents! / 100).toStringAsFixed(2)}'.replaceAll(RegExp(r'\.00$'), '');
}

class OrderQuote {
  const OrderQuote({
    required this.totalCents,
    required this.handlingCents,
    required this.discountCents,
    required this.surplusCents,
    required this.balanceCents,
  });

  final int totalCents;
  final int handlingCents;
  final int discountCents;
  final int surplusCents;
  final int balanceCents;

  /// 最终应付（含手续费）。
  int get payableCents => totalCents + handlingCents;

  String _yuan(int cents) => '¥${(cents / 100).toStringAsFixed(2)}'.replaceAll(RegExp(r'\.00$'), '');

  String get payableLabel => _yuan(payableCents);

  /// 有抵扣 / 手续费时给一句说明，否则空。
  String get note {
    final parts = <String>[];
    if (discountCents > 0) parts.add('优惠 -${_yuan(discountCents)}');
    if (surplusCents > 0) parts.add('旧套餐抵扣 -${_yuan(surplusCents)}');
    if (balanceCents > 0) parts.add('余额抵扣 -${_yuan(balanceCents)}');
    if (handlingCents > 0) parts.add('手续费 +${_yuan(handlingCents)}');
    return parts.join(' · ');
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

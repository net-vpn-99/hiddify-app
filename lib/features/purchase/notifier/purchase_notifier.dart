import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/profile/notifier/profile_notifier.dart';
import 'package:hiddify/features/purchase/data/purchase_service.dart';
import 'package:hiddify/features/purchase/model/plan_offer.dart';
import 'package:hiddify/utils/uri_utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

enum PurchaseStage { browsing, working, awaitingPayment, success }

@immutable
class PurchaseState {
  const PurchaseState({
    this.plansLoading = true,
    this.plans = const [],
    this.plansError,
    this.stage = PurchaseStage.browsing,
    this.error,
    this.tradeNo,
    this.refreshing = false,
    this.refreshFailed = false,
  });

  final bool plansLoading;
  final List<PlanOffer> plans;
  final String? plansError;

  final PurchaseStage stage;

  /// 当前流程里的一次性提示（下单失败、还没查到支付 等）。
  final String? error;
  final String? tradeNo;

  /// 支付成功后，订阅信息刷新中 / 刷新失败（跟「是否付款成功」分开）。
  final bool refreshing;
  final bool refreshFailed;

  PurchaseState copyWith({
    bool? plansLoading,
    List<PlanOffer>? plans,
    Object? plansError = _keep,
    PurchaseStage? stage,
    Object? error = _keep,
    Object? tradeNo = _keep,
    bool? refreshing,
    bool? refreshFailed,
  }) {
    return PurchaseState(
      plansLoading: plansLoading ?? this.plansLoading,
      plans: plans ?? this.plans,
      plansError: plansError == _keep ? this.plansError : plansError as String?,
      stage: stage ?? this.stage,
      error: error == _keep ? this.error : error as String?,
      tradeNo: tradeNo == _keep ? this.tradeNo : tradeNo as String?,
      refreshing: refreshing ?? this.refreshing,
      refreshFailed: refreshFailed ?? this.refreshFailed,
    );
  }

  static const _keep = Object();
}

final purchaseNotifierProvider =
    NotifierProvider.autoDispose<PurchaseNotifier, PurchaseState>(PurchaseNotifier.new);

class PurchaseNotifier extends AutoDisposeNotifier<PurchaseState> {
  final _service = PurchaseService();

  @override
  PurchaseState build() {
    Future.microtask(loadPlans);
    return const PurchaseState();
  }

  Future<String?> _token() => ref.read(panelAuthProvider.notifier).currentToken();

  Future<void> loadPlans() async {
    state = state.copyWith(plansLoading: true, plansError: null);
    final token = await _token();
    if (token == null || token.isEmpty) {
      state = state.copyWith(plansLoading: false, plansError: '请先登录');
      return;
    }
    try {
      final plans = await _service.fetchPlans(token);
      state = state.copyWith(
        plansLoading: false,
        plans: plans,
        plansError: plans.isEmpty ? '暂时没有可购买的套餐' : null,
      );
    } on PurchaseException catch (e) {
      state = state.copyWith(plansLoading: false, plansError: e.message);
    } catch (_) {
      state = state.copyWith(plansLoading: false, plansError: '拉取套餐失败，请检查网络');
    }
  }

  /// 选中一个套餐档 → 建单 → 结账 → 打开收银台。
  Future<void> startPurchase(PlanOffer offer) async {
    if (state.stage == PurchaseStage.working) return;
    final token = await _token();
    if (token == null || token.isEmpty) {
      state = state.copyWith(error: '请先登录');
      return;
    }
    state = state.copyWith(stage: PurchaseStage.working, error: null, refreshFailed: false);

    try {
      await _service.cancelStaleUnpaid(token);
      String trade;
      try {
        trade = await _service.createOrder(token, offer.planId, offer.period);
      } on PurchaseException catch (e) {
        if (!e.unpaidBlocker) rethrow;
        // 再清一次再试
        await _service.cancelStaleUnpaid(token);
        trade = await _service.createOrder(token, offer.planId, offer.period);
      }
      state = state.copyWith(tradeNo: trade);

      final r = await _service.checkout(token, trade);
      if (r.paid) {
        await _onPaid();
        return;
      }
      final opened = await UriUtils.tryLaunch(Uri.parse(r.payUrl!));
      state = state.copyWith(
        stage: PurchaseStage.awaitingPayment,
        error: opened ? null : '没能打开支付页面，点「重新打开支付」再试',
      );
    } on PurchaseException catch (e) {
      state = state.copyWith(stage: PurchaseStage.browsing, error: e.message);
    } catch (_) {
      state = state.copyWith(stage: PurchaseStage.browsing, error: '下单出错了，请重试');
    }
  }

  /// 重新打开易支付收银台（同一笔订单）。先查一次是否已支付，避免对已付订单重复结账。
  Future<void> reopenPayment() async {
    final token = await _token();
    final trade = state.tradeNo;
    if (token == null || trade == null) return;
    try {
      if (await _service.isPaid(token, trade)) {
        await _onPaid();
        return;
      }
      final r = await _service.checkout(token, trade);
      if (r.paid) {
        await _onPaid();
        return;
      }
      await UriUtils.tryLaunch(Uri.parse(r.payUrl!));
    } on PurchaseException catch (e) {
      state = state.copyWith(error: e.message);
    } catch (_) {
      state = state.copyWith(error: '打开支付页面失败，请重试');
    }
  }

  /// 「我已完成支付」/ App 回到前台时调用：查订单状态，不因用户返回就判定未付。
  Future<void> checkPayment() async {
    final token = await _token();
    final trade = state.tradeNo;
    if (token == null || trade == null) return;
    if (state.stage != PurchaseStage.awaitingPayment) return;
    state = state.copyWith(stage: PurchaseStage.working, error: null);
    try {
      final paid = await _service.isPaid(token, trade);
      if (paid) {
        await _onPaid();
      } else {
        state = state.copyWith(
          stage: PurchaseStage.awaitingPayment,
          error: '还没查到支付。如果你已经付款，请稍等十几秒再点「我已完成支付」',
        );
      }
    } catch (_) {
      state = state.copyWith(stage: PurchaseStage.awaitingPayment, error: '查询失败，请重试');
    }
  }

  /// 用户明确放弃这笔订单。
  Future<void> abandonOrder() async {
    final token = await _token();
    final trade = state.tradeNo;
    if (token != null && trade != null) {
      await _service.cancelOrder(token, trade);
    }
    state = state.copyWith(stage: PurchaseStage.browsing, error: null, tradeNo: null);
  }

  Future<void> _onPaid() async {
    state = state.copyWith(stage: PurchaseStage.success, error: null, tradeNo: null, refreshing: true);
    final ok = await _refreshSubscription();
    state = state.copyWith(refreshing: false, refreshFailed: !ok);
  }

  Future<void> retryRefresh() async {
    state = state.copyWith(refreshing: true, refreshFailed: false);
    final ok = await _refreshSubscription();
    state = state.copyWith(refreshing: false, refreshFailed: !ok);
  }

  Future<bool> _refreshSubscription() async {
    try {
      final url = await ref.read(panelAuthProvider.notifier).refreshSubscribeUrl();
      try {
        final profile = await ref.read(activeProfileProvider.future);
        if (profile is RemoteProfileEntity) {
          await ref.read(updateProfileNotifierProvider(profile.id).notifier).updateProfile(profile);
        }
      } catch (_) {}
      return url != null;
    } catch (_) {
      return false;
    }
  }
}

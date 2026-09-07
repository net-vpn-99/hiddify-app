import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/panel_auth/data/panel_api.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/profile/notifier/profile_notifier.dart';
import 'package:hiddify/features/purchase/data/purchase_service.dart';
import 'package:hiddify/features/purchase/model/plan_offer.dart';
import 'package:hiddify/utils/uri_utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

enum PurchaseStage { browsing, working, awaitingPayment, success }

const _kPendingTradeKey = 'oneray_purchase_pending_trade';

@immutable
class PurchaseState {
  const PurchaseState({
    this.plansLoading = true,
    this.plans = const [],
    this.plansError,
    this.selected,
    this.stage = PurchaseStage.browsing,
    this.error,
    this.tradeNo,
    this.quote,
    this.pendingOrder,
    this.refreshing = false,
    this.refreshFailed = false,
    this.fulfilled = false,
  });

  final bool plansLoading;
  final List<PlanOffer> plans;
  final String? plansError;

  /// 当前选中的价格档（底栏「去支付」用）。plans 加载完自动选推荐档。
  final PlanOffer? selected;

  final PurchaseStage stage;

  /// 当前流程里的一次性提示（下单失败、还没查到支付 等）。
  final String? error;
  final String? tradeNo;

  /// 当前订单后端核算后的应付金额（含手续费 / 抵扣）。
  final OrderQuote? quote;

  /// 进页面时发现的「上一笔还没完成的订单」——挡住新下单，需用户处理。
  final RecoverableOrder? pendingOrder;

  /// 支付成功后，订阅信息刷新中 / 刷新失败（跟「是否付款成功」分开）。
  final bool refreshing;
  final bool refreshFailed;

  /// 订单已到「已完成(3)」；false = 还在「开通中(1)」，别写「套餐已开通」。
  final bool fulfilled;

  PurchaseState copyWith({
    bool? plansLoading,
    List<PlanOffer>? plans,
    Object? plansError = _keep,
    Object? selected = _keep,
    PurchaseStage? stage,
    Object? error = _keep,
    Object? tradeNo = _keep,
    Object? quote = _keep,
    Object? pendingOrder = _keep,
    bool? refreshing,
    bool? refreshFailed,
    bool? fulfilled,
  }) {
    return PurchaseState(
      plansLoading: plansLoading ?? this.plansLoading,
      plans: plans ?? this.plans,
      plansError: plansError == _keep ? this.plansError : plansError as String?,
      selected: selected == _keep ? this.selected : selected as PlanOffer?,
      stage: stage ?? this.stage,
      error: error == _keep ? this.error : error as String?,
      tradeNo: tradeNo == _keep ? this.tradeNo : tradeNo as String?,
      quote: quote == _keep ? this.quote : quote as OrderQuote?,
      pendingOrder: pendingOrder == _keep ? this.pendingOrder : pendingOrder as RecoverableOrder?,
      refreshing: refreshing ?? this.refreshing,
      refreshFailed: refreshFailed ?? this.refreshFailed,
      fulfilled: fulfilled ?? this.fulfilled,
    );
  }

  static const _keep = Object();
}

final purchaseNotifierProvider =
    NotifierProvider.autoDispose<PurchaseNotifier, PurchaseState>(PurchaseNotifier.new);

/// 购买页顶部「账户 + 剩余流量」卡片用。拉最新订阅信息，失败 / 未登录返回 null。
final purchaseAccountProvider = FutureProvider.autoDispose<PanelAccount?>(
  (ref) => ref.read(panelAuthProvider.notifier).fetchAccount(),
);

class PurchaseNotifier extends AutoDisposeNotifier<PurchaseState> {
  final _service = PurchaseService();

  @override
  PurchaseState build() {
    Future.microtask(loadPlans);
    Future.microtask(_recoverPersistedOrder);
    return const PurchaseState();
  }

  Future<String?> _token() => ref.read(panelAuthProvider.notifier).currentToken();

  // ---- 未完成订单的本地记录（杀进程 / 重启后能恢复）----------------------

  void _persist(String? trade) {
    try {
      final prefs = ref.read(sharedPreferencesProvider).requireValue;
      if (trade == null || trade.isEmpty) {
        prefs.remove(_kPendingTradeKey);
      } else {
        prefs.setString(_kPendingTradeKey, trade);
      }
    } catch (_) {}
  }

  String? _readPersisted() {
    try {
      return ref.read(sharedPreferencesProvider).requireValue.getString(_kPendingTradeKey);
    } catch (_) {
      return null;
    }
  }

  Future<void> _recoverPersistedOrder() async {
    final trade = _readPersisted();
    if (trade == null || trade.isEmpty) return;
    final token = await _token();
    if (token == null || token.isEmpty) return;
    try {
      final st = await _service.checkStatus(token, trade);
      switch (st) {
        case OrderStatus.pending:
          state = state.copyWith(stage: PurchaseStage.awaitingPayment, tradeNo: trade);
        case OrderStatus.activating:
          await _onPaid(fulfilled: false);
        case OrderStatus.fulfilled:
          _persist(null);
        case OrderStatus.cancelled:
        case OrderStatus.unknown:
          _persist(null);
      }
    } catch (_) {
      // 查不到就当作可能还在待支付，留个入口让用户自己点
      state = state.copyWith(stage: PurchaseStage.awaitingPayment, tradeNo: trade);
    }
  }

  // ---- 拉套餐 -----------------------------------------------------------

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
        selected: _pickDefault(plans),
      );
    } on PurchaseException catch (e) {
      state = state.copyWith(plansLoading: false, plansError: e.message);
    } catch (_) {
      state = state.copyWith(plansLoading: false, plansError: '拉取套餐失败，请检查网络');
    }
    // 顺带认一下有没有未完成订单（挡新单用）
    unawaited(_refreshPendingOrder());
  }

  static PlanOffer? _pickDefault(List<PlanOffer> plans) {
    if (plans.isEmpty) return null;
    for (final o in plans) {
      if (o.recommended) return o;
    }
    return plans.first;
  }

  void select(PlanOffer offer) => state = state.copyWith(selected: offer);

  Future<void> _refreshPendingOrder() async {
    if (state.stage != PurchaseStage.browsing) return;
    final token = await _token();
    if (token == null) return;
    final rec = await _service.findRecoverableOrder(token);
    state = state.copyWith(pendingOrder: rec);
  }

  // ---- 下单 / 支付 ----------------------------------------------------

  /// 选中一档 → 若有未完成订单：同档续用 / 不同档提示用户先处理 → 建单 →
  /// 拿后端应付 → 结账 → 打开收银台。
  Future<void> startPurchase(PlanOffer offer) async {
    if (state.stage == PurchaseStage.working) return;
    final token = await _token();
    if (token == null || token.isEmpty) {
      state = state.copyWith(error: '请先登录');
      return;
    }
    state = state.copyWith(stage: PurchaseStage.working, error: null, refreshFailed: false, fulfilled: false);

    try {
      final rec = await _service.findRecoverableOrder(token);
      String trade;
      if (rec != null && !rec.matches(offer)) {
        // 有一笔别的未完成订单，Xboard 不让再下新单 —— 交给用户决定
        state = state.copyWith(
          stage: PurchaseStage.browsing,
          pendingOrder: rec,
          error: '你有一笔未完成的订单，请先在上方处理它',
        );
        return;
      }
      if (rec != null) {
        trade = rec.tradeNo; // 同档，续用原单
      } else {
        try {
          trade = await _service.createOrder(token, offer.planId, offer.period);
        } on PurchaseException catch (e) {
          if (!e.unpaidBlocker) rethrow;
          // 竞态：刚才没查到、这会儿又冒出来了 —— 认一下再决定
          final again = await _service.findRecoverableOrder(token);
          if (again == null) rethrow;
          if (!again.matches(offer)) {
            state = state.copyWith(
              stage: PurchaseStage.browsing,
              pendingOrder: again,
              error: '你有一笔未完成的订单，请先在上方处理它',
            );
            return;
          }
          trade = again.tradeNo;
        }
      }

      _persist(trade);
      OrderQuote? quote;
      try {
        quote = await _service.orderDetail(token, trade);
      } catch (_) {}
      state = state.copyWith(tradeNo: trade, quote: quote, pendingOrder: null);

      final r = await _service.checkout(token, trade);
      if (r.paid) {
        await _onPaid(fulfilled: true);
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

  /// 顶部「未完成订单」横幅上的「去支付」：直接对那一笔续付。
  Future<void> resumePendingOrder() async {
    final rec = state.pendingOrder;
    final token = await _token();
    if (rec == null || token == null) return;
    state = state.copyWith(stage: PurchaseStage.working, error: null);
    try {
      final st = await _service.checkStatus(token, rec.tradeNo);
      if (st == OrderStatus.fulfilled) {
        state = state.copyWith(stage: PurchaseStage.browsing, pendingOrder: null);
        _persist(null);
        unawaited(_refreshSubscription());
        return;
      }
      if (st == OrderStatus.activating) {
        _persist(rec.tradeNo);
        state = state.copyWith(tradeNo: rec.tradeNo);
        await _onPaid(fulfilled: false);
        return;
      }
      if (st == OrderStatus.cancelled) {
        state = state.copyWith(stage: PurchaseStage.browsing, pendingOrder: null, error: '那笔订单已取消，可以重新下单');
        _persist(null);
        return;
      }
      _persist(rec.tradeNo);
      OrderQuote? quote;
      try {
        quote = await _service.orderDetail(token, rec.tradeNo);
      } catch (_) {}
      final r = await _service.checkout(token, rec.tradeNo);
      if (r.paid) {
        await _onPaid(fulfilled: true);
        return;
      }
      final opened = await UriUtils.tryLaunch(Uri.parse(r.payUrl!));
      state = state.copyWith(
        stage: PurchaseStage.awaitingPayment,
        tradeNo: rec.tradeNo,
        quote: quote,
        pendingOrder: null,
        error: opened ? null : '没能打开支付页面，点「重新打开支付」再试',
      );
    } on PurchaseException catch (e) {
      state = state.copyWith(stage: PurchaseStage.browsing, error: e.message);
    } catch (_) {
      state = state.copyWith(stage: PurchaseStage.browsing, error: '打开支付页面失败，请重试');
    }
  }

  /// 顶部横幅上的「取消这笔」：明确的用户动作，只取消这一笔并核验状态。
  Future<void> cancelPendingOrder() async {
    final rec = state.pendingOrder;
    final token = await _token();
    if (rec == null || token == null) return;
    final st = await _service.checkStatus(token, rec.tradeNo);
    if (st == OrderStatus.pending) {
      await _service.cancelOrder(token, rec.tradeNo);
    }
    _persist(null);
    state = state.copyWith(pendingOrder: null, error: null);
    unawaited(_refreshPendingOrder());
  }

  /// 重新打开收银台（同一笔订单）。先查状态，避免对已付订单重复结账。
  Future<void> reopenPayment() async {
    final token = await _token();
    final trade = state.tradeNo;
    if (token == null || trade == null) return;
    try {
      final st = await _service.checkStatus(token, trade);
      if (st == OrderStatus.fulfilled) {
        await _onPaid(fulfilled: true);
        return;
      }
      if (st == OrderStatus.activating) {
        await _onPaid(fulfilled: false);
        return;
      }
      if (st == OrderStatus.cancelled) {
        _persist(null);
        state = state.copyWith(stage: PurchaseStage.browsing, tradeNo: null, error: '订单已取消，请重新下单');
        return;
      }
      final r = await _service.checkout(token, trade);
      if (r.paid) {
        await _onPaid(fulfilled: true);
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
      final st = await _service.checkStatus(token, trade);
      switch (st) {
        case OrderStatus.fulfilled:
          await _onPaid(fulfilled: true);
        case OrderStatus.activating:
          await _onPaid(fulfilled: false);
        case OrderStatus.cancelled:
          _persist(null);
          state = state.copyWith(stage: PurchaseStage.browsing, tradeNo: null, error: '这笔订单已取消，请重新下单');
        case OrderStatus.pending:
        case OrderStatus.unknown:
          state = state.copyWith(
            stage: PurchaseStage.awaitingPayment,
            error: '还没查到支付。如果你已经付款，请稍等十几秒再点「我已完成支付」',
          );
      }
    } catch (_) {
      state = state.copyWith(stage: PurchaseStage.awaitingPayment, error: '查询失败，请重试');
    }
  }

  /// 成功页「再查一次」：从「开通中」升级到「已开通」。
  Future<void> recheckFulfillment() async {
    final token = await _token();
    final trade = _readPersisted();
    if (token == null || trade == null) return;
    try {
      final st = await _service.checkStatus(token, trade);
      if (st == OrderStatus.fulfilled) {
        _persist(null);
        state = state.copyWith(fulfilled: true);
        await retryRefresh();
      }
    } catch (_) {}
  }

  /// 用户明确放弃这笔订单。
  Future<void> abandonOrder() async {
    final token = await _token();
    final trade = state.tradeNo;
    if (token != null && trade != null) {
      final st = await _service.checkStatus(token, trade);
      if (st == OrderStatus.pending) {
        await _service.cancelOrder(token, trade);
      }
    }
    _persist(null);
    state = state.copyWith(stage: PurchaseStage.browsing, error: null, tradeNo: null, quote: null);
    unawaited(_refreshPendingOrder());
  }

  Future<void> _onPaid({required bool fulfilled}) async {
    _persist(fulfilled ? null : state.tradeNo);
    state = state.copyWith(
      stage: PurchaseStage.success,
      error: null,
      tradeNo: fulfilled ? null : state.tradeNo,
      pendingOrder: null,
      fulfilled: fulfilled,
      refreshing: true,
    );
    final ok = await _refreshSubscription();
    state = state.copyWith(refreshing: false, refreshFailed: !ok);
  }

  Future<void> retryRefresh() async {
    state = state.copyWith(refreshing: true, refreshFailed: false);
    final ok = await _refreshSubscription();
    state = state.copyWith(refreshing: false, refreshFailed: !ok);
  }

  /// 拿到订阅 URL 只是一半 —— 节点 / 权益真同步过来（profile 更新成功）才算成功，
  /// 之前这里 catch(_) 吞掉了 profile 更新失败，会误报「已刷新」。
  Future<bool> _refreshSubscription() async {
    try {
      final url = await ref.read(panelAuthProvider.notifier).refreshSubscribeUrl();
      if (url == null) return false;
      final profile = await ref.read(activeProfileProvider.future);
      if (profile is RemoteProfileEntity) {
        await ref.read(updateProfileNotifierProvider(profile.id).notifier).updateProfile(profile);
      }
      return true;
    } catch (_) {
      return false;
    }
  }
}

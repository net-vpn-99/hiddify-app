import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/theme/oneray_tokens.dart';
import 'package:hiddify/features/panel_auth/data/panel_api.dart';
import 'package:hiddify/features/panel_auth/notifier/guest_bootstrap.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hiddify/features/purchase/data/purchase_service.dart';
import 'package:hiddify/features/purchase/model/plan_offer.dart';
import 'package:hiddify/features/purchase/notifier/purchase_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 推荐档（精品版）放第一张。
List<ShopTier> _orderedTiers(List<ShopTier> tiers) {
  final out = [...tiers];
  out.sort((a, b) => (b.recommended ? 1 : 0) - (a.recommended ? 1 : 0));
  return out;
}

/// 「比标准版每天多 ¥X」：按当前选中的时长算，两档没有同一个时长就不写。
String? _proPerDayMore(PurchaseState state) {
  final period = state.selected?.period;
  if (period == null) return null;
  ShopTier? pro;
  ShopTier? std;
  for (final t in state.tiers) {
    if (t.tier == 'pro') pro = t;
    if (t.tier == 'std') std = t;
  }
  if (pro == null || std == null) return null;
  PlanOffer? p;
  PlanOffer? s;
  for (final o in state.plans) {
    if (o.period != period) continue;
    if (o.planId == pro.planId) p = o;
    if (o.planId == std.planId) s = o;
  }
  if (p == null || s == null || p.periodDays <= 0 || p.periodDays != s.periodDays) return null;
  final diff = p.priceCents - s.priceCents;
  if (diff <= 0) return null;
  return '比标准版每天多 ¥${(diff / 100 / p.periodDays).toStringAsFixed(1)}';
}

String tierNameOf(PurchaseState state, PlanOffer offer) {
  for (final tier in state.tiers) {
    if (tier.planId == offer.planId && tier.name.isNotEmpty) return tier.name;
  }
  return offer.name;
}

/// 续费 / 升级页。版式见 VPN 仓库 docs/充值续费/purchase-design-handoff-v1（android 参考）：
/// 返回导航 → 账户 + 剩余流量卡 → 单列时长卡片 → 共享权益 + 折叠说明 → 底部固定购买区。
class PurchasePage extends ConsumerStatefulWidget {
  const PurchasePage({super.key});

  @override
  ConsumerState<PurchasePage> createState() => _PurchasePageState();
}

class _PurchasePageState extends ConsumerState<PurchasePage> with WidgetsBindingObserver {
  bool _rulesOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    if (lifecycle == AppLifecycleState.resumed) {
      ref.read(purchaseNotifierProvider.notifier).checkPayment();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = OneRayTokens.of(context);
    final state = ref.watch(purchaseNotifierProvider);
    // 标题看人说话：只有买过套餐的老会员才叫「续费 / 升级」。游客和第一次来的人是
    // 头一回开通，顶着「续费」两个字会让他以为自己已经买过了。
    final auth = ref.watch(panelAuthProvider);
    final acc = ref.watch(purchaseAccountProvider).asData?.value ?? auth.account;
    final renewing = auth.loggedIn && !auth.isGuest && (acc?.planName?.trim().isNotEmpty ?? false);
    return Scaffold(
      backgroundColor: t.bg,
      appBar: AppBar(
        backgroundColor: t.bg,
        surfaceTintColor: Colors.transparent,
        foregroundColor: t.text,
        elevation: 0,
        title: Text(renewing ? '续费 / 升级' : '选择套餐'),
      ),
      body: switch (state.stage) {
        PurchaseStage.working => Center(child: CircularProgressIndicator(color: t.acc)),
        PurchaseStage.awaitingPayment => _awaitingPayment(t, state),
        PurchaseStage.success => _success(t, state),
        PurchaseStage.browsing => _browsing(t, state),
      },
    );
  }

  // ---------------------------------------------------------------- 选套餐

  Widget _browsing(OneRayTokens t, PurchaseState state) {
    if (state.plansLoading) {
      return Center(child: CircularProgressIndicator(color: t.acc));
    }
    if (state.plansError != null) {
      return _centered(
        t,
        state.plansError!,
        action: ('重试', () => ref.read(purchaseNotifierProvider.notifier).loadPlans()),
      );
    }

    // 按套餐类型分组
    final byPlan = <int, List<PlanOffer>>{};
    for (final o in state.plans) {
      byPlan.putIfAbsent(o.planId, () => []).add(o);
    }
    final multiPlan = byPlan.length > 1;
    final selected = state.selected;
    final acctAsync = ref.watch(purchaseAccountProvider);
    final account = acctAsync.asData?.value;
    final auth = ref.watch(panelAuthProvider);
    final boot = ref.watch(guestBootstrapProvider);
    final knownMask = !auth.loggedIn ? boot.knownAccountMask : null;

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
            children: [
              // 已注册登录、流量不限的人：账号和套餐压成一行（两端一样，一屏放下）。
              // 游客、没登录、有流量上限的，还用原来的卡片（要说清买给谁、剩多少）。
              if (auth.loggedIn && !auth.isGuest && knownMask == null
                  && quotaStateOf(account) != QuotaState.empty && quotaRatioOf(account) == null)
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(auth.accountLabel, style: TextStyle(color: t.sub, fontSize: 12)),
                    _Pill(
                      t: t,
                      text: _accountLine(account, state.me),
                      tone: _accountLine(account, state.me) == '还没有套餐' ? 'muted' : 'ok',
                    ),
                  ],
                )
              else
                _AccountCard(
                  t: t,
                  account: account,
                  loading: acctAsync.isLoading,
                  isGuest: auth.isGuest,
                  loggedIn: auth.loggedIn,
                  label: auth.accountLabel,
                  knownAccountMask: knownMask,
                  onLogin: () => context.pushNamed('login'),
                ),
              const SizedBox(height: 18),
              if (state.pendingOrder != null) ...[
                _PendingOrderBanner(
                  t: t,
                  order: state.pendingOrder!,
                  onPay: () => ref.read(purchaseNotifierProvider.notifier).resumePendingOrder(),
                  onCancel: () => _confirmCancelPending(t),
                ),
                const SizedBox(height: 12),
              ],
              if (state.error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(state.error!, style: TextStyle(color: t.fault, fontSize: 12)),
                ),
              if (state.tiers.length >= 2) ...[
                Text('选择版本', style: TextStyle(color: t.text, fontSize: 14, fontWeight: FontWeight.w600)),
                // GslShop 1.10.0 起每档带 compare：画对比表，精品版在左，点一列选那一档。
                if (state.tiers.every((t) => t.compare.isNotEmpty))
                  Padding(
                    padding: const EdgeInsets.only(top: 10, bottom: 4),
                    child: TierCompareTable(
                      t: t,
                      tiers: _orderedTiers(state.tiers),
                      selectedPlanId: selected?.planId,
                      me: state.me,
                      badge: byPlan.values.expand((x) => x).map((o) => o.badge).firstWhere((b) => b != null && b.isNotEmpty, orElse: () => null),
                      monthPrice: {
                        for (final o in state.plans)
                          if (o.periodDays == 30) o.planId: o.priceLabel.replaceAll(RegExp(r'\.00$'), ''),
                      },
                      onTap: (tier) => ref.read(purchaseNotifierProvider.notifier).selectTier(tier),
                    ),
                  )
                else
                // 老插件没有 compare：两张卡片上下排，精品版（推荐档）在上。
                for (final tier in _orderedTiers(state.tiers))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _TierCard(
                      t: t,
                      tier: tier,
                      picked: selected?.planId == tier.planId,
                      current: state.me?.tier == tier.tier,
                      blocked: tier.full && state.me?.tier != 'pro',
                      me: state.me,
                      moreLine: tier.tier == 'pro' ? _proPerDayMore(state) : null,
                      onTap: () => ref.read(purchaseNotifierProvider.notifier).selectTier(tier),
                    ),
                  ),
                if (state.stdHint)
                  Container(
                    margin: const EdgeInsets.only(top: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(color: t.accSoft, borderRadius: BorderRadius.circular(10)),
                    child: Text(
                      '你是精品版会员，精品版已经包含全部标准线路，标准线路照常满速用。精品版到期后（${state.me?.expiresOn ?? ''} 之后）可以购买标准版。',
                      style: TextStyle(color: t.text, fontSize: 12),
                    ),
                  ),
              ],
              SizedBox(height: state.tiers.length >= 2 ? 22 : 4),
              // 「选择时长」右边放「流量与购买说明」开关（跟 Windows 一样，不单独占一行）。
              Row(children: [
                Text('选择时长', style: TextStyle(color: t.text, fontSize: 14, fontWeight: FontWeight.w600)),
                const Spacer(),
                InkWell(
                  onTap: () => setState(() => _rulesOpen = !_rulesOpen),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(_rulesOpen ? '流量与购买说明  ˄' : '流量与购买说明  ›',
                        style: TextStyle(color: t.accHover, fontSize: 12)),
                  ),
                ),
              ]),
              for (final entry in byPlan.entries) ...[
                if (state.tiers.length >= 2 && selected != null && entry.key != selected.planId)
                  const SizedBox.shrink()
                else ...[
                  if (multiPlan && state.tiers.length < 2)
                    Padding(
                      padding: const EdgeInsets.only(top: 10, bottom: 6),
                      child: Text(entry.value.first.name,
                          style: TextStyle(color: t.text, fontSize: 18, fontWeight: FontWeight.w700)),
                    ),
                  // 两列，卡片矮一点，标准版 4 档也一屏放下（Win 是一行 4 张）。
                  Padding(
                    padding: const EdgeInsets.only(top: 8, bottom: 4),
                    child: LayoutBuilder(
                      builder: (context, box) {
                        final w = (box.maxWidth - 10) / 2;
                        return Wrap(
                          spacing: 10,
                          runSpacing: 12,
                          children: [
                            for (final o in entry.value)
                              SizedBox(
                                width: w,
                                child: OfferCard(
                                  t: t,
                                  offer: o,
                                  selected: selected != null && selected.planId == o.planId && selected.period == o.period,
                                  onTap: () => ref.read(purchaseNotifierProvider.notifier).select(o),
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ],
              const SizedBox(height: 8),
              _benefits(t, selected),
              _rules(t, selected),
            ],
          ),
        ),
        CheckoutBar(
          t: t,
          offer: selected,
          onPay: knownMask != null
              ? () => context.pushNamed('login')
              : (selected == null ? null : () => _confirm(t, selected)),
          payLabel: _payLabel(knownMask, selected, state.me),
          pickedName: selected == null ? '' : tierNameOf(state, selected),
          pickedNote: _pickedNote(state, selected),
          expiryHint: _expiryHint(account, selected, state.me),
        ),
      ],
    );
  }

  /// 账号状态小标签：「● 精品版 · 还能用 10 天（10-16 到期）」。没套餐写「还没有套餐」。
  static String _accountLine(PanelAccount? acc, ShopMe? me) {
    final plan = (me != null && me.planName.isNotEmpty) ? me.planName : (acc?.planName ?? '');
    if (plan.isEmpty) return '还没有套餐';
    if (me != null && me.planName.isNotEmpty) {
      final on = me.expiresOn.length >= 10 ? me.expiresOn.substring(5) : me.expiresOn;
      return on.isEmpty ? '● $plan · 还能用 ${me.daysLeft} 天' : '● $plan · 还能用 ${me.daysLeft} 天（$on 到期）';
    }
    if (acc?.lifetime == true) return '● $plan · 长期有效';
    final exp = acc?.expiredAt;
    if (exp == null) return '● $plan';
    final days = DateTime.fromMillisecondsSinceEpoch(exp * 1000).difference(DateTime.now()).inDays;
    return days < 0 ? '● $plan · 已到期' : '● $plan · 还能用 $days 天';
  }

  static String _payLabel(String? knownMask, PlanOffer? offer, ShopMe? me) {
    if (knownMask != null) return '登录后购买';
    final q = offer == null ? null : me?.quoteFor(offer.planId, offer.period);
    if (q == null) return '去支付';
    final pay = '¥${(q.payFen / 100).toStringAsFixed(2)}'.replaceAll(RegExp(r'\.00$'), '');
    if (q.surplusFen <= 0) return '支付 $pay';
    final cut = '¥${(q.surplusFen / 100).toStringAsFixed(2)}'.replaceAll(RegExp(r'\.00$'), '');
    return '支付 $pay  已抵 $cut';
  }

  /// 「买完用到哪天」。有服务端报价时用报价里的到期日和抵扣；没有就按参考天数估。
  static String? _expiryHint(PanelAccount? acc, PlanOffer? offer, [ShopMe? me]) {
    final q = offer == null ? null : me?.quoteFor(offer.planId, offer.period);
    if (q != null && q.expiresOn.isNotEmpty) {
      if (q.fromToday && q.surplusFen > 0) return '买完能用到 ${q.expiresOn}（从今天算，已抵 ¥${(q.surplusFen / 100).toStringAsFixed(0)}）';
      if (q.fromToday) return '买完能用到 ${q.expiresOn}（从今天算）';
      return '买完能用到 ${q.expiresOn}（接在现在的到期日后面）';
    }
    if (offer == null) return null;
    if (offer.periodDays <= 0) return '买完长期有效';
    final now = DateTime.now();
    final cur = acc?.expiredAt;
    final renewing = cur != null && cur > 0 && cur * 1000 > now.millisecondsSinceEpoch;
    final base = renewing ? DateTime.fromMillisecondsSinceEpoch(cur * 1000) : now;
    final d = base.add(Duration(days: offer.periodDays));
    final date = '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    return renewing ? '预计用到 $date（在现有到期时间上顺延）' : '预计用到 $date';
  }

  String? _pickedNote(PurchaseState state, PlanOffer? offer) {
    if (offer == null) return null;
    final tier = state.tiers.where((x) => x.planId == offer.planId).firstOrNull;
    if (tier == null) return null;
    final me = state.me;
    if (tier.tier == 'pro' && me?.tier != 'pro') return _proPerDayMore(state);
    if (tier.tier == 'std' && me != null && (me.trial == 'locked' || me.trial == 'offer')) {
      return me.trialMinutes == 60 ? '送 1 小时精品线路体验' : '送 ${me.trialMinutes} 分钟精品线路体验';
    }
    return null;
  }

  Widget _benefits(OneRayTokens t, PlanOffer? offer) {
    final devices = offer?.deviceLimit;
    final deviceText = (devices != null && devices > 0) ? '最多 $devices 台设备同时在线' : '设备数以套餐为准';
    final s = TextStyle(color: t.sub, fontSize: 11);
    final acc = ref.watch(panelAuthProvider).account;
    final paid = acc?.paidQuota ?? 0;
    final paidMbps = acc?.paidThrottleMbps ?? 0;
    String? speedLine;
    if (paid > 0 && paidMbps > 0) {
      // 精品版：标准线路、精品线路两份额度分开算（GslNode 1.6.0），各写各的，别写成「其中」（运营 10-16）。
      final pro = ref.watch(purchaseNotifierProvider).tiers.where((x) => x.planId == offer?.planId && x.tier == 'pro' && x.dailyGb > 0);
      if (pro.isEmpty) {
        speedLine = '每天 ${formatDailyAmount(paid)} 高速，超出后限速 ${paidMbps}Mbps';
      } else {
        final p = pro.first;
        final proMbps = p.dailyMbps > 0 ? p.dailyMbps : paidMbps;
        final over = proMbps == paidMbps ? '超出后限速 ${paidMbps}Mbps' : '超出后标准线路限速 ${paidMbps}Mbps、精品线路 ${proMbps}Mbps';
        speedLine = '每天标准线路 ${formatDailyAmount(paid)}、精品线路 ${p.dailyGb} GB 高速，$over';
      }
      final own = acc?.dailyQuota ?? 0;
      if (acc?.dailyTier == 'trial' && own > 0) {
        speedLine = '$speedLine（试用是每天 ${formatDailyAmount(own)}）';
      }
    }
    // 流量和设备数连着写（跟 Windows 一样），放不下自己换行。
    final traffic = speedLine != null
        ? '所有时长都不限总流量：$speedLine'
        : (offer != null && offer.trafficLabel.isNotEmpty
            ? (offer.trafficLabel == '不限流量' ? '所有时长都不限流量' : offer.trafficLabel)
            : null);
    return Text(traffic != null ? '$traffic　·　$deviceText' : deviceText, style: s.copyWith(height: 1.45));
  }

  Widget _rules(OneRayTokens t, PlanOffer? offer) {
    final planRule = offer == null
        ? '购买后套餐权益以订单和后台规则为准。'
        : '本档 ${offer.durationLabel}：${offer.trafficLabel}。到期时间、流量是否重置以订单确认结果为准。';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_rulesOpen)
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 6),
            child: Text(
              '$planRule\n日均价按参考天数折算，仅用于比较；省额与同套餐连续月付比较。最终付款金额以订单核算为准。',
              style: TextStyle(color: t.sub, fontSize: 11, height: 1.4),
            ),
          ),
      ],
    );
  }

  /// 「允许游客直接购买」开关（GslGuest）。**不能**写成 `ref.read(...).valueOrNull ?? false`：
  /// 这个 FutureProvider 在「试用到期 → 去买」这条路上没人提前加载过，第一次点必然读到
  /// null，游客当场被推去绑定页 —— 1.1.28 定的「不绑邮箱也能买」就这么失效了。这里等它
  /// 一次；拿不到就放行，让服务端去拦（服务端本来就会拦，错误文案还更准）。
  Future<bool> _canGuestBuy() async {
    try {
      return (await ref.read(guestOptionsProvider.future)).canBuy;
    } catch (_) {
      return true;
    }
  }

  Future<void> _confirm(OneRayTokens t, PlanOffer offer) async {
    // 1.1.28 起游客默认不用先绑邮箱就能买（GslGuest 1.1.0 的「允许游客直接购买」）。
    // 后台把那个开关关掉时服务端仍会拦下单，所以这里也跟着先跳绑定页 —— 不然用户
    // 填完支付信息才被服务端退回来。
    final canBuy = await _canGuestBuy();
    if (!mounted) return;
    if (!canBuy && ref.read(panelAuthProvider).isGuest) {
      final bound = await context.pushNamed<bool>('bindEmail');
      if (bound != true || !mounted) return;
    }
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: t.card,
        title: const Text('确认购买'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${offer.name} · ${offer.durationLabel}', style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text('${offer.trafficLabel} · ${offer.priceLabel}'),
            const SizedBox(height: 12),
            const Text('点「去支付」会打开收银台，付完回到 App，自动确认套餐状态。'
                '\n实际应付以订单核算为准（续费 / 升级可能有抵扣）。', style: TextStyle(fontSize: 12)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('去支付'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(purchaseNotifierProvider.notifier).startPurchase(offer);
    }
  }

  Future<void> _confirmCancelPending(OneRayTokens t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: t.card,
        content: const Text('取消这笔未完成的订单？如果你已经付款，请不要取消，改点「去支付」查状态。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('再想想')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('取消订单')),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(purchaseNotifierProvider.notifier).cancelPendingOrder();
    }
  }

  // ---------------------------------------------------------------- 其它阶段

  Widget _awaitingPayment(OneRayTokens t, PurchaseState state) {
    final notifier = ref.read(purchaseNotifierProvider.notifier);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.open_in_new_rounded, size: 48, color: t.sub),
            const SizedBox(height: 16),
            Text('已打开收银台', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: t.text)),
            const SizedBox(height: 8),
            Text('在收银台完成付款，然后回到这里点下面的按钮。',
                textAlign: TextAlign.center, style: TextStyle(color: t.sub)),
            if (state.quote != null) ...[
              const SizedBox(height: 10),
              Text('应付 ${state.quote!.payableLabel}',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: t.text)),
              if (state.quote!.note.isNotEmpty)
                Text(state.quote!.note, style: TextStyle(fontSize: 11, color: t.sub)),
            ],
            if (state.error != null) ...[
              const SizedBox(height: 12),
              Text(state.error!, textAlign: TextAlign.center, style: TextStyle(color: t.fault)),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: notifier.checkPayment,
              child: const Text('我已完成支付'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: notifier.reopenPayment, child: const Text('重新打开支付')),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    backgroundColor: t.card,
                    content: const Text('放弃这笔订单？如果你已经付款，请不要放弃，改点「我已完成支付」。'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('再等等')),
                      TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('放弃订单')),
                    ],
                  ),
                );
                if (ok == true) await notifier.abandonOrder();
              },
              child: const Text('遇到问题？放弃这笔订单'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _success(OneRayTokens t, PurchaseState state) {
    final fulfilled = state.fulfilled;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(fulfilled ? Icons.check_circle_rounded : Icons.hourglass_top_rounded,
                size: 56, color: fulfilled ? t.acc : t.fault),
            const SizedBox(height: 16),
            Text(fulfilled ? '购买成功，套餐已开通' : '已收到付款，套餐开通中',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: t.text)),
            const SizedBox(height: 12),
            if (!fulfilled) ...[
              Text('后台正在开通权益，通常一两分钟内完成。',
                  textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: t.sub)),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () => ref.read(purchaseNotifierProvider.notifier).recheckFulfillment(),
                child: const Text('再查一次'),
              ),
              const SizedBox(height: 12),
            ],
            if (state.refreshing)
              Text('正在刷新订阅信息…', style: TextStyle(fontSize: 13, color: t.sub))
            else if (state.refreshFailed) ...[
              Text(
                '订阅用量 / 到期时间还没刷新过来。回首页下拉刷新即可，不影响已开通的套餐。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: t.sub),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () => ref.read(purchaseNotifierProvider.notifier).retryRefresh(),
                child: const Text('重新刷新'),
              ),
            ],
            // 游客买完：这时候才劝他留邮箱。不拦着用 —— 套餐已经生效了，这里只说清代价。
            // 没有邮箱的号只认这台手机的设备号，换手机 / 恢复出厂就找不回来了，电脑上
            // 也享受不到这个套餐（那是另一台设备 = 另一个游客号）。
            if (ref.watch(panelAuthProvider).isGuest) ...[
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: t.card,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: t.fault.withValues(alpha: .5)),
                ),
                child: Column(
                  children: [
                    Text('加个邮箱，防丢',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: t.text)),
                    const SizedBox(height: 8),
                    Text('手机丢了或重装也能找回这个套餐', style: TextStyle(fontSize: 13, color: t.sub)),
                    const SizedBox(height: 10),
                    FilledButton(
                      onPressed: () => context.pushNamed('bindEmail'),
                      child: const Text('加邮箱'),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 24),
            // 游客这一屏的主按钮是「绑定邮箱」，「完成」退成次要的，别抢。
            if (ref.watch(panelAuthProvider).isGuest)
              TextButton(
                onPressed: () => context.canPop() ? context.pop() : context.goNamed('home'),
                child: const Text('以后再说'),
              )
            else
              FilledButton(
                onPressed: () => context.canPop() ? context.pop() : context.goNamed('home'),
                child: const Text('完成'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _centered(OneRayTokens t, String text, {(String, VoidCallback)? action}) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text, style: TextStyle(color: t.sub)),
          if (action != null) ...[
            const SizedBox(height: 12),
            OutlinedButton(onPressed: action.$2, child: Text(action.$1)),
          ],
        ],
      ),
    );
  }
}

// ================================================================= 子部件

class _AccountCard extends StatelessWidget {
  const _AccountCard({
    required this.t,
    required this.account,
    required this.loading,
    required this.isGuest,
    required this.loggedIn,
    required this.label,
    required this.knownAccountMask,
    required this.onLogin,
  });

  final OneRayTokens t;
  final PanelAccount? account;
  final bool loading;
  final bool isGuest;
  final bool loggedIn;
  final String label;
  final String? knownAccountMask;
  final VoidCallback onLogin;

  @override
  Widget build(BuildContext context) {
    final state = quotaStateOf(account);
    final ratio = quotaRatioOf(account);
    final a = account;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: t.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: t.ring),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 「这单记在谁头上」。原来这张卡只写「当前套餐 / 剩余流量」，游客和已登录用户看到的
          // 一模一样 —— 用户的原话是「我不太清楚我是给谁在购买」。买订阅跟买实物不一样，
          // 钱是记在某个账号上的，所以身份必须摆在最上面。
          //
          // 说法分身份（1.1.40）：自己给自己续费的人看到「购买给 自己的邮箱」会愣一下 ——
          // 那是替别人付款的口气。已注册登录 → 「当前账号」；免注册的和没账号的才说
          // 「购买给」，他们真正要确认的正是这笔钱落到哪个号上。
          Row(
            children: [
              Text(
                  knownAccountMask != null
                      ? ''
                      : (loggedIn && !isGuest ? '当前账号 ' : '购买给 '),
                  style: TextStyle(color: t.sub, fontSize: 11)),
              Expanded(
                child: Text(
                  knownAccountMask != null
                      ? (knownAccountMask!.isEmpty ? '先登录你的账号' : '先登录 $knownAccountMask')
                      : (loggedIn ? label : '还没有账号（付款时自动创建）'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: t.text, fontSize: 13, fontWeight: FontWeight.bold),
                ),
              ),
              if (knownAccountMask != null || !loggedIn)
                GestureDetector(
                  onTap: onLogin,
                  child: Text(knownAccountMask != null ? '登录' : '已有账号？登录',
                      style: TextStyle(color: t.acc, fontSize: 11, fontWeight: FontWeight.w600)),
                ),
            ],
          ),
          if (isGuest) ...[
            const SizedBox(height: 2),
            Text(
              // 短、准、不吓人。「只能本机使用」那种说法会被读成「买了就锁死」，
              // 而事实是绑个邮箱就能换机 —— 两件事必须放在同一句里说完。
              '买在这个账号上，其它设备用配对码登录就能一起用',
              style: TextStyle(color: t.sub, fontSize: 11, height: 1.3),
            ),
          ],
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Divider(height: 1, color: t.ring),
          ),
          Row(
            children: [
              Text('当前套餐 ', style: TextStyle(color: t.sub, fontSize: 11)),
              Text(
                a?.planName?.isNotEmpty == true ? a!.planName! : (loading ? '读取中…' : '尚未开通'),
                style: TextStyle(color: t.text, fontSize: 13, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          if (a != null) ...[
            const SizedBox(height: 2),
            Text(
              a.lifetime ? '长期有效' : _expiryText(a.expiredAt!),
              style: TextStyle(color: t.sub, fontSize: 11),
            ),
          ],
          if (state != QuotaState.unknown) ...[
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(child: Text('剩余流量', style: TextStyle(color: t.sub, fontSize: 11))),
                Text(
                  _headline(state, a),
                  style: TextStyle(color: t.text, fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            if (ratio != null) ...[
              const SizedBox(height: 6),
              _MeterBar(t: t, ratio: ratio, state: state),
            ],
            const SizedBox(height: 6),
            if (state == QuotaState.unlimited)
              Text('${_used(a)} · 无固定流量上限', style: TextStyle(color: t.sub, fontSize: 11))
            else
              Row(
                children: [
                  Expanded(child: Text(_used(a), style: TextStyle(color: t.sub, fontSize: 11))),
                  Text(
                    state == QuotaState.empty ? '流量已用完' : '剩余 ${((ratio ?? 0) * 100).round()}%',
                    style: TextStyle(
                      color: state == QuotaState.empty ? t.fault : t.sub,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
          ] else ...[
            const SizedBox(height: 8),
            Text('开通后即可连接。选择下面任意一档完成购买。',
                style: TextStyle(color: t.sub, fontSize: 12)),
          ],
        ],
      ),
    );
  }

  String _used(PanelAccount? a) => '已用 ${formatAccountBytes(a?.used ?? 0)}';

  String _headline(QuotaState s, PanelAccount? a) {
    if (s == QuotaState.unlimited) return '不限流量';
    if (a == null) return '暂不可用';
    final left = (a.transferEnable - a.used).clamp(0, a.transferEnable);
    return '${formatAccountBytes(left)} / ${formatAccountBytes(a.transferEnable)}';
  }

  String _expiryText(int epochSeconds) {
    final left = DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000).difference(DateTime.now());
    if (left.isNegative) return '已到期';
    final days = left.inDays;
    if (days >= 1) return '还有 $days 天到期';
    return '不到 1 天到期';
  }
}

class _MeterBar extends StatelessWidget {
  const _MeterBar({required this.t, required this.ratio, required this.state});

  final OneRayTokens t;
  final double ratio;
  final QuotaState state;

  @override
  Widget build(BuildContext context) {
    final fill = switch (state) {
      QuotaState.low => t.fault,
      QuotaState.empty => t.fault,
      _ => t.acc,
    };
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Stack(
        children: [
          Container(height: 8, color: t.panel),
          FractionallySizedBox(
            widthFactor: ratio.clamp(0.0, 1.0),
            child: Container(height: 8, color: fill),
          ),
        ],
      ),
    );
  }
}

class _TierCard extends StatelessWidget {
  const _TierCard({
    required this.t,
    required this.tier,
    required this.picked,
    required this.current,
    required this.blocked,
    required this.me,
    required this.onTap,
    this.moreLine,
  });

  final OneRayTokens t;
  final ShopTier tier;
  final bool picked;
  final bool current;
  final bool blocked;
  final ShopMe? me;
  final VoidCallback onTap;

  /// 精品版卡片上的「比标准版每天多 ¥X」。
  final String? moreLine;

  @override
  Widget build(BuildContext context) {
    final tone = tier.keyTone == 'good' || tier.keyTone == 'connected' ? t.acc : t.fault;
    final stdBlocked = tier.tier == 'std' && me?.canBuyStd == false;
    final gift = me != null && tier.tier == 'std' && (me!.trial == 'locked' || me!.trial == 'offer');
    return Opacity(
      opacity: blocked || stdBlocked ? 0.55 : 1,
      child: InkWell(
        onTap: blocked ? null : onTap,
        borderRadius: BorderRadius.circular(14),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
          decoration: BoxDecoration(
            color: blocked ? t.panel : t.card,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: picked ? t.acc : (current ? t.acc : t.ring),
              width: picked || current ? 2 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (blocked)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('本月名额已满', style: TextStyle(color: t.sub, fontSize: 11)),
                ),
              Wrap(
                spacing: 6,
                crossAxisAlignment: WrapCrossAlignment.end,
                children: [
                  Text(tier.name, style: TextStyle(color: t.text, fontSize: 15, fontWeight: FontWeight.w700)),
                  Text(tier.keyLine, style: TextStyle(color: tone, fontSize: 12, fontWeight: FontWeight.w600)),
                ],
              ),
              const SizedBox(height: 4),
              // 好处列表：服务端 GslShop 1.9.0 下发 points，老插件退回 sub 一句。
              for (final p in stdBlocked
                  ? const ['精品版已包含，不用另买']
                  : (tier.points.isNotEmpty ? tier.points : [if (tier.sub.isNotEmpty) tier.sub]))
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('✓', style: TextStyle(color: t.acc, fontSize: 12, height: 1.35)),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(p, style: TextStyle(color: t.sub, fontSize: 12, height: 1.35)),
                      ),
                    ],
                  ),
                ),
              if ((moreLine != null && !current) || (tier.tier == 'pro' && tier.dailyGb > 0))
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (moreLine != null && !current)
                        Text(moreLine!,
                            style: TextStyle(color: t.acc, fontSize: 12, fontWeight: FontWeight.w700)),
                      if (tier.tier == 'pro' && tier.dailyGb > 0)
                        Text('精品线路每天 ${tier.dailyGb}GB 高速', style: TextStyle(color: t.sub, fontSize: 11)),
                    ],
                  ),
                ),
              if (gift)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    (me!.trialMinutes == 60) ? '送 1 小时精品线路体验' : '送 ${me!.trialMinutes} 分钟精品线路体验',
                    style: TextStyle(color: t.acc, fontSize: 11),
                  ),
                ),
            ],
          ),
        ),
            if (current)
              Positioned(
                top: -8,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
                    decoration: BoxDecoration(color: t.acc, borderRadius: BorderRadius.circular(8)),
                    child: Text('✓ 你现在用的', style: TextStyle(color: t.accInk, fontSize: 11)),
                  ),
                ),
              ),
            // 「推荐」角标，样式同时长卡片的角标。
            if (tier.recommended && !current && !blocked)
              Positioned(
                top: -8,
                right: 10,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(color: t.acc, borderRadius: BorderRadius.circular(8)),
                  child: Text('推荐', style: TextStyle(color: t.accInk, fontSize: 10, fontWeight: FontWeight.bold)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 10-16 运营定方案 B（参照 GoMami，两端一样）：浅灰底上一张白卡，不描边，只带很淡的阴影。
BoxDecoration _softCard(BuildContext context, OneRayTokens t) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return BoxDecoration(
    color: t.card,
    borderRadius: BorderRadius.circular(16),
    boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: dark ? 0.25 : 0.06), blurRadius: 14, offset: const Offset(0, 1))],
  );
}

/// 状态小标签（浅底、不描边）：warm 浅橙 / current 灰 / muted 灰浅字 / ok 浅绿。两端一样。
class _Pill extends StatelessWidget {
  const _Pill({required this.t, required this.text, required this.tone});

  final OneRayTokens t;
  final String text;
  final String tone;

  @override
  Widget build(BuildContext context) {
    final bg = switch (tone) { 'warm' => t.accSoft, 'ok' => t.accSoft, _ => t.panel };
    final fg = switch (tone) {
      'warm' => t.accHover,
      'ok' => t.acc,
      'current' => t.sub,
      _ => t.sub.withValues(alpha: 0.8),
    };
    // 不设 alignment：设了会把小标签撑满整行。
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
      child: Text(text, style: TextStyle(color: fg, fontSize: 11, fontWeight: FontWeight.w500, height: 1.1)),
    );
  }
}

/// 版本单选：没选是空心圈（看得出能点），选中是主色实心圆 + 白勾。
class _PickRadio extends StatelessWidget {
  const _PickRadio({required this.t, required this.checked});

  final OneRayTokens t;
  final bool checked;

  @override
  Widget build(BuildContext context) => Container(
        width: 18,
        height: 18,
        decoration: BoxDecoration(
          color: checked ? t.acc : t.card,
          shape: BoxShape.circle,
          border: checked ? null : Border.all(color: t.ring, width: 1.5),
        ),
        child: checked ? Icon(Icons.check_rounded, size: 13, color: t.accInk) : null,
      );
}

/// 版本对比表：一张白卡，左边项目名，右边每档一列；选中那一列整列铺浅橙 + 右上角圆勾，
/// 没选的放空心圆圈。不描边、不画格子框，只有很淡的行线。点哪一格都选那一档。
class TierCompareTable extends StatelessWidget {
  const TierCompareTable({
    required this.t,
    required this.tiers,
    required this.selectedPlanId,
    required this.me,
    required this.onTap,
    this.badge,
    this.monthPrice = const {},
  });

  final OneRayTokens t;
  final List<ShopTier> tiers;
  /// 推荐角标的字，跟时长卡片的角标同一句；没有就写「推荐」。
  final String? badge;
  final int? selectedPlanId;
  final ShopMe? me;
  final ValueChanged<ShopTier> onTap;
  /// 每档「¥49」（30 天那一项的价格），写在版本名下面，选版本时就看得到差价。没有就不写。
  final Map<int, String> monthPrice;

  bool _seatBlocked(ShopTier tier) => tier.full && me?.tier != 'pro';
  bool _stdBlocked(ShopTier tier) => tier.tier == 'std' && me?.canBuyStd == false;
  bool _picked(ShopTier tier) => !_stdBlocked(tier) && selectedPlanId == tier.planId;
  bool _dim(ShopTier tier) => _stdBlocked(tier) || _seatBlocked(tier);

  /// 每档最多一个状态小标签（两端一样）。
  /// 精品版：当前 → 本月名额已满 → 推荐；标准版：当前 → 精品版已包含 → 送精品线路体验。
  /// 不写「剩 N 个名额」（运营 10-16：不打算限制购买人数）。
  (String, String)? _badge(ShopTier tier) {
    if (me?.tier == tier.tier) return ('当前', 'current');
    if (_stdBlocked(tier)) return ('精品版已包含', 'muted');
    if (_seatBlocked(tier)) return ('本月名额已满', 'muted');
    if (tier.tier == 'std' && me != null && (me!.trial == 'locked' || me!.trial == 'offer')) {
      return (me!.trialMinutes == 60 ? '送 1 小时精品线路体验' : '送 ${me!.trialMinutes} 分钟精品线路体验', 'warm');
    }
    // 只写「推荐」，跟时长卡的「推荐选择」区分开。
    if (tier.recommended) return ('推荐', 'warm');
    return null;
  }

  /// 「适合」写在版本名下面（一眼知道这档给谁用），不再占表里一行。两端一样。
  static bool _isTagline(CompareCell c) => c.label == '适合';
  String _tagline(ShopTier tier) =>
      tier.compare.firstWhere(_isTagline, orElse: () => const CompareCell(label: '', value: '', good: false)).value;

  @override
  Widget build(BuildContext context) {
    final allRows = tiers.map((x) => x.compare.length).fold(0, (a, b) => a > b ? a : b);
    final rowIdx = [
      for (var r = 0; r < allRows; r++)
        if (!(r < tiers.first.compare.length && _isTagline(tiers.first.compare[r]))) r,
    ];
    const pad = 4.0;

    return Container(
      decoration: _softCard(context, t),
      padding: const EdgeInsets.all(pad),
      child: LayoutBuilder(builder: (context, box) {
        final labelW = (box.maxWidth * 0.19).clamp(62.0, 124.0);
        final colW = (box.maxWidth - labelW) / tiers.length;
        double colX(int i) => labelW + i * colW;

        Widget tap(ShopTier tier, Widget child) => GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _seatBlocked(tier) ? null : () => onTap(tier),
              child: child,
            );

        final head = TableRow(children: [
          const SizedBox.shrink(),
          for (final tier in tiers)
            tap(
              tier,
              Stack(children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 12, 28, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(tier.name,
                          style: TextStyle(color: _dim(tier) ? t.sub : t.text, fontSize: 16, fontWeight: FontWeight.w600)),
                      if (_badge(tier) case final b?) ...[
                        const SizedBox(height: 4),
                        _Pill(t: t, text: b.$1, tone: b.$2),
                      ],
                      if (_tagline(tier).isNotEmpty) ...[
                        const SizedBox(height: 5),
                        Text(_tagline(tier), style: TextStyle(color: t.sub, fontSize: 12, height: 1.3)),
                      ],
                      if (monthPrice[tier.planId] case final p?) ...[
                        const SizedBox(height: 4),
                        Text.rich(TextSpan(children: [
                          TextSpan(text: p, style: TextStyle(color: _dim(tier) ? t.sub : t.text, fontSize: 17, fontWeight: FontWeight.w600)),
                          TextSpan(text: ' /月', style: TextStyle(color: t.sub, fontSize: 12)),
                        ])),
                      ],
                    ],
                  ),
                ),
                if (!_dim(tier)) Positioned(right: 8, top: 12, child: _PickRadio(t: t, checked: _picked(tier))),
              ]),
            ),
        ]);

        Widget rule(Widget child) => DecoratedBox(
              decoration: BoxDecoration(border: Border(top: BorderSide(color: t.ring.withValues(alpha: 0.22)))),
              child: child,
            );

        final body = <TableRow>[
          for (final r in rowIdx)
            TableRow(children: [
              rule(Padding(
                padding: EdgeInsets.fromLTRB(8, 8, 4, r == rowIdx.last ? 10 : 8),
                child: Text(
                  tiers.map((x) => r < x.compare.length ? x.compare[r].label : '').firstWhere((s) => s.isNotEmpty, orElse: () => ''),
                  style: TextStyle(color: t.sub.withValues(alpha: 0.85), fontSize: 11.5),
                ),
              )),
              for (final tier in tiers)
                tap(
                  tier,
                  rule(Padding(
                    padding: EdgeInsets.fromLTRB(10, 8, 6, r == rowIdx.last ? 10 : 8),
                    child: Text(
                      r < tier.compare.length ? tier.compare[r].value : '',
                      style: TextStyle(color: _dim(tier) ? t.sub : t.text, fontSize: 13),
                    ),
                  )),
                ),
            ]),
        ];

        return Stack(children: [
          // 选中那一列的浅橙底（整列）。
          for (var i = 0; i < tiers.length; i++)
            if (_picked(tiers[i]))
              Positioned(
                left: colX(i),
                top: 0,
                bottom: 0,
                width: colW,
                child: DecoratedBox(
                  decoration: BoxDecoration(color: t.accSoft.withValues(alpha: 0.8), borderRadius: BorderRadius.circular(12)),
                ),
              ),
          Table(
            columnWidths: {
              0: FixedColumnWidth(labelW),
              for (var i = 0; i < tiers.length; i++) i + 1: FixedColumnWidth(colW),
            },
            defaultVerticalAlignment: TableCellVerticalAlignment.intrinsicHeight,
            children: [head, ...body],
          ),
        ]);
      }),
    );
  }
}

class OfferCard extends StatelessWidget {
  const OfferCard({required this.t, required this.offer, required this.selected, required this.onTap});

  final OneRayTokens t;
  final PlanOffer offer;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final priceLabel = offer.priceLabel.replaceAll(RegExp(r'\.00$'), '');
    // 白卡；选中 = 主色细边 + 价格变主色。「推荐」小标签放卡片里右上（跟 Windows 一样）。
    return Container(
      decoration: _softCard(context, t),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            height: 72,
            padding: const EdgeInsets.fromLTRB(14, 0, 10, 0),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: selected ? Border.all(color: t.acc, width: 1.5) : null,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Text(offer.durationLabel, style: TextStyle(color: t.sub, fontSize: 12)),
                  const Spacer(),
                  if (offer.badge != null) _Pill(t: t, text: offer.badge!, tone: 'warm'),
                ]),
                const SizedBox(height: 2),
                Text(priceLabel,
                    style: TextStyle(color: selected ? t.accHover : t.text, fontSize: 21, fontWeight: FontWeight.w600, height: 1.15)),
                if (offer.dailyLabel != null)
                  Text('约 ${offer.dailyLabel}', maxLines: 1, style: TextStyle(color: t.sub, fontSize: 11)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class CheckoutBar extends StatelessWidget {
  const CheckoutBar({
    required this.t,
    required this.offer,
    required this.onPay,
    required this.payLabel,
    required this.pickedName,
    required this.expiryHint,
    this.pickedNote,
  });

  /// 跟在「已选」后面的一句：精品版比标准版每天多多少 / 标准版送的精品线路体验（原来在版本卡片头里，10-16 挪过来）。
  final String? pickedNote;

  final OneRayTokens t;
  final PlanOffer? offer;
  final VoidCallback? onPay;
  final String payLabel;
  final String pickedName;

  /// 「买完用到哪天」。付钱之前最想知道的一件事，原来这页从头到尾没写过，
  /// 用户得自己拿当前到期时间加上档位天数去算。
  final String? expiryHint;

  @override
  Widget build(BuildContext context) {
    final priceLabel = (offer?.priceLabel ?? '').replaceAll(RegExp(r'\.00$'), '');
    return Material(
      color: t.card,
      shape: Border(top: BorderSide(color: t.ring.withValues(alpha: 0.6))),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          // 一行：左边「已选 / 买完能用到」两行小字，右边付款按钮（金额写在按钮上）。两端一样。
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      offer != null ? '$pickedName · ${offer!.durationLabel}' : '请选择一档',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: t.text, fontSize: 14, fontWeight: FontWeight.w500),
                    ),
                    // 手机上一行放不下，单独一行（Windows 宽，跟在「已选」后面）。
                    if (offer != null && pickedNote != null) ...[
                      const SizedBox(height: 2),
                      Text(pickedNote!, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: t.text, fontSize: 11, fontWeight: FontWeight.w500)),
                    ],
                    if (expiryHint != null) ...[
                      const SizedBox(height: 2),
                      Text(expiryHint!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: t.sub, fontSize: 11)),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              FilledButton(
                // 颜色、胶囊形状都跟全局主题走（B 夜航主按钮）；这里只定尺寸和不可点时的底色。
                style: FilledButton.styleFrom(disabledBackgroundColor: t.panel, minimumSize: const Size(132, 44)),
                onPressed: onPay,
                child: Text(
                  payLabel == '去支付' && priceLabel.isNotEmpty ? '支付 $priceLabel' : payLabel,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 顶部「你有一笔未完成的订单」横幅 —— Xboard 有未完成订单时不让下新单，
/// 必须先处理这一笔（去支付 / 取消）。
class _PendingOrderBanner extends StatelessWidget {
  const _PendingOrderBanner({
    required this.t,
    required this.order,
    required this.onPay,
    required this.onCancel,
  });

  final OneRayTokens t;
  final RecoverableOrder order;
  final VoidCallback onPay;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final activating = order.status == OrderStatus.activating;
    final desc = [
      if (order.planName != null && order.planName!.isNotEmpty) order.planName!,
      if (order.amountLabel.isNotEmpty) order.amountLabel,
    ].join(' · ');
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: t.accSoft,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: t.acc),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(activating ? '你有一笔订单正在开通中' : '你有一笔未完成的订单',
              style: TextStyle(color: t.text, fontSize: 13, fontWeight: FontWeight.bold)),
          if (desc.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(desc, style: TextStyle(color: t.sub, fontSize: 12)),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              FilledButton(
                style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
                onPressed: onPay,
                child: Text(activating ? '查看状态' : '去支付'),
              ),
              const SizedBox(width: 8),
              TextButton(onPressed: onCancel, child: const Text('取消这笔')),
            ],
          ),
        ],
      ),
    );
  }
}

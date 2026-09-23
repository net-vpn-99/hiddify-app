import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/features/panel_auth/data/panel_api.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hiddify/features/panel_auth/widget/account_benefits.dart';
import 'package:hiddify/features/purchase/data/purchase_service.dart';
import 'package:hiddify/features/purchase/model/plan_offer.dart';
import 'package:hiddify/features/purchase/notifier/purchase_notifier.dart';
import 'package:hiddify/features/purchase/widget/purchase_tokens.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

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
    final t = PurchaseTokens.of(context);
    final state = ref.watch(purchaseNotifierProvider);
    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        backgroundColor: t.background,
        surfaceTintColor: Colors.transparent,
        foregroundColor: t.text,
        elevation: 0,
        title: const Text('续费 / 升级套餐'),
      ),
      body: switch (state.stage) {
        PurchaseStage.working => Center(child: CircularProgressIndicator(color: t.primary)),
        PurchaseStage.awaitingPayment => _awaitingPayment(t, state),
        PurchaseStage.success => _success(t, state),
        PurchaseStage.browsing => _browsing(t, state),
      },
    );
  }

  // ---------------------------------------------------------------- 选套餐

  Widget _browsing(PurchaseTokens t, PurchaseState state) {
    if (state.plansLoading) {
      return Center(child: CircularProgressIndicator(color: t.primary));
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

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
            children: [
              _AccountCard(
                t: t,
                account: account,
                loading: acctAsync.isLoading,
                isGuest: auth.isGuest,
                loggedIn: auth.loggedIn,
                label: auth.accountLabel,
                onLogin: () => context.pushNamed('login'),
              ),
              const SizedBox(height: 16),
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
                  child: Text(state.error!, style: TextStyle(color: t.empty, fontSize: 12)),
                ),
              Row(
                children: [
                  Expanded(
                    child: Text('选择使用时长',
                        style: TextStyle(color: t.text, fontSize: 15, fontWeight: FontWeight.bold)),
                  ),
                  Text('以下价格均为整期金额', style: TextStyle(color: t.secondary, fontSize: 11)),
                ],
              ),
              const SizedBox(height: 10),
              for (final entry in byPlan.entries) ...[
                if (multiPlan)
                  Padding(
                    padding: const EdgeInsets.only(top: 6, bottom: 6),
                    child: Text(entry.value.first.name,
                        style: TextStyle(color: t.secondary, fontSize: 12, fontWeight: FontWeight.bold)),
                  ),
                for (final o in entry.value)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _OfferCard(
                      t: t,
                      offer: o,
                      selected: selected != null && selected.planId == o.planId && selected.period == o.period,
                      onTap: () => ref.read(purchaseNotifierProvider.notifier).select(o),
                    ),
                  ),
              ],
              const SizedBox(height: 4),
              _benefits(t, selected),
              const SizedBox(height: 6),
              _rules(t, selected),
            ],
          ),
        ),
        _CheckoutBar(
          t: t,
          offer: selected,
          onPay: selected == null ? null : () => _confirm(t, selected),
          expiryHint: _expiryHint(account, selected),
        ),
      ],
    );
  }

  /// 「买完用到哪天」。没到期的按现有到期日往后顺延，已到期 / 没套餐的从今天算。
  /// 面板实际是按自然月加的，这里拿档位的参考天数估，所以写「预计」，别写死。
  static String? _expiryHint(PanelAccount? acc, PlanOffer? offer) {
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

  Widget _benefits(PurchaseTokens t, PlanOffer? offer) {
    final devices = offer?.deviceLimit;
    final deviceText = (devices != null && devices > 0) ? '最多 $devices 台设备同时在线' : '设备数以套餐为准';
    final s = TextStyle(color: t.secondary, fontSize: 11);
    return Wrap(
      spacing: 16,
      runSpacing: 4,
      children: [
        Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.devices_rounded, size: 13, color: t.secondary),
          const SizedBox(width: 4),
          Text(deviceText, style: s),
        ]),
        Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.layers_rounded, size: 13, color: t.secondary),
          const SizedBox(width: 4),
          Text('同一账号共享流量', style: s),
        ]),
      ],
    );
  }

  Widget _rules(PurchaseTokens t, PlanOffer? offer) {
    final planRule = offer == null
        ? '购买后套餐权益以订单和后台规则为准。'
        : '本档 ${offer.durationLabel}：${offer.trafficLabel}。到期时间、流量是否重置以订单确认结果为准。';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _rulesOpen = !_rulesOpen),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Icon(_rulesOpen ? Icons.expand_more_rounded : Icons.chevron_right_rounded,
                    size: 18, color: t.secondary),
                const SizedBox(width: 2),
                Text('流量与购买说明', style: TextStyle(color: t.secondary, fontSize: 12)),
              ],
            ),
          ),
        ),
        if (_rulesOpen)
          Padding(
            padding: const EdgeInsets.only(left: 20, bottom: 6),
            child: Text(
              '$planRule\n日均价按参考天数折算，仅用于比较；省额与同套餐连续月付比较。最终付款金额以订单核算为准。',
              style: TextStyle(color: t.secondary, fontSize: 11, height: 1.4),
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

  Future<void> _confirm(PurchaseTokens t, PlanOffer offer) async {
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
        backgroundColor: t.raised,
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
            style: FilledButton.styleFrom(backgroundColor: t.primary, foregroundColor: t.onPrimary),
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

  Future<void> _confirmCancelPending(PurchaseTokens t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: t.raised,
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

  Widget _awaitingPayment(PurchaseTokens t, PurchaseState state) {
    final notifier = ref.read(purchaseNotifierProvider.notifier);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.open_in_new_rounded, size: 48, color: t.secondary),
            const SizedBox(height: 16),
            Text('已打开收银台', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: t.text)),
            const SizedBox(height: 8),
            Text('在收银台完成付款，然后回到这里点下面的按钮。',
                textAlign: TextAlign.center, style: TextStyle(color: t.secondary)),
            if (state.quote != null) ...[
              const SizedBox(height: 10),
              Text('应付 ${state.quote!.payableLabel}',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: t.text)),
              if (state.quote!.note.isNotEmpty)
                Text(state.quote!.note, style: TextStyle(fontSize: 11, color: t.secondary)),
            ],
            if (state.error != null) ...[
              const SizedBox(height: 12),
              Text(state.error!, textAlign: TextAlign.center, style: TextStyle(color: t.empty)),
            ],
            const SizedBox(height: 24),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: t.primary, foregroundColor: t.onPrimary),
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
                    backgroundColor: t.raised,
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

  Widget _success(PurchaseTokens t, PurchaseState state) {
    final fulfilled = state.fulfilled;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(fulfilled ? Icons.check_circle_rounded : Icons.hourglass_top_rounded,
                size: 56, color: fulfilled ? t.remaining : t.warning),
            const SizedBox(height: 16),
            Text(fulfilled ? '购买成功，套餐已开通' : '已收到付款，套餐开通中',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: t.text)),
            const SizedBox(height: 12),
            if (!fulfilled) ...[
              Text('后台正在开通权益，通常一两分钟内完成。',
                  textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: t.secondary)),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () => ref.read(purchaseNotifierProvider.notifier).recheckFulfillment(),
                child: const Text('再查一次'),
              ),
              const SizedBox(height: 12),
            ],
            if (state.refreshing)
              Text('正在刷新订阅信息…', style: TextStyle(fontSize: 13, color: t.secondary))
            else if (state.refreshFailed) ...[
              Text(
                '订阅用量 / 到期时间还没刷新过来。回首页下拉刷新即可，不影响已开通的套餐。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: t.secondary),
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
                  color: t.raised,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: t.warning.withValues(alpha: .5)),
                ),
                child: Column(
                  children: [
                    Text('留个邮箱，保住这个套餐',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: t.text)),
                    const SizedBox(height: 8),
                    // 跟别处同一份说法（account_benefits.dart），别再单独编一段。
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: AccountBenefitList(lead: '绑定邮箱后：'),
                    ),
                    const SizedBox(height: 10),
                    FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: t.primary, foregroundColor: t.onPrimary),
                      onPressed: () => context.pushNamed('bindEmail'),
                      child: const Text('绑定邮箱'),
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
                child: const Text('以后再说，先用着'),
              )
            else
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: t.primary, foregroundColor: t.onPrimary),
                onPressed: () => context.canPop() ? context.pop() : context.goNamed('home'),
                child: const Text('完成'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _centered(PurchaseTokens t, String text, {(String, VoidCallback)? action}) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text, style: TextStyle(color: t.secondary)),
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
    required this.onLogin,
  });

  final PurchaseTokens t;
  final PanelAccount? account;
  final bool loading;
  final bool isGuest;
  final bool loggedIn;
  final String label;
  final VoidCallback onLogin;

  @override
  Widget build(BuildContext context) {
    final state = quotaStateOf(account);
    final ratio = quotaRatioOf(account);
    final a = account;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: t.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 「这单买给谁」。原来这张卡只写「当前套餐 / 剩余流量」，游客和已登录用户看到的
          // 一模一样 —— 用户的原话是「我不太清楚我是给谁在购买」。买订阅跟买实物不一样，
          // 钱是记在某个账号上的，所以身份必须摆在最上面。
          Row(
            children: [
              Text('购买给 ', style: TextStyle(color: t.secondary, fontSize: 11)),
              Expanded(
                child: Text(
                  loggedIn ? label : '还没有账号（付款时自动创建）',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: t.text, fontSize: 13, fontWeight: FontWeight.bold),
                ),
              ),
              if (isGuest || !loggedIn)
                GestureDetector(
                  onTap: onLogin,
                  child: Text('已有账号？登录',
                      style: TextStyle(color: t.primary, fontSize: 11, fontWeight: FontWeight.w600)),
                ),
            ],
          ),
          if (isGuest) ...[
            const SizedBox(height: 2),
            Text(
              // 短、准、不吓人。「只能本机使用」那种说法会被读成「买了就锁死」，
              // 而事实是绑个邮箱就能换机 —— 两件事必须放在同一句里说完。
              '只在这台手机有效，绑邮箱后可换机',
              style: TextStyle(color: t.secondary, fontSize: 11, height: 1.3),
            ),
          ],
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Divider(height: 1, color: t.border),
          ),
          Row(
            children: [
              Text('当前套餐 ', style: TextStyle(color: t.secondary, fontSize: 11)),
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
              style: TextStyle(color: t.secondary, fontSize: 11),
            ),
          ],
          if (state != QuotaState.unknown) ...[
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(child: Text('剩余流量', style: TextStyle(color: t.secondary, fontSize: 11))),
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
              Text('${_used(a)} · 无固定流量上限', style: TextStyle(color: t.secondary, fontSize: 11))
            else
              Row(
                children: [
                  Expanded(child: Text(_used(a), style: TextStyle(color: t.secondary, fontSize: 11))),
                  Text(
                    state == QuotaState.empty ? '流量已用完' : '剩余 ${((ratio ?? 0) * 100).round()}%',
                    style: TextStyle(
                      color: state == QuotaState.empty ? t.empty : t.secondary,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
          ] else ...[
            const SizedBox(height: 8),
            Text('开通后即可连接。选择下面任意一档完成购买。',
                style: TextStyle(color: t.secondary, fontSize: 12)),
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

  final PurchaseTokens t;
  final double ratio;
  final QuotaState state;

  @override
  Widget build(BuildContext context) {
    final fill = switch (state) {
      QuotaState.low => t.warning,
      QuotaState.empty => t.empty,
      _ => t.remaining,
    };
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Stack(
        children: [
          Container(height: 8, color: t.fill),
          FractionallySizedBox(
            widthFactor: ratio.clamp(0.0, 1.0),
            child: Container(height: 8, color: fill),
          ),
        ],
      ),
    );
  }
}

class _OfferCard extends StatelessWidget {
  const _OfferCard({required this.t, required this.offer, required this.selected, required this.onTap});

  final PurchaseTokens t;
  final PlanOffer offer;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final priceLabel = offer.priceLabel.replaceAll(RegExp(r'\.00$'), '');
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(13),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? t.selected : t.surface,
          borderRadius: BorderRadius.circular(13),
          border: Border.all(color: selected ? t.primary : t.border, width: selected ? 2 : 1),
        ),
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
              size: 20,
              color: selected ? t.primary : t.secondary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(offer.durationLabel,
                          style: TextStyle(color: t.text, fontSize: 15, fontWeight: FontWeight.w600)),
                      if (offer.badge != null) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: t.primary,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(offer.badge!,
                              style: TextStyle(color: t.onPrimary, fontSize: 10, fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    offer.dailyLabel != null ? '${offer.trafficLabel} · 约 ${offer.dailyLabel}' : offer.trafficLabel,
                    style: TextStyle(color: t.secondary, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(priceLabel,
                style: TextStyle(color: t.text, fontSize: 20, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }
}

class _CheckoutBar extends StatelessWidget {
  const _CheckoutBar({
    required this.t,
    required this.offer,
    required this.onPay,
    required this.expiryHint,
  });

  final PurchaseTokens t;
  final PlanOffer? offer;
  final VoidCallback? onPay;

  /// 「买完用到哪天」。付钱之前最想知道的一件事，原来这页从头到尾没写过，
  /// 用户得自己拿当前到期时间加上档位天数去算。
  final String? expiryHint;

  @override
  Widget build(BuildContext context) {
    final priceLabel = (offer?.priceLabel ?? '').replaceAll(RegExp(r'\.00$'), '');
    return Material(
      color: t.surface,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      offer != null ? '已选 · ${offer!.name} / ${offer!.durationLabel}' : '请选择一档',
                      style: TextStyle(color: t.secondary, fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (offer != null)
                    Text(offer!.trafficLabel, style: TextStyle(color: t.secondary, fontSize: 11)),
                ],
              ),
              if (expiryHint != null) ...[
                const SizedBox(height: 2),
                Text(expiryHint!,
                    style: TextStyle(color: t.text, fontSize: 12, fontWeight: FontWeight.w600)),
              ],
              const SizedBox(height: 8),
              Row(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('本次套餐金额', style: TextStyle(color: t.secondary, fontSize: 11)),
                      Text(priceLabel.isEmpty ? '—' : priceLabel,
                          style: TextStyle(color: t.text, fontSize: 22, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const Spacer(),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: t.primary,
                      foregroundColor: t.onPrimary,
                      disabledBackgroundColor: t.fill,
                      minimumSize: const Size(150, 48),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(25)),
                    ),
                    onPressed: onPay,
                    child: const Text('去支付', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text('付款后返回，自动确认套餐状态', style: TextStyle(color: t.secondary, fontSize: 11)),
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

  final PurchaseTokens t;
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
        color: t.selected,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: t.primary),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(activating ? '你有一笔订单正在开通中' : '你有一笔未完成的订单',
              style: TextStyle(color: t.text, fontSize: 13, fontWeight: FontWeight.bold)),
          if (desc.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(desc, style: TextStyle(color: t.secondary, fontSize: 12)),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: t.primary,
                  foregroundColor: t.onPrimary,
                  visualDensity: VisualDensity.compact,
                ),
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

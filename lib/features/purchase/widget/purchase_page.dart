import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/features/purchase/model/plan_offer.dart';
import 'package:hiddify/features/purchase/notifier/purchase_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class PurchasePage extends ConsumerStatefulWidget {
  const PurchasePage({super.key});

  @override
  ConsumerState<PurchasePage> createState() => _PurchasePageState();
}

class _PurchasePageState extends ConsumerState<PurchasePage> with WidgetsBindingObserver {
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
    final state = ref.watch(purchaseNotifierProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('续费 / 升级套餐')),
      body: switch (state.stage) {
        PurchaseStage.working => const Center(child: CircularProgressIndicator()),
        PurchaseStage.awaitingPayment => _awaitingPayment(state),
        PurchaseStage.success => _success(state),
        PurchaseStage.browsing => _browsing(state),
      },
    );
  }

  Widget _browsing(PurchaseState state) {
    if (state.plansLoading) return const Center(child: CircularProgressIndicator());
    if (state.plansError != null) {
      return _centered(state.plansError!, action: ('重试', () => ref.read(purchaseNotifierProvider.notifier).loadPlans()));
    }

    // 按套餐分组
    final byPlan = <int, List<PlanOffer>>{};
    for (final o in state.plans) {
      byPlan.putIfAbsent(o.planId, () => []).add(o);
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (state.error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(state.error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        for (final entry in byPlan.entries) ...[
          _PlanGroup(offers: entry.value, onPick: _confirm),
          const SizedBox(height: 16),
        ],
        const SizedBox(height: 8),
        Text(
          '付款通过易支付，完成后套餐立即生效。如遇问题请联系客服。',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.outline),
        ),
      ],
    );
  }

  Future<void> _confirm(PlanOffer offer) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认购买'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${offer.name} · ${offer.durationLabel}', style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text('${offer.trafficLabel} · ${offer.priceLabel}'),
            const SizedBox(height: 12),
            const Text('点「去支付」会打开收银台（支付宝 / 微信），付完回到 App。', style: TextStyle(fontSize: 12)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('去支付')),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(purchaseNotifierProvider.notifier).startPurchase(offer);
    }
  }

  Widget _awaitingPayment(PurchaseState state) {
    final notifier = ref.read(purchaseNotifierProvider.notifier);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.open_in_new_rounded, size: 48),
          const SizedBox(height: 16),
          const Text('已打开收银台', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text(
            '在支付宝 / 微信里完成付款，然后回到这里点下面的按钮。',
            textAlign: TextAlign.center,
          ),
          if (state.error != null) ...[
            const SizedBox(height: 12),
            Text(state.error!, textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 24),
          FilledButton(onPressed: notifier.checkPayment, child: const Text('我已完成支付')),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: notifier.reopenPayment, child: const Text('重新打开支付')),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
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
    );
  }

  Widget _success(PurchaseState state) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.check_circle_rounded, size: 56, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 16),
          const Text('购买成功，套餐已开通', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          if (state.refreshing)
            const Text('正在刷新订阅信息…', style: TextStyle(fontSize: 13))
          else if (state.refreshFailed) ...[
            const Text(
              '订阅用量 / 到期时间还没刷新过来。回首页下拉刷新即可，不影响已开通的套餐。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => ref.read(purchaseNotifierProvider.notifier).retryRefresh(),
              child: const Text('重新刷新'),
            ),
          ],
          const SizedBox(height: 24),
          FilledButton(
            onPressed: () => context.canPop() ? context.pop() : context.goNamed('home'),
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }

  Widget _centered(String text, {(String, VoidCallback)? action}) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text),
          if (action != null) ...[
            const SizedBox(height: 12),
            OutlinedButton(onPressed: action.$2, child: Text(action.$1)),
          ],
        ],
      ),
    );
  }
}

class _PlanGroup extends StatelessWidget {
  const _PlanGroup({required this.offers, required this.onPick});

  final List<PlanOffer> offers;
  final Future<void> Function(PlanOffer) onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final head = offers.first;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            color: theme.colorScheme.surfaceContainerHighest,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(head.name, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 2),
                Text(head.trafficLabel, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          for (final o in offers)
            ListTile(
              title: Row(
                children: [
                  Text('${o.periodLabel}（${o.durationLabel}）'),
                  if (o.badge != null) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        o.badge!,
                        style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onPrimaryContainer),
                      ),
                    ),
                  ],
                ],
              ),
              subtitle: o.dailyLabel != null ? Text(o.dailyLabel!) : null,
              trailing: Text(
                o.priceLabel,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
              onTap: () => onPick(o),
            ),
        ],
      ),
    );
  }
}

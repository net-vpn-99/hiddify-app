/// 一个「套餐 × 周期」的可购买选项。对应 Xboard `plan/fetch` 里一条套餐的一个价格档。
class PlanOffer {
  const PlanOffer({
    required this.planId,
    required this.name,
    required this.trafficLabel,
    required this.period,
    required this.periodLabel,
    required this.durationLabel,
    required this.priceCents,
    required this.periodDays,
    this.badge,
  });

  final int planId;
  final String name;

  /// 例如「111 GB」。
  final String trafficLabel;

  /// 传给 order/save 的 period 键，例如 `month_price`。
  final String period;

  /// 例如「月付」。
  final String periodLabel;

  /// 例如「1 个月」。
  final String durationLabel;

  final int priceCents;
  final int periodDays;

  /// 「超值套餐」/「最受欢迎」，可空。
  final String? badge;

  String get priceLabel => '¥${(priceCents / 100).toStringAsFixed(2)}';

  String? get dailyLabel {
    if (periodDays <= 0 || priceCents <= 0) return null;
    return '¥${(priceCents / 100 / periodDays).toStringAsFixed(2)}/天';
  }

  PlanOffer withBadge(String? b) => PlanOffer(
        planId: planId,
        name: name,
        trafficLabel: trafficLabel,
        period: period,
        periodLabel: periodLabel,
        durationLabel: durationLabel,
        priceCents: priceCents,
        periodDays: periodDays,
        badge: b,
      );

  /// 从 plan/fetch 的一条套餐里展开出所有价格档。
  static List<PlanOffer> expand(Map<String, dynamic> plan) {
    num n(dynamic v) => v is num ? v : num.tryParse('$v') ?? 0;
    final id = n(plan['id']).toInt();
    if (id <= 0) return const [];
    final name = (plan['name'] as String?)?.trim() ?? '套餐';
    final traffic = _formatTraffic(n(plan['transfer_enable']).toInt());

    const cycles = <(String, String, String, int)>[
      ('onetime_price', '7天', '7 天', 7),
      ('month_price', '月付', '1 个月', 30),
      ('quarter_price', '季付', '3 个月', 90),
      ('half_year_price', '半年付', '6 个月', 180),
      ('year_price', '年付', '1 年', 365),
      ('two_year_price', '两年付', '2 年', 730),
      ('three_year_price', '三年付', '3 年', 1095),
    ];

    final out = <PlanOffer>[];
    for (final (key, label, duration, days) in cycles) {
      final raw = plan[key];
      final cents = raw == null ? 0 : n(raw).toInt();
      if (cents <= 0) continue;
      out.add(
        PlanOffer(
          planId: id,
          name: name,
          trafficLabel: traffic,
          period: key,
          periodLabel: label,
          durationLabel: duration,
          priceCents: cents,
          periodDays: days,
        ),
      );
    }
    return out;
  }

  /// 给「每天最便宜」的打「超值套餐」、第二便宜的打「最受欢迎」。
  static List<PlanOffer> withBadges(List<PlanOffer> offers) {
    var best = -1;
    var second = -1;
    var bestDaily = double.infinity;
    var secondDaily = double.infinity;
    for (var i = 0; i < offers.length; i++) {
      final o = offers[i];
      if (o.periodDays <= 0 || o.priceCents <= 0) continue;
      final daily = o.priceCents / o.periodDays;
      if (daily < bestDaily) {
        second = best;
        secondDaily = bestDaily;
        best = i;
        bestDaily = daily;
      } else if (daily < secondDaily) {
        second = i;
        secondDaily = daily;
      }
    }
    final result = [...offers];
    if (best >= 0) result[best] = result[best].withBadge('超值套餐');
    if (second >= 0) result[second] = result[second].withBadge('最受欢迎');
    return result;
  }

  static String _formatTraffic(int bytes) {
    if (bytes <= 0) return '不限流量';
    final gb = bytes / (1024 * 1024 * 1024);
    if (gb >= 1024) return '${(gb / 1024).toStringAsFixed(gb % 1024 == 0 ? 0 : 1)} TB';
    return '${gb.toStringAsFixed(gb.truncateToDouble() == gb ? 0 : 1)} GB';
  }
}

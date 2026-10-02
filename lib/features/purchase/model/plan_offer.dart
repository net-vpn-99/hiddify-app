/// 运营常量 —— 后台没有对应字段，只能客户端写死（见 VPN 仓库
/// docs/充值续费/数据契约-v2-实测修正.md §1 / §2）。
///
/// [kShortTermPlanId]：插件 GslInviteBonus 配置 `short_term_plan_id`。这个套餐的
/// 「一次性(onetime)」价位被插件改写成「N 天体验」，其余套餐的 onetime 仍是
/// Xboard 原生的一次性永久。改了插件配置这里也要改。
/// [kShortTermDays] / [kShortTermTrafficGb]：插件 `short_term_days` / `short_term_traffic_gb`。
///
/// [kDefaultRecommendedPeriod] / [kDefaultRecommendedBadge]：推荐档由服务端 GslShop 插件经
/// comm/config 的 gsl_shop 下发（改了不用发版），这两个只是拉不到时的兜底，和插件默认值一致。
const int kShortTermPlanId = 1;
const int kShortTermDays = 7;
const int kShortTermTrafficGb = 0; // 0 = 不限流量（插件 short_term_traffic_gb=0，2026-09-19）
const String kDefaultRecommendedPeriod = 'quarter_price';
const String kDefaultRecommendedBadge = '推荐选择';

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
    this.deviceLimit,
    this.recommended = false,
    this.badge,
  });

  final int planId;
  final String name;

  /// 套餐设备上限；null = 不限（后台 device_limit 为 null）。
  final int? deviceLimit;

  /// 例如「50 GB」/「不限流量」。短期档是短期专属额度（见 [kShortTermTrafficGb]）。
  final String trafficLabel;

  /// 传给 order/save 的 period 键，例如 `month_price`。
  final String period;

  /// 例如「月付」。
  final String periodLabel;

  /// 例如「1 个月」。短期档 = 「7 天」，非短期套餐的一次性 = 「一次性」。
  final String durationLabel;

  final int priceCents;

  /// 参考天数，只用于算日均价 / 比较。<= 0 = 不算日均价（一次性永久档）。
  final int periodDays;

  /// 推荐位（服务端 gsl_shop 下发，见 PurchaseService.fetchPlans）。
  final bool recommended;

  /// 运营徽标文案，可空。当前只有推荐位会填「推荐选择」。
  final String? badge;

  String get priceLabel => '¥${(priceCents / 100).toStringAsFixed(2)}';

  String? get dailyLabel {
    if (periodDays <= 0 || priceCents <= 0) return null;
    return '¥${(priceCents / 100 / periodDays).toStringAsFixed(2)}/天';
  }

  PlanOffer copyWith({bool? recommended, String? badge}) => PlanOffer(
        planId: planId,
        name: name,
        trafficLabel: trafficLabel,
        period: period,
        periodLabel: periodLabel,
        durationLabel: durationLabel,
        priceCents: priceCents,
        periodDays: periodDays,
        deviceLimit: deviceLimit,
        recommended: recommended ?? this.recommended,
        badge: badge ?? this.badge,
      );

  /// 从 plan/fetch 的一条套餐里展开出所有价格档。
  ///
  /// 单位口径（数据契约 §2）：
  /// - 套餐 `transfer_enable` 是 **GB 整数**（不是字节！账户接口那个才是字节）
  /// - `month_price` 等是 **分**（后台把 prices JSON 的「元」×100 下发成旧字段）
  ///   null = 该周期没设价 / 不可买；这里 null 和 <=0 都跳过
  static List<PlanOffer> expand(Map<String, dynamic> plan) {
    num n(dynamic v) => v is num ? v : num.tryParse('$v') ?? 0;
    final id = n(plan['id']).toInt();
    if (id <= 0) return const [];
    final name = (plan['name'] as String?)?.trim() ?? '套餐';
    final isShortTermPlan = id == kShortTermPlanId;
    final rawDevice = plan['device_limit'];
    final deviceLimit = rawDevice == null ? null : n(rawDevice).toInt();

    // (period 键, 周期文案, 时长文案, 参考天数)
    final cycles = <(String, String, String, int)>[
      // 一次性：只有短期套餐才当「N 天体验」（插件改写了到期时间）；
      // 其余套餐的 onetime 是 Xboard 原生的一次性永久，不算日均价。
      if (isShortTermPlan)
        ('onetime_price', '$kShortTermDays 天', '$kShortTermDays 天', kShortTermDays)
      else
        ('onetime_price', '一次性', '一次性', -1),
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
      if (raw == null) continue; // 没设这个周期的价 —— 跳过（null ≠ 0）
      final cents = n(raw).toInt();
      if (cents <= 0) continue; // 0 价不当免费档处理（本站无真实免费档）

      final gb = (key == 'onetime_price' && isShortTermPlan)
          ? kShortTermTrafficGb
          : n(plan['transfer_enable']).toInt();

      out.add(
        PlanOffer(
          planId: id,
          name: name,
          trafficLabel: _formatPlanTraffic(gb),
          period: key,
          periodLabel: label,
          durationLabel: duration,
          priceCents: cents,
          periodDays: days,
          deviceLimit: deviceLimit,
        ),
      );
    }
    return out;
  }

  /// 套餐额度格式化：入参是 **GB 整数**（不是字节）。0 / 负 / ≥1000G = 不限流量
  /// （2026-09-19 起全部套餐不限流量，后台用大额度代替）。
  static String _formatPlanTraffic(int gb) {
    if (gb <= 0 || gb >= 1000) return '不限流量';
    if (gb >= 1024 && gb % 1024 == 0) return '${gb ~/ 1024} TB';
    return '$gb GB';
  }
}

class ShopTier {
  const ShopTier({
    required this.tier,
    required this.planId,
    required this.name,
    required this.keyLine,
    required this.keyTone,
    required this.sub,
    required this.full,
    this.seatsLeft,
  });

  final String tier;
  final int planId;
  final String name;
  final String keyLine;
  final String keyTone;
  final String sub;
  final bool full;
  final int? seatsLeft;

  static List<ShopTier> listFrom(dynamic raw) {
    if (raw is! List) return const [];
    final out = <ShopTier>[];
    for (final row in raw) {
      if (row is! Map) continue;
      final id = row['plan_id'];
      final planId = id is num ? id.toInt() : int.tryParse('$id') ?? 0;
      if (planId <= 0) continue;
      final seats = row['seats_left'];
      out.add(ShopTier(
        tier: '${row['tier'] ?? ''}',
        planId: planId,
        name: '${row['name'] ?? ''}',
        keyLine: '${row['key'] ?? ''}',
        keyTone: '${row['key_tone'] ?? ''}',
        sub: '${row['sub'] ?? ''}',
        full: row['full'] == true,
        seatsLeft: seats is num ? seats.toInt() : null,
      ));
    }
    return out;
  }
}

class PeriodQuote {
  const PeriodQuote({
    required this.period,
    required this.priceFen,
    required this.surplusFen,
    required this.payFen,
    required this.fromToday,
    required this.expiresOn,
  });

  final String period;
  final int priceFen;
  final int surplusFen;
  final int payFen;
  final bool fromToday;
  final String expiresOn;

  static int _n(dynamic v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;

  static PeriodQuote? from(dynamic raw) {
    if (raw is! Map) return null;
    final period = '${raw['period'] ?? ''}';
    if (period.isEmpty) return null;
    return PeriodQuote(
      period: period,
      priceFen: _n(raw['price_fen']),
      surplusFen: _n(raw['surplus_fen']),
      payFen: _n(raw['pay_fen']),
      fromToday: raw['from_today'] == true,
      expiresOn: '${raw['expires_on'] ?? ''}',
    );
  }
}

class ShopMe {
  const ShopMe({
    required this.tier,
    required this.planName,
    required this.daysLeft,
    required this.expiresOn,
    required this.quotes,
  });

  final String tier;
  final String planName;
  final int daysLeft;
  final String expiresOn;
  final List<({int planId, List<PeriodQuote> periods})> quotes;

  PeriodQuote? quoteFor(int planId, String period) {
    for (final q in quotes) {
      if (q.planId != planId) continue;
      for (final p in q.periods) {
        if (p.period == period) return p;
      }
    }
    return null;
  }

  static ShopMe? from(dynamic raw) {
    if (raw is! Map) return null;
    final quotes = <({int planId, List<PeriodQuote> periods})>[];
    final list = raw['quotes'];
    if (list is List) {
      for (final row in list) {
        if (row is! Map) continue;
        final id = row['plan_id'];
        final planId = id is num ? id.toInt() : int.tryParse('$id') ?? 0;
        final periods = <PeriodQuote>[];
        final ps = row['periods'];
        if (ps is List) {
          for (final p in ps) {
            final parsed = PeriodQuote.from(p);
            if (parsed != null) periods.add(parsed);
          }
        }
        quotes.add((planId: planId, periods: periods));
      }
    }
    final days = raw['days_left'];
    return ShopMe(
      tier: '${raw['tier'] ?? ''}',
      planName: '${raw['plan_name'] ?? ''}',
      daysLeft: days is num ? days.toInt() : int.tryParse('$days') ?? 0,
      expiresOn: '${raw['expires_on'] ?? ''}',
      quotes: quotes,
    );
  }
}

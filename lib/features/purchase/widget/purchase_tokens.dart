import 'package:flutter/material.dart';
import 'package:hiddify/features/panel_auth/data/panel_api.dart';

/// 购买 / 续费页专用配色 —— 取自 VPN 仓库
/// docs/充值续费/purchase-design-handoff-v1/design-tokens.json，浅深两套。
/// 局部使用（不动全局主题），跟 Windows 客户端 Theme.qml / 官网 site.css 一致。
// ignore: use_enums  —— 不是枚举：每套是一组具体色值，用 .light / .dark 取。
class PurchaseTokens {
  const PurchaseTokens._({
    required this.background,
    required this.surface,
    required this.raised,
    required this.text,
    required this.secondary,
    required this.border,
    required this.fill,
    required this.primary,
    required this.primaryHover,
    required this.onPrimary,
    required this.selected,
    required this.remaining,
    required this.warning,
    required this.empty,
  });

  final Color background;
  final Color surface;
  final Color raised;
  final Color text;
  final Color secondary;
  final Color border;
  final Color fill;
  final Color primary;
  final Color primaryHover;
  final Color onPrimary;
  final Color selected;
  final Color remaining;
  final Color warning;
  final Color empty;

  static const light = PurchaseTokens._(
    background: Color(0xFFF5F4EF),
    surface: Color(0xFFFCFBF7),
    raised: Color(0xFFFFFFFF),
    text: Color(0xFF17191D),
    secondary: Color(0xFF5E636B),
    border: Color(0xFFD9D7CF),
    fill: Color(0xFFEBE9E2),
    primary: Color(0xFFE1B83F),
    primaryHover: Color(0xFFD3A833),
    onPrimary: Color(0xFF17191D),
    selected: Color(0xFFFBF4DD),
    remaining: Color(0xFF2A9477),
    warning: Color(0xFFA66116),
    empty: Color(0xFFB34435),
  );

  static const dark = PurchaseTokens._(
    background: Color(0xFF101214),
    surface: Color(0xFF191B1D),
    raised: Color(0xFF20252B),
    text: Color(0xFFF1F1EC),
    secondary: Color(0xFFA3A7A1),
    border: Color(0xFF34383B),
    fill: Color(0xFF24282B),
    primary: Color(0xFFF0C94F),
    primaryHover: Color(0xFFF7D76F),
    onPrimary: Color(0xFF17191D),
    selected: Color(0xFF30291A),
    remaining: Color(0xFF70D8B8),
    warning: Color(0xFFE4AE69),
    empty: Color(0xFFEC9A8B),
  );

  static PurchaseTokens of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;
}

/// 账户剩余流量的显示状态（数据契约 §流量条）。
enum QuotaState { normal, low, empty, unlimited, unknown }

/// 账户字节按 GiB（1024³）换算，与 Windows 客户端口径一致。
String formatAccountBytes(int bytes) {
  if (bytes <= 0) return '0 GB';
  final gb = bytes / (1024 * 1024 * 1024);
  if (gb >= 10) return '${gb.round()} GB';
  if (gb >= 1) return '${gb.toStringAsFixed(1)} GB';
  return '${(bytes / (1024 * 1024)).round()} MB';
}

QuotaState quotaStateOf(PanelAccount? a) {
  if (a == null) return QuotaState.unknown;
  if (a.transferEnable <= 0) return QuotaState.unlimited;
  final left = a.transferEnable - a.used;
  if (left <= 0) return QuotaState.empty;
  if (left * 5 <= a.transferEnable) return QuotaState.low; // 剩余 ≤ 20%
  return QuotaState.normal;
}

/// 剩余占比 0..1；null = 不限 / 未知（不画条）。
double? quotaRatioOf(PanelAccount? a) {
  if (a == null || a.transferEnable <= 0) return null;
  final left = (a.transferEnable - a.used).clamp(0, a.transferEnable);
  return left / a.transferEnable;
}

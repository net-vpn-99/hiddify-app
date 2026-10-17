import 'package:flutter/material.dart';
import 'package:hiddify/features/panel_auth/data/panel_api.dart';

/// 安卓整个 App 的配色：B「夜航」深浅两套（10-17 定稿，VPN 仓库 docs/计划/界面改版-B夜航.md §3.1）。
/// 名字跟 Windows `Theme.qml` 一一对应；全局主题（app_theme.dart）也从这里取。
/// 页面里要颜色就读 OneRayTokens.of(context)，别再自己写色值。
// ignore: use_enums  —— 不是枚举：每套是一组具体色值，用 .light / .dark 取。
class OneRayTokens {
  const OneRayTokens._({
    required this.bg,
    required this.scope,
    required this.card,
    required this.panel,
    required this.sheet,
    required this.ring,
    required this.text,
    required this.sub,
    required this.dim,
    required this.acc,
    required this.accHover,
    required this.accSoft,
    required this.accInk,
    required this.blip,
    required this.fault,
    required this.faultSoft,
    required this.scrim,
    required this.line,
  });

  /// 窗口 / 页面底
  final Color bg;

  /// 雷达屏底
  final Color scope;

  /// 卡片、底部面板
  final Color card;

  /// 卡片里的浅底块、次按钮、输入框
  final Color panel;

  /// 侧栏 / 弹窗底
  final Color sheet;

  /// 雷达圈、极少数分割线
  final Color ring;

  /// 正文
  final Color text;

  /// 次要文字
  final Color sub;

  /// 占位、不可用
  final Color dim;

  /// 唯一强调色：主按钮、选中、链接、「精品」标签、未读圆点
  final Color acc;

  /// 强调色按钮按下 / 悬停
  final Color accHover;

  /// 强调色浅底（选中、提示条）
  final Color accSoft;

  /// 强调色实心上的字
  final Color accInk;

  /// 雷达上没选中的光点
  final Color blip;

  /// 出错小标签字 / 光点（不做整块红底）
  final Color fault;

  /// 出错小标签底
  final Color faultSoft;

  /// 弹窗 / 底部面板后面的遮罩
  final Color scrim;

  /// 只给「断开 / 取消」按钮描边
  final Color line;

  /// 运营商 LOGO、二维码底下垫的白块：深色模式里也是白。
  static const paper = Color(0xFFFFFFFF);

  /// 数字字体（延迟、速度、价格、天数、配对码、诊断码）。夹着汉字的字串仍用系统字体。
  static const numberFont = 'Saira';

  static const light = OneRayTokens._(
    bg: Color(0xFFEEF3F7),
    scope: Color(0xFFFFFFFF),
    card: Color(0xFFFFFFFF),
    panel: Color(0xFFEEF3F7),
    sheet: Color(0xFFFFFFFF),
    ring: Color(0xFFD3DCE6),
    text: Color(0xFF13202E),
    sub: Color(0xFF5A6B7D),
    dim: Color(0xFF8C9BAB),
    acc: Color(0xFF0B8F7A),
    accHover: Color(0xFF097A68),
    accSoft: Color(0xFFE3F4F0),
    accInk: Color(0xFFFFFFFF),
    blip: Color(0xFF79B8AC),
    fault: Color(0xFFC2412D),
    faultSoft: Color(0xFFFBE7E2),
    scrim: Color(0x4713202E),
    line: Color(0xFFC3CEDA),
  );

  static const dark = OneRayTokens._(
    bg: Color(0xFF0E1B2B),
    scope: Color(0xFF112235),
    card: Color(0xFF142538),
    panel: Color(0xFF1A2E44),
    sheet: Color(0xFF132436),
    ring: Color(0xFF23384F),
    text: Color(0xFFE9EEF2),
    sub: Color(0xFF8EA0B3),
    dim: Color(0xFF5E738A),
    acc: Color(0xFF74E0C1),
    accHover: Color(0xFF8FE8CE),
    accSoft: Color(0x1F74E0C1),
    accInk: Color(0xFF0E1B2B),
    blip: Color(0xFF3E8F82),
    fault: Color(0xFFFF8E7E),
    faultSoft: Color(0x24FF8E7E),
    scrim: Color(0x8C050C14),
    line: Color(0xFF3A5370),
  );

  static OneRayTokens of(BuildContext context) =>
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
  if (a.unlimitedQuota) return QuotaState.unlimited;
  final left = a.transferEnable - a.used;
  if (left <= 0) return QuotaState.empty;
  if (left * 5 <= a.transferEnable) return QuotaState.low; // 剩余 ≤ 20%
  return QuotaState.normal;
}

/// 剩余占比 0..1；null = 不限 / 未知（不画条）。
double? quotaRatioOf(PanelAccount? a) {
  if (a == null || a.unlimitedQuota) return null;
  final left = (a.transferEnable - a.used).clamp(0, a.transferEnable);
  return left / a.transferEnable;
}

import 'package:circle_flags/circle_flags.dart';
import 'package:flutter/material.dart';

/// 线路名 → 两位国家码。
///
/// 跟 Windows 端 `routelistmodel.cpp` 的 `countryCodeFromName` 同一套规则，两端显示
/// 一致。我们的节点名是「香港 02」「美国洛杉矶」「日本大阪 | ...」这种，含地区名就够判。
/// 认不出来返回 null —— 调用方退回一个地球图标，别瞎猜（猜错的国旗比没有更糟）。
String? countryCodeFromLineName(String name) {
  final n = name.toLowerCase();
  bool has(List<String> keys) => keys.any(n.contains);

  if (has(['香港', 'hong kong', 'hongkong', 'hk'])) return 'hk';
  if (has(['台湾', '台北', 'taiwan', 'taipei'])) return 'tw';
  if (has(['日本', '东京', '大阪', 'japan', 'tokyo', 'osaka'])) return 'jp';
  if (has(['新加坡', 'singapore'])) return 'sg';
  if (has(['韩国', '首尔', 'korea', 'seoul'])) return 'kr';
  if (has(['美国', '洛杉矶', '硅谷', '圣何塞', 'usa', 'united states', 'los angeles', 'san jose'])) {
    return 'us';
  }
  if (has(['英国', '伦敦', 'london', 'united kingdom'])) return 'gb';
  if (has(['德国', '法兰克福', 'germany', 'frankfurt'])) return 'de';
  if (has(['荷兰', 'netherlands', 'amsterdam'])) return 'nl';
  if (has(['加拿大', 'canada'])) return 'ca';
  if (has(['澳洲', '澳大利亚', '悉尼', 'australia', 'sydney'])) return 'au';
  if (has(['俄罗斯', 'russia'])) return 'ru';
  if (has(['法国', 'france', 'paris'])) return 'fr';
  if (has(['马来', 'malaysia'])) return 'my';
  if (has(['菲律宾', 'philippines'])) return 'ph';
  if (has(['越南', 'vietnam'])) return 'vn';
  if (has(['泰国', 'thailand'])) return 'th';
  if (has(['印度', 'india'])) return 'in';
  if (has(['土耳其', 'turkey'])) return 'tr';
  return null;
}

/// 线路名前面那面国旗。认不出地区就显示地球图标，尺寸和占位都一样，列表不会跳。
///
/// 用 `circle_flags` 的内置 SVG（App 里本来就有，ip_widget 也用它），不用系统 emoji
/// 字体 —— 国内 ROM 的 emoji 国旗支持参差不齐，有的直接显示成「HK」两个字母。
class LineFlag extends StatelessWidget {
  const LineFlag(this.lineName, {this.size = 22, super.key});

  final String lineName;
  final double size;

  @override
  Widget build(BuildContext context) {
    final code = countryCodeFromLineName(lineName);
    if (code == null) {
      return Icon(Icons.public_rounded, size: size, color: Theme.of(context).colorScheme.primary);
    }
    return SizedBox(
      width: size,
      height: size,
      child: CircleFlag(code, size: size),
    );
  }
}

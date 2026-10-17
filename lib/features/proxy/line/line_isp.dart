import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:hiddify/core/theme/oneray_tokens.dart';
import 'package:hiddify/features/proxy/line/line_source.dart';
import 'package:hiddify/features/proxy/model/node_display.dart';

/// 线路适合哪家宽带：运营商 LOGO、「精品」小标签、列表顶上那句提示、同国家里适合的排前面。
///
/// 唯一来源是线路名第二段（splitNodeName 的 isps），用户是哪家宽带来自 getSubscribe 的
/// gsl_isp。规则见 `docs/计划/按地区运营商调整推荐线路.md` 第九节，Windows 同一套。
/// LOGO 是三家官网的官方图案（运营 10-17 同意使用），只取左边图案：电信 / 联通是 PNG，
/// 移动是 SVG（从官网 SVG 抠出圆环，样式写成 fill，flutter_svg 不吃 <style>）。

const _logoAssets = {
  '电信': 'assets/images/isp/ct.png',
  '联通': 'assets/images/isp/cu.png',
  '移动': 'assets/images/isp/cm.svg',
};

/// 这条线写着适合 [isp] 这家（[isp] 为空 = 不知道用户是哪家，谁都不算）。
bool lineFitsIsp(LineOption o, String isp) => isp.isNotEmpty && (o.isps?.contains(isp) ?? false);

/// 同一个国家里，适合 [isp] 的线路排前面；国家之间的位置、同类线路之间的先后都不动。
/// 做法：每个国家原来占的那几个位置不变，只把这个国家自己的线路按「适合的在前」重新填进去。
List<LineOption> ispFitFirst(List<LineOption> lines, String isp) {
  if (isp.isEmpty) return lines;
  final fit = <String, List<LineOption>>{};
  final rest = <String, List<LineOption>>{};
  for (final o in lines) {
    (lineFitsIsp(o, isp) ? fit : rest).putIfAbsent(lineCountry(o.name), () => []).add(o);
  }
  final sorted = {
    for (final c in {...fit.keys, ...rest.keys}) c: [...?fit[c], ...?rest[c]],
  };
  final cursor = <String, int>{};
  final out = <LineOption>[];
  for (final o in lines) {
    final c = lineCountry(o.name);
    final i = cursor[c] ?? 0;
    cursor[c] = i + 1;
    out.add(sorted[c]![i]);
  }
  return out;
}

/// 一家运营商的 LOGO，18dp。[ring] = 用户自己那家：外面一圈 1.5dp 主题橙。
class IspLogo extends StatelessWidget {
  const IspLogo(this.isp, {super.key, this.ring = false, this.size = 18});

  final String isp;
  final bool ring;
  final double size;

  @override
  Widget build(BuildContext context) {
    final asset = _logoAssets[isp];
    if (asset == null) return const SizedBox.shrink();
    final tokens = OneRayTokens.of(context);
    final image = asset.endsWith('.svg')
        ? SvgPicture.asset(asset, width: size, height: size)
        : Image.asset(asset, width: size, height: size, fit: BoxFit.contain);
    return Container(
      width: size,
      height: size,
      decoration: ring
          ? BoxDecoration(
              // LOGO 是彩色图，深色模式下也垫白底，跟橙圈一起像一枚徽章。
              color: Colors.white,
              borderRadius: BorderRadius.circular(4),
              boxShadow: [BoxShadow(color: tokens.acc, spreadRadius: 1.5)],
            )
          : null,
      child: image,
    );
  }
}

/// 线路行右边那一组：写着适合的几家各一个 LOGO，用户那家加橙圈；
/// 没有宽带段 /「暂不推荐」→ 什么都不放，不写任何负面字眼（10-17 运营定，两端一样）。
class LineIspMarks extends StatelessWidget {
  const LineIspMarks({super.key, required this.option, required this.isp});

  final LineOption option;
  final String isp;

  /// 这条线有没有 LOGO 可放（调用方据此决定留不留间距）。
  static bool hasMarks(LineOption o) => o.isps?.isNotEmpty ?? false;

  /// LOGO 区固定宽度 = 三个 LOGO 的宽度，一个 / 两个时靠右，各行 LOGO 右边对齐、左边文字不跟着跳。
  static const width = 18.0 * 3 + 5 * 2;

  @override
  Widget build(BuildContext context) {
    final isps = option.isps;
    if (isps == null || isps.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      width: width,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          for (final (i, w) in isps.indexed) ...[
            if (i > 0) const SizedBox(width: 5),
            IspLogo(w, ring: w == isp),
          ],
        ],
      ),
    );
  }
}

/// 精品线路名字后面的橙色「精品」小标签。
class ProBadge extends StatelessWidget {
  const ProBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = OneRayTokens.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(color: tokens.acc, borderRadius: BorderRadius.circular(5)),
      child: Text(
        '精品',
        style: TextStyle(fontSize: 11, height: 1.3, fontWeight: FontWeight.w700, color: tokens.accInk),
      ),
    );
  }
}

/// 列表顶上那条浅橙提示：「你用的是中国X宽带。线路后面有 [LOGO] 的，适合你用。」
/// 列表里至少有一条线路适合 [isp] 才显示（[isp] 为空自然也不显示）。
class IspHint extends StatelessWidget {
  const IspHint({super.key, required this.isp, required this.lines, this.margin = EdgeInsets.zero});

  final String isp;

  /// 整个线路列表（含收起的分组）。一条都不适合 [isp] = 列表里根本没有这家的 LOGO，
  /// 提示了用户也找不到，不显示（10-17 运营真机）。
  final List<LineOption> lines;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    if (!lines.any((o) => lineFitsIsp(o, isp))) return const SizedBox.shrink();
    final tokens = OneRayTokens.of(context);
    final style = TextStyle(fontSize: 12, color: tokens.acc);
    return Padding(
      padding: margin,
      child: DecoratedBox(
        decoration: BoxDecoration(color: tokens.accSoft, borderRadius: BorderRadius.circular(10)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text.rich(
            TextSpan(
              style: style,
              children: [
                // 两端一字不差（Windows RoutePalette 同一句）。
                TextSpan(text: '你用的是中国$isp宽带。线路后面有'),
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: Padding(padding: const EdgeInsets.symmetric(horizontal: 3), child: IspLogo(isp)),
                ),
                const TextSpan(text: '的，适合你用。'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

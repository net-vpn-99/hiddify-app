import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:hiddify/features/proxy/line/line_source.dart';
import 'package:hiddify/features/proxy/model/node_display.dart';
import 'package:hiddify/features/purchase/widget/purchase_tokens.dart';

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
    final tokens = PurchaseTokens.of(context);
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
              boxShadow: [BoxShadow(color: tokens.primary, spreadRadius: 1.5)],
            )
          : null,
      child: image,
    );
  }
}

/// 线路行右边那一组：写着适合的几家各一个 LOGO，用户那家加橙圈；
/// 「暂不推荐」→ 灰字「三家都不推荐」；老名字（没有宽带段）→ 什么都不放。
class LineIspMarks extends StatelessWidget {
  const LineIspMarks({super.key, required this.option, required this.isp});

  final LineOption option;
  final String isp;

  @override
  Widget build(BuildContext context) {
    final isps = option.isps;
    if (isps == null) return const SizedBox.shrink();
    final tokens = PurchaseTokens.of(context);
    if (isps.isEmpty) {
      return Text(
        '三家都不推荐',
        maxLines: 1,
        style: TextStyle(fontSize: 10, color: tokens.secondary.withValues(alpha: 0.7)),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (i, w) in isps.indexed) ...[
          if (i > 0) const SizedBox(width: 5),
          IspLogo(w, ring: w == isp),
        ],
      ],
    );
  }
}

/// 精品线路名字后面的橙色「精品」小标签。
class ProBadge extends StatelessWidget {
  const ProBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = PurchaseTokens.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(color: tokens.primary, borderRadius: BorderRadius.circular(5)),
      child: Text(
        '精品',
        style: TextStyle(fontSize: 10, height: 1.3, fontWeight: FontWeight.w700, color: tokens.onPrimary),
      ),
    );
  }
}

/// 列表顶上那条浅橙提示：「你用的是 [LOGO] 中国X宽带，带橙圈的线路更适合你」。[isp] 为空不显示。
class IspHint extends StatelessWidget {
  const IspHint({super.key, required this.isp, this.margin = EdgeInsets.zero});

  final String isp;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    if (!kIspWords.contains(isp)) return const SizedBox.shrink();
    final tokens = PurchaseTokens.of(context);
    final style = TextStyle(fontSize: 12, color: tokens.warning);
    return Padding(
      padding: margin,
      child: DecoratedBox(
        decoration: BoxDecoration(color: tokens.selected, borderRadius: BorderRadius.circular(10)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text.rich(
            TextSpan(
              style: style,
              children: [
                const TextSpan(text: '你用的是 '),
                WidgetSpan(alignment: PlaceholderAlignment.middle, child: IspLogo(isp, ring: true)),
                TextSpan(text: ' 中国$isp宽带，带橙圈的线路更适合你'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

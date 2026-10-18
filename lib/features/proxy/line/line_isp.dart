import 'package:hiddify/features/proxy/line/line_source.dart';
import 'package:hiddify/features/proxy/model/node_display.dart';

/// 线路适合哪家宽带：同国家里适合的排前面、线路页「适合 X」标签（10-18 改版起不再画三家 LOGO，只标用户自己那家）。
///
/// 唯一来源是线路名第二段（splitNodeName 的 isps），用户是哪家宽带来自 getSubscribe 的
/// gsl_isp。规则见 VPN 仓库 `docs/计划/线路列表改版.md`，Windows 同一套。

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

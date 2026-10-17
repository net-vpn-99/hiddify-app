import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/proxy/line/line_isp.dart';
import 'package:hiddify/features/proxy/model/node_display.dart';

/// 线路名第九节格式（docs/计划/按地区运营商调整推荐线路.md），验收那几条名字都在这。
void main() {
  test('新格式：宽带段拆成列表，第三段当说明', () {
    final n = splitNodeName('香港 09 | 电信 联通 | 低延迟');
    expect(n.name, '香港 09');
    expect(n.isps, ['电信', '联通']);
    expect(n.desc, '低延迟');
    expect(n.pro, false);
  });

  test('精品：⭐精品 从名字里拿掉，pro 为 true，宽带按 电信→联通→移动 排', () {
    final n = splitNodeName('日本 东京 03 ⭐精品 | 移动 电信 联通 | 晚高峰稳 § 0');
    expect(n.name, '日本 东京 03');
    expect(n.pro, true);
    expect(n.isps, ['电信', '联通', '移动']);
    expect(n.desc, '晚高峰稳');
  });

  test('暂不推荐 / 第二段空 → 空列表', () {
    expect(splitNodeName('韩国 首尔 01 | 暂不推荐 | 能用 AI').isps, isEmpty);
    expect(splitNodeName('香港 09 |  | 能用 AI').isps, isEmpty);
    expect(splitNodeName('香港 09 |  | 能用 AI').desc, '能用 AI');
  });

  test('老名字照旧：第二段不是宽带词就当说明，isps 为 null', () {
    final n = splitNodeName('香港 01 | 低延迟 · 不能用 ChatGPT | 适合 网页');
    expect(n.name, '香港 01');
    expect(n.isps, isNull);
    expect(n.desc, '低延迟 · 不能用 ChatGPT · 适合 网页');
    expect(splitNodeName('美国 洛杉矶 01').isps, isNull);
    expect(splitNodeName('美国 洛杉矶 01').desc, '');
    expect(splitNodeName('日本 | 电信优化').isps, isNull);
  });

  test('同国家里适合的排前面，国家位置不动', () {
    final lines = [
      for (final s in ['香港 01 | 电信 联通 | a', '日本 大阪 01 | 暂不推荐 | b', '香港 03 | 移动 | c', '日本 东京 02 | 移动 | d'])
        splitNodeName(s),
    ];
    expect(ispFitFirst(lines, '移动').map((o) => o.name), ['香港 03', '日本 东京 02', '香港 01', '日本 大阪 01']);
    expect(ispFitFirst(lines, '电信').map((o) => o.name), ['香港 01', '日本 大阪 01', '香港 03', '日本 东京 02']);
    expect(ispFitFirst(lines, ''), same(lines));
  });
}

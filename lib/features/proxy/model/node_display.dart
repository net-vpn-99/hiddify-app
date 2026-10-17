import 'dart:convert';

import 'package:hiddify/utils/link_parsers.dart';

/// 非节点的出站类型（分组 / 内置），选线路时要跳过。
const _nonNodeOutboundTypes = {
  'selector', 'urltest', 'loadbalance', 'loadbalancer',
  'direct', 'block', 'dns', 'dns-out',
};

/// 离线读出当前订阅里的线路列表（不用连接）。
///
/// hiddify-core 会把订阅（我们是 base64 vless:// 列表）转成一份 sing-box JSON 存到
/// 本地 profile 文件里，所以这里拿到的一般是 JSON —— 从 `outbounds` 里挑真实协议的出站。
/// 兜底也能处理 base64 / 纯文本的 vless 列表（`#` 后是名字）。
/// 返回 splitNodeName 拆好的线路名，按顺序、按 name 去重。
List<NodeName> parseSubscriptionLines(String raw) {
  final text = raw.trim();
  final result = <NodeName>[];
  final seen = <String>{};
  void add(String tag) {
    final s = splitNodeName(tag);
    if (s.name.isNotEmpty && seen.add(s.name)) result.add(s);
  }

  // 1) sing-box JSON
  try {
    final obj = jsonDecode(text);
    if (obj is Map && obj['outbounds'] is List) {
      for (final ob in obj['outbounds'] as List) {
        if (ob is! Map) continue;
        final type = (ob['type'] ?? '').toString().toLowerCase();
        final tag = (ob['tag'] ?? '').toString();
        if (tag.isEmpty || _nonNodeOutboundTypes.contains(type) || isAutoGroupTag(tag)) continue;
        add(tag);
      }
      return result;
    }
  } catch (_) {
    // 不是 JSON，走下面的行解析
  }

  // 2) base64 / 纯文本的 proxy URI 列表
  var lines = text;
  final decoded = safeDecodeBase64(lines);
  if (decoded.contains('://')) lines = decoded;
  for (final rawLine in const LineSplitter().convert(lines)) {
    final line = rawLine.trim();
    if (line.isEmpty || !line.contains('://')) continue;

    String? frag;
    final hashIdx = line.indexOf('#');
    if (hashIdx >= 0 && hashIdx < line.length - 1) {
      try {
        frag = Uri.decodeComponent(line.substring(hashIdx + 1));
      } catch (_) {
        frag = line.substring(hashIdx + 1);
      }
    } else if (line.startsWith('vmess://')) {
      try {
        final obj = jsonDecode(safeDecodeBase64(line.substring('vmess://'.length))) as Map;
        frag = obj['ps']?.toString();
      } catch (_) {}
    }
    if (frag == null || frag.trim().isEmpty) continue;
    add(frag);
  }
  return result;
}

/// hiddify-core 会自动生成几个"均衡/自动"分组出站（select / balance / lowest 等），
/// 用户看不懂、还会误选到 round-robin（一半流量走美国，慢 + IP 乱跳）。
/// UI 里把这些藏掉，只留真实线路；连接后若当前选中的是这些组，自动切回真实节点。
const kAutoGroupTags = {'select', 'balance', 'lowest', 'auto', 'url-test', 'urltest'};

bool isAutoGroupTag(String tag) => kAutoGroupTags.contains(tag.trim().toLowerCase());

/// 拆好的线路名。
///  - name：第一段去掉「⭐精品」，全 App 拿它当线路的名字（偏好、维修中、测速都按它对）；
///  - desc：说明（新格式是第三段；老名字是第二段以后）；
///  - isps：第二段写的适合哪几家宽带（顺序固定电信→联通→移动）。空列表 = 「暂不推荐」/ 空段，
///    null = 没有这一段（只有一段的名字、老名字）。两种都不放 LOGO、不写任何字（10-17 运营定）；
///  - pro：名字里有「⭐精品」。
typedef NodeName = ({String name, String desc, List<String>? isps, bool pro});

/// 线路名第二段能写的宽带词，也是 LOGO 的排列顺序。
const kIspWords = ['电信', '联通', '移动'];

final _proMark = RegExp(r'⭐️?\s*精品');

/// 线路名格式（10-17 定，`docs/计划/按地区运营商调整推荐线路.md` 第九节，跟 Windows 同一套）：
/// 「地区 城市 编号[ ⭐精品] | 宽带 | 特点」，后两段可以没有：「日本 东京 01」「新加坡 01 | 移动」
/// 「日本 东京 03 ⭐精品 | 电信 联通 移动 | 晚高峰稳」。只有一段时它就是名字。
/// 老名字「地区 | 线路说明 | 场景」照旧：第二段不是宽带词就当说明。
/// hiddify-core 还会加个 " § N" 组序号，先去掉。
NodeName splitNodeName(String raw) {
  var s = raw.trim();
  final marker = s.lastIndexOf('§');
  if (marker > 0 && RegExp(r'§\s*\d+\s*$').hasMatch(s.substring(marker))) {
    s = s.substring(0, marker).trim();
  }
  final parts = s.split('|').map((e) => e.trim()).toList();
  final isps = parts.length >= 2 && parts.first.isNotEmpty ? _ispsOf(parts[1], blankOk: parts.length >= 3) : null;
  final kept = [
    for (final (i, p) in parts.indexed)
      if (p.isNotEmpty && !(isps != null && i == 1)) p,
  ];
  if (kept.isEmpty) return (name: s, desc: '', isps: null, pro: false);
  final head = kept.first;
  final pro = _proMark.hasMatch(head);
  final name = pro ? head.replaceAll(_proMark, ' ').replaceAll(RegExp(r'\s+'), ' ').trim() : head;
  return (name: name.isEmpty ? head : name, desc: kept.skip(1).join(' · '), isps: isps, pro: pro);
}

/// 第二段 → 宽带列表。「暂不推荐」/ 空（后面还有第三段时）→ 空列表；不是宽带词 → null（老名字）。
List<String>? _ispsOf(String seg, {required bool blankOk}) {
  if (seg == '暂不推荐') return const [];
  if (seg.isEmpty) return blankOk ? const [] : null;
  final words = seg.split(RegExp(r'\s+')).toSet();
  if (!words.every(kIspWords.contains)) return null;
  return [for (final w in kIspWords) if (words.contains(w)) w];
}

/// 线路名第一个词 = 国家 / 地区（「日本 东京 03」→「日本」），线路页按它分组。
String lineCountry(String name) {
  final head = name.trim().split(RegExp(r'\s+')).first.trim();
  return head.isEmpty ? '其它' : head;
}

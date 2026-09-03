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
/// 返回 splitNodeName 拆好的 (name, desc)，按顺序、按 name 去重。
List<({String name, String desc})> parseSubscriptionLines(String raw) {
  final text = raw.trim();
  final result = <({String name, String desc})>[];
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

/// Xboard 节点名格式：「地区 | 线路说明 | 场景」，hiddify-core 还会加个 " § N" 组序号。
/// 拆成 (name, desc) 给 UI 分两行显示，客户更好选。
({String name, String desc}) splitNodeName(String raw) {
  var s = raw.trim();
  final marker = s.lastIndexOf('§');
  if (marker > 0 && RegExp(r'§\s*\d+\s*$').hasMatch(s.substring(marker))) {
    s = s.substring(0, marker).trim();
  }
  final parts = s.split('|').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  if (parts.isEmpty) return (name: s, desc: '');
  if (parts.length == 1) return (name: parts.first, desc: '');
  return (name: parts.first, desc: parts.sublist(1).join(' · '));
}

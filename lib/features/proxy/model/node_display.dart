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

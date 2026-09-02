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

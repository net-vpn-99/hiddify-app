/// 公共后缀表（Public Suffix List）取主域名：imgb.anycip.com → anycip.com，xxx.github.io 保持完整。
/// 跟 Windows publicsuffix.cpp 同一套。名单里的中文后缀（如 公司.cn）跳过：日志里的网址是 xn-- 形式，
/// 这几个对不上，最多把这类网站的主域名多截一级。
class PublicSuffix {
  PublicSuffix._(this._rules, this._wildcards, this._exceptions);

  final Set<String> _rules;
  final Set<String> _wildcards;
  final Set<String> _exceptions;

  /// 每行第一个空白之前是规则；空行和 // 注释跳过。
  factory PublicSuffix.parse(String text) {
    final rules = <String>{};
    final wildcards = <String>{};
    final exceptions = <String>{};
    for (var line in text.split('\n')) {
      line = line.trim();
      if (line.isEmpty || line.startsWith('//')) continue;
      line = line.split(RegExp(r'\s')).first.toLowerCase();
      if (line.codeUnits.any((c) => c > 0x7f)) continue;
      if (line.startsWith('!')) {
        exceptions.add(line.substring(1));
      } else if (line.startsWith('*.')) {
        wildcards.add(line.substring(2));
      } else {
        rules.add(line);
      }
    }
    return PublicSuffix._(rules, wildcards, exceptions);
  }

  String registrable(String host) {
    final h = host.toLowerCase();
    final labels = h.split('.').where((l) => l.isNotEmpty).toList();
    if (labels.length < 2) return h;
    // 从最长的候选后缀往短里找，第一个命中的就是最长的公共后缀；都不中按默认规则「*」= 最后一级。
    var suffixStart = labels.length - 1;
    for (var i = 0; i < labels.length; i++) {
      final candidate = labels.sublist(i).join('.');
      if (_exceptions.contains(candidate)) {
        suffixStart = i + 1;
        break;
      }
      if (_rules.contains(candidate)) {
        suffixStart = i;
        break;
      }
      if (i + 1 < labels.length && _wildcards.contains(labels.sublist(i + 1).join('.'))) {
        suffixStart = i;
        break;
      }
    }
    if (suffixStart == 0) return h; // 主机名本身就是公共后缀
    return labels.sublist(suffixStart - 1).join('.');
  }
}

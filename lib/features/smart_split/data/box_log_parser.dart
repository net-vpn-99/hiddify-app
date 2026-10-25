import 'package:hiddify/features/smart_split/model/classifier.dart';

/// 读 box.log（info 级）拼连接：同一个连接号下先有「哪个 App」，后有「去哪、走哪条出站」。
/// 10-25 真机（诊断 1E12-1025）：
///   INFO [2331236780 4ms] router: found package name: com.microsoft.emmx
///   INFO [2331236780 52ms] outbound/vless[美国 洛杉矶 07 …]: outbound connection to www.btsj6.com:443
///   INFO [2701029455 20ms] outbound/direct[direct §hide§]: outbound connection to loc.map.baidu.com:443
/// 出站行同一条连接会出现两次（相隔约 0.4 秒），只算第一次。只有包名、没有出站行的（假 DNS 那几行）不出连接。
class BoxLogParser {
  static final _pkgRe = RegExp(r'\[(\d+) [^\]]*\] router: found package name: (\S+)');
  static final _outRe = RegExp(r'\[(\d+) [^\]]*\] outbound/(\w+)\[.*\]: outbound connection to (\S+)');

  final _pkg = <String, String>{};
  final _done = <String>{};

  /// 喂新读到的整行文本，返回这次新拼出来的连接（按出现先后）。
  List<Conn> feed(String text) {
    final out = <Conn>[];
    for (final line in text.split('\n')) {
      final p = _pkgRe.firstMatch(line);
      if (p != null) {
        _pkg[p.group(1)!] = p.group(2)!;
        continue;
      }
      final o = _outRe.firstMatch(line);
      if (o == null) continue;
      final id = o.group(1)!;
      final type = o.group(2)!;
      if (type == 'block' || !_done.add(id)) continue;
      out.add(Conn(id: id, pkg: _pkg[id] ?? '', host: _host(o.group(3)!), outbound: type == 'direct' ? 'direct' : 'proxy'));
    }
    return out;
  }

  /// www.x.com:443 → www.x.com；[fc00::1]:443 → fc00::1
  static String _host(String target) {
    if (target.startsWith('[')) {
      final end = target.indexOf(']');
      return end > 0 ? target.substring(1, end) : target;
    }
    final colon = target.lastIndexOf(':');
    return colon > 0 ? target.substring(0, colon) : target;
  }
}

List<Conn> parseBoxLog(String text) => BoxLogParser().feed(text);

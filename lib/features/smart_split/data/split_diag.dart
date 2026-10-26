import 'dart:convert';
import 'dart:io';

import 'package:hiddify/features/log/data/log_path_resolver.dart';
import 'package:hiddify/features/smart_split/data/box_log_parser.dart';
import 'package:hiddify/features/smart_split/data/route_writer.dart';

/// 「好了」只说明隧道重新连上。这段说明这次规则写进去没有、重新打开网页之后实际走了哪边。
/// 只提用户自己改过的网址，不把别的浏览记录列出来。
String splitDiag({String? routeJson, String stderr = '', String boxLog = ''}) {
  final lines = <String>[];
  Map<String, dynamic>? root;
  if (routeJson == null || routeJson.trim().isEmpty) {
    lines.add('规则文件不在。内核用的还是上一次的。');
  } else {
    try {
      final decoded = jsonDecode(routeJson);
      if (decoded is Map<String, dynamic>) {
        root = decoded;
      } else {
        lines.add('规则文件坏了，内核会跳过。');
      }
    } catch (_) {
      lines.add('规则文件坏了，内核会跳过。');
    }
  }

  List<String> names(String key) {
    final v = root?[key];
    if (v is! List) return const [];
    return [for (final x in v) if (x is String && x.isNotEmpty) x];
  }

  final direct = root == null ? const <String>[] : names('user_direct');
  final proxy = root == null ? const <String>[] : names('user_proxy');
  if (root != null) {
    lines.add(direct.isEmpty ? '走本地：一个网址都没写进规则。' : '走本地：${_join(direct)}');
    if (proxy.isNotEmpty) lines.add('走光速雷达：${_join(proxy)}');
  }

  final skips = RegExp(r'\[gsl-route\] skip[^\n]*').allMatches(stderr).map((m) => m.group(0)!).toList();
  if (skips.isNotEmpty) {
    lines.add('内核没读成：${skips.last}');
  } else if (root != null) {
    lines.add('内核没有报读失败。');
  }

  final suffixes = [...direct, ...proxy];
  if (suffixes.isEmpty) return lines.join('\n');
  if (boxLog.trim().isEmpty) {
    lines.add('还没有连接日志。回浏览器把网页重新打开，再看一次。');
    return lines.join('\n');
  }

  final hits = <String, String>{};
  var ip = 0;
  var ech = 0;
  for (final c in BoxLogParser().feed(boxLog)) {
    final h = c.host.toLowerCase();
    if (suffixes.any((s) => h == s || h.endsWith('.$s'))) {
      hits[h] = c.outbound;
    } else if (_isIp(h)) {
      ip++;
    } else if (h == 'cloudflare-ech.com' || h.endsWith('.cloudflare-ech.com')) {
      ech++;
    }
  }
  if (hits.isEmpty) {
    lines.add('重新打开之后，上面这些网址一条都没出现。');
    if (ech > 0) lines.add('浏览器有 $ech 条连的是 cloudflare-ech.com，真域名被藏起来了，规则对不上。');
    if (ip > 0) lines.add('有 $ip 条只有 IP，没有域名，规则也对不上。');
  } else {
    lines.add('重新打开之后：');
    for (final e in hits.entries) {
      lines.add(e.value == 'direct' ? '${e.key} 走了本地。' : '${e.key} 仍走光速雷达。');
    }
  }
  return lines.join('\n');
}

String _join(List<String> xs) => xs.length <= 12 ? xs.join('、') : '${xs.take(12).join('、')} 等 ${xs.length} 个';

bool _isIp(String host) {
  if (host.contains(':')) return true;
  final parts = host.split('.');
  if (parts.length != 4) return false;
  return parts.every((p) {
    final n = int.tryParse(p);
    return n != null && n >= 0 && n <= 255 && '$n' == p;
  });
}

Future<String> _tail(File f) async {
  try {
    if (!f.existsSync()) return '';
    final len = await f.length();
    const maxBytes = 200 * 1024;
    final start = len > maxBytes ? len - maxBytes : 0;
    return f.openRead(start).transform(utf8.decoder).join();
  } catch (_) {
    return '';
  }
}

/// 读工作目录里的规则文件、内核报错、连接日志，拼成上面那段话。
Future<String> readSplitDiag(Directory workingDir) async {
  final route = File('${workingDir.path}/$gslRouteFile');
  if (route.existsSync() && await route.length() > 1024 * 1024) return '规则文件太大，读不了。';
  final stderr = StringBuffer();
  for (final name in ['stderr.log', 'stderr2.log']) {
    stderr.write(await _tail(File('${workingDir.path}/$name')));
  }
  return splitDiag(
    routeJson: route.existsSync() ? await route.readAsString() : null,
    stderr: stderr.toString(),
    boxLog: await _tail(File(LogPathResolver.corePath(workingDir))),
  );
}

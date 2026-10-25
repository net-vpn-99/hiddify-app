import 'dart:io';

import 'package:flutter/services.dart';
import 'package:hiddify/features/smart_split/model/thing_list.dart';

/// 名单存 `<baseDir>/split-things.json`（打开智能分流页、点「开始采集」时按版本号拉新的）；没有就用 App 里带的种子。
const splitThingsFile = 'split-things.json';

Future<ThingList?> loadThings(Directory baseDir) async {
  try {
    final f = File('${baseDir.path}/$splitThingsFile');
    if (f.existsSync()) {
      final saved = ThingList.parse(await f.readAsString());
      if (saved != null) return saved;
    }
    return ThingList.parse(await rootBundle.loadString('assets/split/things-seed.json'));
  } catch (_) {
    return null;
  }
}

Future<void> saveThings(Directory baseDir, String json) async {
  final f = File('${baseDir.path}/$splitThingsFile');
  final tmp = File('${f.path}.tmp');
  await tmp.writeAsString(json, flush: true);
  await tmp.rename(f.path);
}

import 'dart:convert';
import 'dart:io';

import 'package:hiddify/features/smart_split/data/box_log_parser.dart';
import 'package:hiddify/features/smart_split/model/classifier.dart';

/// 采集：从点「开始采集」那一刻起读 box.log 新增的部分。只在内存里，停止就清空。
/// 重连会把 box.log 清空重写（connect_reporter.dart），文件比读到的地方短就从头读，已采到的留着。
class Collector {
  Collector(this.boxLog);

  final File boxLog;

  /// 一次最多读这么多，box.log 很大时不卡界面，剩下的下次读。
  static const _maxRead = 2 * 1024 * 1024;

  var _offset = 0;
  var _running = false;
  var _parser = BoxLogParser();
  final _conns = <Conn>[];

  bool get running => _running;

  void start() {
    _conns.clear();
    _parser = BoxLogParser();
    _offset = _length();
    _running = true;
  }

  /// 我们自己重连了（选了以后要重连才生效）：box.log 从头重写，从头读。已采到的留着。
  void rewind() => _offset = 0;

  void stop() {
    _running = false;
    _conns.clear();
  }

  /// 读新增的部分，返回到现在为止采到的全部（按出现先后）。
  List<Conn> poll() {
    if (!_running) return const [];
    final len = _length();
    if (len < _offset) _offset = 0;
    if (len > _offset) {
      try {
        final raf = boxLog.openSync();
        try {
          raf.setPositionSync(_offset);
          final bytes = raf.readSync((len - _offset).clamp(0, _maxRead));
          // 最后半行先不读，等写完
          final end = bytes.lastIndexOf(10);
          if (end >= 0) {
            _conns.addAll(_parser.feed(utf8.decode(bytes.sublist(0, end + 1), allowMalformed: true)));
            _offset += end + 1;
          }
        } finally {
          raf.closeSync();
        }
      } catch (_) {
        // 读不了就等下次
      }
    }
    return List.unmodifiable(_conns);
  }

  int _length() {
    try {
      return boxLog.lengthSync();
    } catch (_) {
      return 0;
    }
  }
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/proxy/line/line_latency.dart';

/// 雷达测延迟规矩的自动测试：读 test/fixtures/latency_due_cases.json 跑 latencyDue / nextMisses。
/// 情况表跟 Windows 共用（VPN 仓库 ui/one-ray/tests/latency_due_cases.json，内容一模一样，Windows 测试会比对）。
/// 跑法：flutter test test/features/proxy/line_latency_rule_test.dart
void main() {
  final root = jsonDecode(File('test/fixtures/latency_due_cases.json').readAsStringSync()) as Map<String, dynamic>;

  for (final c in (root['due'] as List).cast<Map<String, dynamic>>()) {
    test('该不该测：${c['name']}', () {
      expect(
        latencyDue(
          same: c['same'] as bool,
          measuredAgoMs: c['measuredAgo'] as int,
          misses: c['misses'] as int,
          missedAgoMs: c['missedAgo'] as int,
        ),
        c['due'] as bool,
      );
    });
  }
  for (final c in (root['misses'] as List).cast<Map<String, dynamic>>()) {
    test('没测到几轮：${c['name']}', () {
      expect(
        nextMisses(
          any: c['any'] as bool,
          sameNet: c['sameNet'] as bool,
          lastHadResult: c['lastHadResult'] as bool,
          misses: c['misses'] as int,
        ),
        c['next'] as int,
      );
    });
  }
}

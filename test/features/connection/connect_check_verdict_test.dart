import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/connection/data/connect_check_verdict.dart';

/// 连接检查结论表的自动测试（docs/计划/连接检查.md 第六节，VPN 仓库）：读 test/fixtures/connect_check_cases.json，
/// 用假数据把每一种情况都跑一遍 concludeCheck，比结论编号、按钮、关键文案，再核对文案规矩。
/// 情况表跟 Windows 共用（VPN 仓库 ui/one-ray/tests/connect_check_cases.json，内容一模一样，Windows 测试会比对）。
/// 跑法：flutter test test/features/connection/connect_check_verdict_test.dart
void main() {
  final root = jsonDecode(File('test/fixtures/connect_check_cases.json').readAsStringSync()) as Map<String, dynamic>;
  final defaults = root['defaults'] as Map<String, dynamic>;
  final cases = (root['cases'] as List).cast<Map<String, dynamic>>();

  // 「net+ api- line+」→ rows。情况表写错（行名拼错、没写 + / -）直接算不对，不悄悄当成「不通过」
  const rowKeys = {'net', 'api', 'line', 'others', 'local', 'alt'};
  Map<String, String> parseRows(String code) {
    final rows = <String, String>{};
    for (final part in code.split(' ').where((x) => x.isNotEmpty)) {
      final key = part.substring(0, part.length - 1);
      final sign = part[part.length - 1];
      if ((sign != '+' && sign != '-') || !rowKeys.contains(key)) fail('情况表 rows 写错了：「$part」');
      rows[key] = sign == '+' ? 'ok' : 'fail';
    }
    return rows;
  }

  // 情况表里认识的字段（拼错的字段会被悄悄忽略，所以要查）
  final stepKeys = {...defaults.keys, 'rows', 'expect'};
  const expectKeys = {'result', 'primary', 'secondary', 'primaryText', 'title', 'body', 'bodyHas'};
  void checkKeys(Map<String, dynamic> obj, Set<String> known, String what) {
    final bad = obj.keys.where((k) => !known.contains(k)).toList();
    if (bad.isNotEmpty) fail('情况表 $what 里有不认识的字段 $bad');
  }
  String device(String s) => s.replaceAll('{device}', '手机');

  // 文案规矩（客户文案写法 / 计划书第十节）：不出技术词、不说中间态；有按钮就要有字，有字就要有动作。
  const banned = ['TCP', '端口', 'DNS', '毫秒', 'ms', '正在确认', '秒内', 'errno', '10013'];
  const acts = {'recheck', 'switch', 'routes', 'reconnect', 'contact', 'repair', 'vpn_settings', 'site', 'close'};
  List<String> copyProblems(CheckVerdict v) => [
        if (v.title.isEmpty || v.body.isEmpty) '标题或正文是空的',
        for (final text in [v.title, v.body, v.primaryText, v.secondaryText])
          for (final word in banned)
            if (text.contains(word)) '文案里有「$word」：$text',
        if (v.primaryAct.isEmpty || v.primaryText.isEmpty) '没有主按钮',
        if (v.secondaryAct.isEmpty != v.secondaryText.isEmpty) '次按钮有字没动作 / 有动作没字：${v.secondaryText} / ${v.secondaryAct}',
        for (final act in [v.primaryAct, v.secondaryAct])
          if (act.isNotEmpty && !acts.contains(act)) '不认识的按钮动作 $act',
        if (v.secondaryAct.isNotEmpty && v.secondaryAct == v.primaryAct) '主次按钮做同一件事 ${v.primaryAct}',
      ];

  test('情况表读得到、不是空的', () => expect(cases, isNotEmpty));

  test('情况表的 case 字段和 platforms 都写对了', () {
    for (final c in cases) {
      checkKeys(c, {'name', 'platforms', 'steps'}, 'case「${c['name']}」');
      for (final p in (c['platforms'] as List?)?.cast<String>() ?? const <String>[]) {
        expect(p, anyOf('windows', 'android'), reason: '「${c['name']}」platforms 写错了');
      }
    }
  });

  for (final c in cases) {
    final platforms = (c['platforms'] as List?)?.cast<String>();
    if (platforms != null && !platforms.contains('android')) continue;
    test(c['name'] as String, () {
      final history = CheckHistory();
      final steps = (c['steps'] as List).cast<Map<String, dynamic>>();
      for (var i = 0; i < steps.length; i++) {
        checkKeys(steps[i], stepKeys, 'step');
        checkKeys(steps[i]['expect'] as Map<String, dynamic>, expectKeys, 'expect');
        expect((steps[i]['expect'] as Map).containsKey('result'), isTrue, reason: '情况表这一步没写 expect.result');
        final s = {...defaults, ...steps[i]};
        final v = concludeCheck(
          CheckInput(
            rows: parseRows(s['rows'] as String),
            line: s['line'] as String,
            lineHost: s['lineHost'] as String,
            alt: s['alt'] as String,
            hasAlt: s['hasAlt'] as bool,
            fault: s['fault'] as String,
            connected: s['connected'] as bool,
            canRepair: s['canRepair'] as bool,
            attempt: s['attempt'] as int,
          ),
          history,
        );
        final where = steps.length > 1 ? '第 ${i + 1} 步' : '';
        expect(copyProblems(v), isEmpty, reason: '$where 文案规矩');
        final e = s['expect'] as Map<String, dynamic>;
        expect(v.result, e['result'], reason: '$where 结论');
        if (e.containsKey('primary')) expect(v.primaryAct, e['primary'], reason: '$where 主按钮');
        if (e.containsKey('secondary')) expect(v.secondaryAct, e['secondary'], reason: '$where 次按钮');
        if (e.containsKey('primaryText')) expect(v.primaryText, device(e['primaryText'] as String), reason: '$where 主按钮的字');
        if (e.containsKey('title')) expect(v.title, device(e['title'] as String), reason: '$where 标题');
        if (e.containsKey('body')) expect(v.body, device(e['body'] as String), reason: '$where 正文');
        if (e.containsKey('bodyHas')) expect(v.body, contains(device(e['bodyHas'] as String)), reason: '$where 正文');
      }
    });
  }
}

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/connection/data/connect_reporter.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/panel_auth/data/other_vpn.dart';
import 'package:hiddify/features/panel_auth/data/panel_api_base.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hiddify/features/proxy/line/line_isp.dart';
import 'package:hiddify/features/proxy/line/line_source.dart';
import 'package:hiddify/features/proxy/line/line_tier.dart';
import 'package:hiddify/features/proxy/model/node_display.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 连接检查（docs/计划/连接检查.md，VPN 仓库）：断开 / 连不上说不清原因时，他点「帮我查一查」，
/// 这里一项项真的去查，每项查出结果才打勾 / 打叉（不按秒数下结论，等系统给结论），全部查完按结论表
/// 出一句结论 + 主次按钮。Windows 同一套：ui/one-ray/src/connectcheck.cpp，两边一起改。
///
/// 检查项（同时开始）：
///   net    这台手机能上网          直接碰百度（本 App 不走 VPN）
///   api    光速雷达的服务器能连上    直接碰接口服务器
///   line   刚才那条线路有回应        直接碰线路的服务器
///   others 这条线路其他人用着正常吗   问服务器（api 通了才问；看不出来不显示）
///   local  没有别的 VPN 占着         系统里还有别的 VPN 在用
///   alt    换一条试试               line 不通或其他人也连不上时，碰推荐的那条
const _rowOrder = ['net', 'api', 'line', 'others', 'local', 'alt'];

class CheckRow {
  const CheckRow(this.text, this.state);

  final String text;

  /// run（查着）/ ok / fail
  final String state;
}

class ConnectCheckState {
  const ConnectCheckState({
    this.running = false,
    this.rows = const [],
    this.result = '',
    this.title = '',
    this.body = '',
    this.primaryText = '',
    this.primaryAct = '',
    this.secondaryText = '',
    this.secondaryAct = '',
    this.altName = '',
    this.report = '',
  });

  final bool running;
  final List<CheckRow> rows;

  /// 结论编号 R1~R11，查着时为空。
  final String result;
  final String title;
  final String body;

  /// 按钮：act = recheck / switch（换到推荐那条）/ routes（自己选线路）/ reconnect / contact / repair / vpn_settings / site / close
  final String primaryText;
  final String primaryAct;
  final String secondaryText;
  final String secondaryAct;

  /// 「换到 X」的 X（线路名）
  final String altName;

  /// 检查报告：联系客服时带上
  final String report;

  /// 未知情况（R10）：卡上带「查清后送会员时长」的小贴士
  bool get reward => result == 'R10';
}

final connectCheckProvider = NotifierProvider<ConnectCheckNotifier, ConnectCheckState>(ConnectCheckNotifier.new);

class _Line {
  const _Line(this.name, this.host, this.port);

  final String name;
  final String? host;
  final int? port;

  bool get checkable => host != null && host!.isNotEmpty && (port ?? 0) > 0;
}

class ConnectCheckNotifier extends Notifier<ConnectCheckState> {
  int _gen = 0;
  final Map<String, String> _rows = {}; // key → run / ok / fail（不显示的不在里面）
  final Map<String, int> _err = {};
  _Line? _line;
  _Line? _alt;
  String _fault = '';
  bool _connected = false;
  bool _canRepair = false;
  int _serverId = 0;
  String _supportReport = '';

  // 跨次记的：上一次的结论（R7 之后重连又不通 = R8；同一个结论连着第二次 = 客服升主按钮）
  String _lastResult = '';
  String _lastHost = '';
  int _lastAttempt = -1;
  int _attempt = 0;
  int _streak = 0;

  // 碰得到但不给回数据的线路（R8 记下）：换了一条还是这样 = 未知情况 R10
  final Set<String> _datalessHosts = {};

  @override
  ConnectCheckState build() => const ConnectCheckState();

  ConnectReporter get _reporter => ref.read(connectReporterProvider);

  /// [fault]：刚才失败的原因（Windows faultKind 同一套词），空 = 没失败、自己从「帮助与诊断」点进来的。
  /// [connected]：查的时候正连着。[canRepair]：「修复并重新连接」帮得上。
  Future<void> start({String fault = '', bool connected = false, bool canRepair = false}) async {
    final gen = ++_gen;
    _fault = fault;
    _connected = connected;
    _canRepair = canRepair;
    _serverId = 0;
    _rows
      ..clear()
      ..addAll({'net': 'run', 'api': 'run', 'local': 'run'});
    _err.clear();
    _publishRunning();

    _attempt = connectedSerial;
    final lineName = ref.read(Preferences.lastNodeName);
    var host = _reporter.lastNodeHost;
    var port = _reporter.lastNodePort;
    // 这次打开 App 还没连过（从「帮助与诊断」点进来）：按线路名到订阅里找它的服务器地址
    if (host == null && lineName.isNotEmpty) {
      final node = await _reporter.resolveNode(lineName);
      (host, port) = (node.host, node.port);
      if (gen != _gen) return;
    }
    _line = _Line(lineName, host, port);
    _alt = await _pickAlt(lineName);
    if (gen != _gen) return;
    if (_line!.checkable) _rows['line'] = 'run';
    _publishRunning();

    _probe(gen, 'net', 'www.baidu.com', 443);
    final api = Uri.tryParse(_reporter.primaryApiBase());
    _probe(gen, 'api', api?.host ?? '', api != null && api.hasPort ? api.port : 443);
    if (_line!.checkable) _probe(gen, 'line', _line!.host!, _line!.port!);
    final other = await OtherVpn.isActive();
    if (gen != _gen) return;
    _rows['local'] = other ? 'fail' : 'ok';
    _maybeFinish(gen);
  }

  void stop() {
    if (!state.running) return;
    _gen++;
    state = ConnectCheckState(rows: state.rows);
  }

  /// 查完点了「联系客服」：服务器那条记上；检查报告交给客服页，跟第一条消息一起发。
  void markContacted() {
    _supportReport = state.report;
    if (_serverId > 0) unawaited(_post({'id': _serverId}));
  }

  /// 客服页发第一条消息时取一次（取过就清掉）。
  String takeSupportReport() {
    final r = _supportReport;
    _supportReport = '';
    return r;
  }

  /// 推荐那条：跟刚才那条同一个国家、能用的（不维修、他用得了），按线路列表同一套排序（适合宽带在前，繁忙和维修中最后）；
  /// 同一个国家没有就用服务器排的第一条没在维修的。
  Future<_Line?> _pickAlt(String cur) async {
    try {
      final set = await ref.read(lineSetProvider.future);
      if (set.locked) return null;
      final acc = ref.read(panelAuthProvider).account;
      final tiers = ref.read(lineTierProvider);
      final proLocked = tiers.trial != 'pro' && tiers.trial != 'active';
      bool usable(LineOption o) =>
          o.name != cur && !(acc?.isLineDown(o.name) ?? false) && !(proLocked && tiers.isProName(o.name));
      final country = cur.isEmpty ? '' : lineCountry(cur);
      final same = set.lines.where((o) => usable(o) && country.isNotEmpty && lineCountry(o.name) == country).toList();
      final ordered = ispFitFirst(same, acc?.isp ?? '', last: acc?.busyLines ?? const {});
      final pick = ordered.firstOrNull ?? set.lines.where(usable).firstOrNull;
      if (pick == null) return null;
      final node = await _reporter.resolveNode(pick.name);
      return _Line(pick.name, node.host, node.port);
    } catch (_) {
      return null;
    }
  }

  void _probe(int gen, String key, String host, int port) {
    unawaited(() async {
      final r = host.isEmpty ? const <String, dynamic>{'ok': false} : await _reporter.probeTcp(host, port);
      if (gen != _gen) return;
      _rows[key] = r['ok'] == true ? 'ok' : 'fail';
      _err[key] = r['errno'] as int? ?? 0;
      if (key == 'api' && r['ok'] == true) _askOthers(gen);
      _maybeStartAlt(gen);
      _maybeFinish(gen);
    }());
  }

  Future<void> _askOthers(int gen) async {
    final line = _line;
    if (line == null || !line.checkable) return;
    _rows['others'] = 'run';
    _publishRunning();
    var s = 'unknown';
    try {
      final token = await ref.read(panelAuthProvider.notifier).currentToken();
      if (token != null && token.isNotEmpty) {
        final res = await PanelApiBase.dio().get<dynamic>(
          '/api/v1/user/gsl_connect/line_health',
          queryParameters: {'host': line.host, 'port': line.port},
          options: Options(headers: {'auth_data': token, 'Authorization': token}),
        );
        final data = res.data is Map ? (res.data as Map)['data'] : null;
        if (data is Map && (data['state'] == 'ok' || data['state'] == 'fail')) s = data['state'] as String;
      }
    } catch (_) {}
    if (gen != _gen) return;
    // 看不出来（没别人在用）：这一行不显示
    if (s == 'unknown') {
      _rows.remove('others');
    } else {
      _rows['others'] = s;
    }
    _maybeStartAlt(gen);
    _maybeFinish(gen);
  }

  /// 换一条试试：刚才那条没回应，或者其他人也连不上，才去碰推荐的那条（推荐「换到 X」之前先确认它有回应）。
  void _maybeStartAlt(int gen) {
    final alt = _alt;
    if (_rows.containsKey('alt') || alt == null || !alt.checkable) return;
    if (_rows['line'] != 'fail' && _rows['others'] != 'fail') return;
    _rows['alt'] = 'run';
    _probe(gen, 'alt', alt.host!, alt.port!);
  }

  bool _ok(String k) => _rows[k] == 'ok';
  bool _fail(String k) => _rows[k] == 'fail';

  void _publishRunning() {
    state = ConnectCheckState(running: true, rows: _rowList(), title: '正在帮你检查…', secondaryText: '停止检查', secondaryAct: 'close');
  }

  void _maybeFinish(int gen) {
    if (gen != _gen) return;
    if (_rows.values.contains('run')) {
      _publishRunning();
      return;
    }
    state = _conclude();
    unawaited(_post({
      'result': state.result,
      'rows': _rowsCode(),
      'fault': _fault,
      'node_tag': _line?.name ?? '',
      'node_host': _line?.host ?? '',
      'platform': 'android',
      'app_ver': ref.read(appInfoProvider).valueOrNull?.version ?? '',
      'report': state.report,
    }).then((id) {
      if (gen == _gen && id > 0) _serverId = id;
    }));
  }

  Future<int> _post(Map<String, dynamic> body) async {
    try {
      final token = await ref.read(panelAuthProvider.notifier).currentToken();
      if (token == null || token.isEmpty) return 0;
      final res = await PanelApiBase.dio().post<dynamic>(
        '/api/v1/user/gsl_connect/check',
        data: jsonEncode(body),
        options: Options(contentType: 'application/json', headers: {'auth_data': token, 'Authorization': token}),
      );
      final data = res.data is Map ? (res.data as Map)['data'] : null;
      return data is Map && data['id'] is num ? (data['id'] as num).toInt() : 0;
    } catch (_) {
      return 0;
    }
  }

  /// 结论表（docs/计划/连接检查.md 第六节），从上往下第一条对上的就是。文案只写在这里（Windows conclude() 同一张表）。
  ConnectCheckState _conclude() {
    final line = _line?.name ?? '';
    final alt = _alt?.name ?? '';
    final hasAlt = _alt != null;
    final lineChecked = _rows.containsKey('line');
    final switchText = hasAlt ? '换到 $alt' : '自己选线路';
    final switchAct = hasAlt ? 'switch' : 'routes';
    const contact = '联系客服';
    String r;
    String title;
    String body;
    String pText;
    String pAct;
    var sText = '';
    var sAct = '';

    if (!_ok('net') && !_ok('api')) {
      (r, title, body, pText, pAct) = ('R1', '这台手机没连上网', '不是线路的问题。网络恢复后，再点「重新检查」。', '重新检查', 'recheck');
    } else if (!_ok('api')) {
      (r, title, body, pText, pAct) =
          ('R2', '连不上光速雷达的服务器', '这台手机能上网。请稍后再点「重新检查」；一直这样的话，请到官网下载最新版。', '重新检查', 'recheck');
      (sText, sAct) = ('打开官网', 'site');
    } else if (_fail('local')) {
      (r, title, body, pText, pAct) = ('R3', OtherVpn.title, OtherVpn.message, '打开 VPN 设置', 'vpn_settings');
      (sText, sAct) = (contact, 'contact');
    } else if (_canRepair && _fault == 'engine_gone') {
      (r, title, body, pText, pAct) = ('R11', '光速雷达没能启动连接', '点「修复并重新连接」，再试一次。', '修复并重新连接', 'repair');
      (sText, sAct) = (contact, 'contact');
    } else if (_fault == 'reality_mismatch') {
      (r, title, body, pText, pAct) =
          ('R9', '这条线路暂时用不了', '这条线路的设置和服务器对不上，不是你的问题。请联系客服，我们来处理；你也可以先换一条线路。', switchText, switchAct);
      (sText, sAct) = (contact, 'contact');
    } else if (_fail('line') && _fail('others')) {
      (r, title, pText, pAct) =
          ('R4', '$line 出了问题', _ok('alt') ? switchText : '自己选线路', _ok('alt') ? switchAct : 'routes');
      body = '我们已经收到报警，正在处理。${_ok('alt') ? '你可以先换到 $alt。' : '你可以先换一条线路。'}';
      (sText, sAct) = (contact, 'contact');
    } else if (_fail('line') && !_fail('alt')) {
      // 推荐那条有回应（或者没有可推荐的）：是他到这条线路的网络暂时不通
      (r, title, pText, pAct) =
          ('R5', '你的网络连不上 $line', _ok('alt') ? switchText : '自己选线路', _ok('alt') ? switchAct : 'routes');
      body = _ok('alt') ? '换到 $alt 就能用。' : '换一条线路就能用。';
      (sText, sAct) = ('重新连接 $line', 'reconnect');
    } else if (_fail('line')) {
      (r, title, body, pText, pAct) =
          ('R6', '两条线路都没有回应', '光速雷达的服务器能连上，但两条线路都没有回应，换线路也没用。请点「联系客服」，我们帮你查。', contact, 'contact');
      (sText, sAct) = ('重新检查', 'recheck');
    } else {
      // 都碰得到。碰得到只说明线路的服务器在，证明不了它会给我们回数据，所以不说「都正常了」。
      final host = _line?.host ?? '';
      final sameAsLast = lineChecked && host == _lastHost;
      final otherDataless = lineChecked && _fault == 'dead_tunnel' && _datalessHosts.isNotEmpty && !_datalessHosts.contains(host);
      final againAfterR7 = _fault.isNotEmpty && _attempt != _lastAttempt && _lastResult == 'R7' && sameAsLast;
      if (_fault == 'egress_mismatch' || otherDataless || (againAfterR7 && _fault != 'dead_tunnel')) {
        (r, title, body, pText, pAct) = ('R10', '连接没有完成', '这次的情况我们还没见过。点「联系客服」，我们帮你查。', contact, 'contact');
        (sText, sAct) = ('重新检查', 'recheck');
      } else if (againAfterR7) {
        _datalessHosts.add(host);
        (r, title, pText, pAct) = ('R8', '$line 现在不通', switchText, switchAct);
        body = hasAlt ? '它能碰到，但不给光速雷达回数据。换到 $alt 就能用。' : '它能碰到，但不给光速雷达回数据。换一条线路就能用。';
        (sText, sAct) = (contact, 'contact');
      } else {
        r = 'R7';
        title = '检查没发现问题';
        final who = lineChecked ? '网络、光速雷达的服务器、$line' : '网络和光速雷达的服务器';
        if (_connected) {
          (body, pText, pAct) = ('$who都有回应。', '知道了', 'close');
        } else {
          (body, pText, pAct) = ('$who现在都有回应。刚才可能是临时断了一下，点「重新连接」试试。', '重新连接', 'reconnect');
          if (hasAlt) (sText, sAct) = (switchText, switchAct);
        }
      }
    }

    // 同一个结论连着第二次（照处理办法做了还是不行）：联系客服升成主按钮（现有规矩）
    // 只点「重新检查」（中间没有新的连接）不算一次：次数不加
    final same = r == _lastResult && (_line?.host ?? '') == _lastHost;
    _streak = !same ? 1 : (_attempt != _lastAttempt ? _streak + 1 : _streak);
    if (_streak >= 2 && (r == 'R4' || r == 'R5' || r == 'R8')) {
      (sText, sAct) = (pText, pAct);
      (pText, pAct) = (contact, 'contact');
    }
    _lastResult = r;
    _lastHost = _line?.host ?? '';
    _lastAttempt = _attempt;

    final rows = _rowList();
    final report = '连接检查 $r：$title｜刚才：${_fault.isEmpty ? '没失败，自己点的' : _fault}｜'
        '${rows.map((x) => '${x.state == 'ok' ? '✓' : '✗'} ${x.text}').join('；')}';
    return ConnectCheckState(
      rows: rows,
      result: r,
      title: title,
      body: body,
      primaryText: pText,
      primaryAct: pAct,
      secondaryText: sText,
      secondaryAct: sAct,
      altName: alt,
      report: report,
    );
  }

  String _rowText(String key) {
    final s = _rows[key];
    final run = s == 'run';
    final good = s == 'ok';
    final line = _line?.name ?? '';
    final alt = _alt?.name ?? '';
    return switch (key) {
      'net' => run ? '这台手机能不能上网' : (good ? '这台手机能上网' : '这台手机没连上网'),
      'api' => run ? '光速雷达的服务器能不能连上' : (good ? '光速雷达的服务器能连上' : '光速雷达的服务器连不上'),
      'line' => run ? '$line 有没有回应' : (good ? '$line 有回应' : '$line 没有回应'),
      'others' => run ? '$line 其他人用着怎么样' : (good ? '$line 其他人用着正常' : '$line 其他人也连不上'),
      'local' => run || good ? '没有别的 VPN 占着' : '手机上还开着别的 VPN',
      'alt' => run ? '换一条试试：$alt' : (good ? '换一条试试：$alt 有回应' : '$alt 也没有回应'),
      _ => '',
    };
  }

  List<CheckRow> _rowList() => [
        for (final k in _rowOrder)
          if (_rows.containsKey(k)) CheckRow(_rowText(k), _rows[k]!),
      ];

  /// 给服务器的每一行：net+ api+ line- others+ local+ alt+（+ 通过 / - 不通过；没查的不写）
  String _rowsCode() => [
        for (final k in _rowOrder)
          if (_rows[k] == 'ok' || _rows[k] == 'fail') '$k${_rows[k] == 'ok' ? '+' : '-'}',
      ].join(' ');
}

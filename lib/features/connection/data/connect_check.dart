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
///   local  没有别的 VPN 占着         系统里还有别的 VPN 在用（光速雷达自己连着 / 正在连时不查：那是我们自己）
///   alt    换一条试试               一开始就去碰推荐的那条，line 不通或其他人也连不上时才显示这一行
const _rowOrder = ['net', 'api', 'line', 'others', 'local', 'alt'];

/// 判「这台手机能不能上网」碰的那个国内地址（判没网、连接检查第 1 行都用它，Windows onlineProbeHost）。
const onlineProbeHost = 'www.baidu.com';

/// 线路设置对不上（REALITY 校验失败）时那句话，首页失败卡和连接检查共用（Windows realityMismatchCopy）。
const realityMismatchCopy = '这条线路的设置和服务器对不上，不是你的问题。请联系客服，我们来处理；你也可以先换一条线路';

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
  bool _running = false;
  final Map<String, String> _rows = {}; // key → run / ok / fail（不显示的不在里面）
  // 推荐那条一开始就去碰，结果先放这里，要显示时再放进 _rows（不用等前一行超时完再碰）；'' = 没有可推荐的
  String _altResult = '';
  _Line? _line;
  _Line? _alt;
  String _fault = '';
  bool _connected = false;
  bool _canRepair = false;
  int _attempt = 0;
  int _serverId = 0;
  bool _contacted = false; // 查完点了联系客服（客服页传好的诊断码才补到这次检查上）
  bool _contactPending = false; // 点了联系客服，服务器那条还没记上
  String _pendingDiag = ''; // 诊断码先到了，服务器那条还没记上
  String _supportReport = '';

  // 跨次记的（连接确认通了就清掉，resetHistory）：上一次的结论（R7 之后重连又不通 = R8；同一个结论连着第二次 = 客服升主按钮）
  String _lastResult = '';
  String _lastHost = '';
  int _lastAttempt = -1;
  int _streak = 0;

  // 碰得到但不给回数据的线路（R8 记下）：换了一条还是这样 = 未知情况 R10
  final Set<String> _datalessHosts = {};

  @override
  ConnectCheckState build() => const ConnectCheckState();

  ConnectReporter get _reporter => ref.read(connectReporterProvider);

  /// [fault]：刚才失败的原因（Windows faultKind 同一套词），空 = 没失败、自己从「帮助与诊断」点进来的。
  /// [connected]：查的时候正连着 / 正在连（结论不给「重新连接」，那一下会变成取消；也不查「别的 VPN」）。
  /// [canRepair]：「修复并重新连接」帮得上。
  Future<void> start({String fault = '', bool connected = false, bool canRepair = false}) async {
    final gen = ++_gen;
    _running = true;
    _fault = fault;
    _connected = connected;
    _canRepair = canRepair;
    _attempt = connectedSerial;
    _serverId = 0;
    _contacted = false;
    _contactPending = false;
    _pendingDiag = '';
    _altResult = '';
    _line = null;
    _alt = null;
    _rows
      ..clear()
      ..addAll({'net': 'run', 'api': 'run', 'local': 'run'});
    _publishRunning();

    // 不用等读线路：这两行先碰起来
    _probe(gen, 'net', onlineProbeHost, 443);
    final api = Uri.tryParse(_reporter.primaryApiBase());
    _probe(gen, 'api', api?.host ?? '', api != null && api.hasPort ? api.port : 443);
    unawaited(_checkLocal(gen));

    // 线路名和地址从同一份订阅里按名字找（找不到就不查这一行，不拿别的线路顶）
    final lineName = ref.read(Preferences.lastNodeName);
    final nodes = await _reporter.configNodes();
    if (gen != _gen) return;
    ({String tag, String? host, int? port})? find(String name) =>
        nodes.where((n) => splitNodeName(n.tag).name == name).firstOrNull;
    final cur = lineName.isEmpty ? null : find(lineName);
    final altName = await _pickAlt(lineName, cur?.host ?? '', (n) => find(n)?.host ?? '');
    if (gen != _gen) return;
    final altNode = altName.isEmpty ? null : find(altName);
    if (altNode != null) _alt = _Line(altName, altNode.host, altNode.port);
    // 从这里起到下面开始碰都是同步的：api 先通了的由下面 _ok('api') 那句去问，后通的由 _probe 去问，只问一次
    _line = _Line(lineName, cur?.host, cur?.port);

    if (_line!.checkable) {
      _rows['line'] = 'run';
      _probe(gen, 'line', _line!.host!, _line!.port!);
    }
    if (_alt?.checkable ?? false) {
      _altResult = 'run';
      _probe(gen, 'alt', _alt!.host!, _alt!.port!);
    }
    if (_ok('api')) unawaited(_askOthers(gen));
    _maybeFinish(gen);
  }

  void stop() {
    if (!_running) return;
    _gen++;
    _running = false;
    state = ConnectCheckState(rows: state.rows);
  }

  /// 连接确认通了：跨次记的那些清掉（「照做了还是不行」只算这一段，跟失败卡「连上就清零」一样，Windows resetHistory）。
  void resetHistory() {
    _lastResult = '';
    _lastHost = '';
    _lastAttempt = -1;
    _streak = 0;
    _datalessHosts.clear();
  }

  /// 查完点了「联系客服」：服务器那条记上（结果还没记上就等记上再补）；检查报告交给客服页，跟第一条消息一起发。
  void markContacted() {
    _supportReport = state.report;
    _contacted = true;
    _sendContacted();
  }

  void _sendContacted() {
    if (_serverId <= 0) {
      _contactPending = true;
      return;
    }
    _contactPending = false;
    unawaited(_post({'id': _serverId, 'contacted': true}));
  }

  /// 联系客服时传好的诊断码：补到服务器那条上（后台「连接检查 · 未知情况」靠它找诊断包）。
  /// 不是从检查结果点进客服的（[markContacted] 没叫过）就不补。
  void attachDiagCode(String code) {
    if (code.isEmpty || !_contacted) return;
    if (_serverId <= 0) {
      _pendingDiag = code;
      return;
    }
    _pendingDiag = '';
    unawaited(_post({'id': _serverId, 'diag_code': code}));
  }

  /// 客服页关掉了：检查报告和「这次是从检查点进来的」都清掉（之后从别处打开客服传的诊断码跟这次检查无关；
  /// Windows ContactDialog 关掉时同一处）。
  void supportClosed() {
    _supportReport = '';
    _contacted = false;
  }

  /// 客服页发第一条消息时取一次（取过就清掉）。
  String takeSupportReport() {
    final r = _supportReport;
    _supportReport = '';
    return r;
  }

  /// 推荐那条：跟刚才那条同一个国家、能用的（不维修、他用得了、不在同一台服务器上），按线路列表同一套排序
  /// （适合宽带在前，繁忙和维修中最后）；同一个国家没有就用服务器排的第一条能用的。
  /// 同一台服务器上的分节点一起好一起坏，碰它证明不了什么（Windows startCheck / sameCountryLines 同一套）。
  Future<String> _pickAlt(String cur, String curHost, String Function(String name) hostOf) async {
    try {
      final set = await ref.read(lineSetProvider.future);
      if (set.locked) return '';
      final acc = ref.read(panelAuthProvider).account;
      final tiers = ref.read(lineTierProvider);
      final proLocked = tiers.trial != 'pro' && tiers.trial != 'active';
      bool usable(LineOption o) =>
          o.name != cur &&
          !(acc?.isLineDown(o.name) ?? false) &&
          !(proLocked && tiers.isProName(o.name)) &&
          (curHost.isEmpty || hostOf(o.name) != curHost);
      final country = cur.isEmpty ? '' : lineCountry(cur);
      final same = set.lines.where((o) => usable(o) && country.isNotEmpty && lineCountry(o.name) == country).toList();
      final ordered = ispFitFirst(same, acc?.isp ?? '', last: acc?.busyLines ?? const {});
      return (ordered.firstOrNull ?? set.lines.where(usable).firstOrNull)?.name ?? '';
    } catch (_) {
      return '';
    }
  }

  /// 别的 VPN：光速雷达自己连着 / 正在连时系统里那个 VPN 就是我们，不算。
  Future<void> _checkLocal(int gen) async {
    final other = !_connected && await OtherVpn.isActive();
    if (gen != _gen || !_running) return;
    _rows['local'] = other ? 'fail' : 'ok';
    _maybeFinish(gen);
  }

  void _probe(int gen, String key, String host, int port) {
    unawaited(() async {
      final r = host.isEmpty ? const <String, dynamic>{'ok': false} : await _reporter.probeTcp(host, port);
      // 已经出结论了（没显示的推荐那条后回来）/ 停掉、重查了：扔掉
      if (gen != _gen || !_running) return;
      final s = r['ok'] == true ? 'ok' : 'fail';
      if (key == 'alt') {
        _altResult = s;
        if (_rows.containsKey('alt')) _rows['alt'] = s;
      } else {
        _rows[key] = s;
      }
      if (key == 'api' && s == 'ok' && _line != null) unawaited(_askOthers(gen));
      _maybeFinish(gen);
    }());
  }

  /// api 通了、线路也从订阅里找出来了才问（两件事谁后到谁来叫它，只叫一次）。
  Future<void> _askOthers(int gen) async {
    final line = _line;
    if (gen != _gen || !_running || line == null || !line.checkable) return;
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
    if (gen != _gen || !_running) return;
    // 看不出来（没别人在用）：这一行不显示
    if (s == 'unknown') {
      _rows.remove('others');
    } else {
      _rows['others'] = s;
    }
    _maybeFinish(gen);
  }

  bool _ok(String k) => _rows[k] == 'ok';
  bool _fail(String k) => _rows[k] == 'fail';

  void _publishRunning() {
    state = ConnectCheckState(running: true, rows: _rowList(), title: '正在帮你检查…', secondaryText: '停止检查', secondaryAct: 'close');
  }

  void _maybeFinish(int gen) {
    if (gen != _gen || !_running) return;
    // 换一条试试：刚才那条没回应，或者其他人也连不上，才显示这一行（推荐「换到 X」之前先确认它有回应）
    if (!_rows.containsKey('alt') && _altResult.isNotEmpty && (_fail('line') || _fail('others'))) {
      _rows['alt'] = _altResult;
    }
    // 线路还没从订阅里找出来，或者还有行在查：接着等
    if (_line == null || _rows.values.contains('run')) {
      _publishRunning();
      return;
    }
    _running = false;
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
      if (gen != _gen || id <= 0) return;
      _serverId = id;
      // 记上之前就点了联系客服 / 诊断码已经传好：现在补上
      if (_contactPending) _sendContacted();
      if (_pendingDiag.isNotEmpty) attachDiagCode(_pendingDiag);
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

  /// 结论表（docs/计划/连接检查.md 第六节），从上往下第一条对上的就是（Windows conclude() 同一张表、同一套文案）。
  ConnectCheckState _conclude() {
    final line = _line?.name ?? '';
    final alt = _alt?.name ?? '';
    final hasAlt = _alt != null;
    final lineChecked = _rows.containsKey('line');
    final failedBefore = _fault.isNotEmpty;
    final newAttempt = _attempt != _lastAttempt;
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

    if (_fail('local')) {
      // 先看本机：别的 VPN 占着时我们碰哪儿都可能不通，不能说成「没连上网」
      (r, title, body, pText, pAct) = ('R3', OtherVpn.title, OtherVpn.message, '打开 VPN 设置', 'vpn_settings');
      (sText, sAct) = (contact, 'contact');
    } else if (_canRepair && _fault == 'engine_gone') {
      (r, title, body, pText, pAct) = ('R11', '光速雷达没能启动连接', '点「修复并重新连接」，再试一次。', '修复并重新连接', 'repair');
      (sText, sAct) = (contact, 'contact');
    } else if (!_ok('net') && !_ok('api')) {
      (r, title, body, pText, pAct) = ('R1', '这台手机没连上网', '不是线路的问题。网络恢复后，再点「重新检查」。', '重新检查', 'recheck');
    } else if (!_ok('api')) {
      (r, title, body, pText, pAct) =
          ('R2', '连不上光速雷达的服务器', '这台手机能上网。请稍后再点「重新检查」；一直这样的话，请到官网下载最新版。', '重新检查', 'recheck');
      (sText, sAct) = ('打开官网', 'site');
    } else if (_fault == 'reality_mismatch') {
      (r, title, body, pText, pAct) = ('R9', '这条线路暂时用不了', realityMismatchCopy, switchText, switchAct);
      (sText, sAct) = (contact, 'contact');
    } else if (_fail('others') && (_fail('line') || failedBefore)) {
      // 其他人也连不上：刚才那条碰不到，或者碰得到但他刚才也没连成——是线路自己出了问题（不说「检查没发现问题」）
      (r, title, pText, pAct) =
          ('R4', '$line 出了问题', _ok('alt') ? switchText : '自己选线路', _ok('alt') ? switchAct : 'routes');
      body = '我们已经收到报警，正在处理。${_ok('alt') ? '你可以先换到 $alt。' : '你可以先换一条线路。'}';
      (sText, sAct) = (contact, 'contact');
    } else if (_fail('line') && !_fail('alt')) {
      // 推荐那条有回应（或者没有可推荐的）：是他到这条线路的网络暂时不通
      (r, title, pText, pAct) =
          ('R5', '你的网络连不上 $line', _ok('alt') ? switchText : '自己选线路', _ok('alt') ? switchAct : 'routes');
      body = _ok('alt') ? '换到 $alt 就能用。' : '换一条线路就能用。';
      // 正连着 / 正在连时不给「重新连接」（那一下会变成取消）
      if (!_connected) (sText, sAct) = ('重新连接 $line', 'reconnect');
    } else if (_fail('line')) {
      (r, title, body, pText, pAct) =
          ('R6', '两条线路都没有回应', '光速雷达的服务器能连上，但两条线路都没有回应，换线路也没用。请点「联系客服」，我们帮你查。', contact, 'contact');
      (sText, sAct) = ('重新检查', 'recheck');
    } else {
      // 都碰得到。碰得到只说明线路的服务器在，证明不了它会给我们回数据，所以不说「都正常了」。
      final host = _line?.host ?? '';
      final sameAsLast = lineChecked && host == _lastHost;
      final otherDataless = lineChecked && _fault == 'dead_tunnel' && _datalessHosts.isNotEmpty && !_datalessHosts.contains(host);
      // 上次查完是 R7，他照做重连了（中间有一次新的连接）还是一样
      final againAfterR7 = failedBefore && newAttempt && _lastResult == 'R7' && sameAsLast;
      // 上次已经是 R8、中间没再连过：重查还是 R8（不会退回「检查没发现问题」）
      final stillR8 = !newAttempt && _lastResult == 'R8' && sameAsLast;
      if (_fault == 'egress_mismatch' || otherDataless || (againAfterR7 && _fault != 'dead_tunnel')) {
        // 网页没经过线路却查不出原因 / 换了一条还是碰得到不回数据 / 照做了还是一样：我们还没见过
        (r, title, body, pText, pAct) = ('R10', '连接没有完成', '这次的情况我们还没见过。点「联系客服」，我们帮你查。', contact, 'contact');
        (sText, sAct) = ('重新检查', 'recheck');
      } else if (againAfterR7 || stillR8) {
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

    // 同一个结论连着第二次（照处理办法做了还是不行）：联系客服升成主按钮（现有规矩）。只点「重新检查」不算一次。
    final same = r == _lastResult && (_line?.host ?? '') == _lastHost;
    _streak = !same ? 1 : (newAttempt ? _streak + 1 : _streak);
    if (_streak >= 2 && (r == 'R4' || r == 'R5' || r == 'R8')) {
      (sText, sAct) = (pText, pAct);
      (pText, pAct) = (contact, 'contact');
    }
    _lastResult = r;
    _lastHost = _line?.host ?? '';
    _lastAttempt = _attempt;

    final rows = _rowList();
    // 检查报告（跟着他发给客服的第一条消息走，他自己也看得到）：结论 + 每一行查到的 + 编号（客服按编号找；Windows report() 同一格式）
    final report = '连接检查：$title｜${rows.map((x) => '${x.state == 'ok' ? '✓' : '✗'} ${x.text}').join('；')}｜编号 $r';
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

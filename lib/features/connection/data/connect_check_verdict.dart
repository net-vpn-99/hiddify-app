import 'package:hiddify/features/panel_auth/data/other_vpn.dart';

/// 连接检查的结论表（docs/计划/连接检查.md 第六节，VPN 仓库）：查到的几行 + 点之前知道的事 → 一句结论 + 主次按钮。
/// 只算、不碰网络不碰界面，ConnectCheckNotifier 查完调它；自动测试
/// （test/features/connection/connect_check_verdict_test.dart）用假数据把每一种情况都跑一遍，
/// 情况表 test/fixtures/connect_check_cases.json 跟 Windows 共用（ui/one-ray/src/connectverdict.cpp 同一张表）。

/// 线路设置对不上（REALITY 校验失败）时那句话，首页失败卡和连接检查共用（Windows FaultCopy::realityMismatchCopy）。
const realityMismatchCopy = '这条线路的设置和服务器对不上，不是你的问题。请联系客服，我们来处理；你也可以先换一条线路';

/// 查完那一刻的样子。[rows]：net / api / line / others / local / alt → ok / fail（还在查是 run，不显示的不在里面）。
class CheckInput {
  const CheckInput({
    required this.rows,
    this.line = '',
    this.lineHost = '',
    this.alt = '',
    this.hasAlt = false,
    this.fault = '',
    this.connected = false,
    this.canRepair = false,
    this.attempt = 0,
  });

  final Map<String, String> rows;
  final String line;
  final String lineHost;
  final String alt;
  final bool hasAlt;

  /// 刚才失败的原因（Windows faultKind 同一套词），空 = 没失败
  final String fault;

  /// 查的时候正连着 / 正在连
  final bool connected;

  /// 「修复并重新连接」帮得上
  final bool canRepair;

  /// 第几次连接（「照做了还是不行」要中间真有一次新的连接）
  final int attempt;
}

/// 跨次记的（连接确认通了就清掉）
class CheckHistory {
  String lastResult = '';
  String lastHost = '';
  int lastAttempt = -1;
  int streak = 0;

  /// 碰得到但不给回数据的线路（R8 记下）：换了一条还是这样 = 未知情况 R10
  final Set<String> datalessHosts = {};

  void reset() {
    lastResult = '';
    lastHost = '';
    lastAttempt = -1;
    streak = 0;
    datalessHosts.clear();
  }
}

class CheckVerdict {
  const CheckVerdict(this.result, this.title, this.body, this.primaryText, this.primaryAct, this.secondaryText, this.secondaryAct);

  /// R1~R11
  final String result;
  final String title;
  final String body;
  final String primaryText;
  final String primaryAct;
  final String secondaryText;
  final String secondaryAct;
}

/// 从上往下第一条对上的就是结论（顺序 R3 → R1 → R2 → R11（连接意外断了）→ R9 → R4 → R5 → R6 → R10 → R8 → R7；
/// Windows 在 R3 后面还多一条 R11（本机连接数用满，安卓没有这种），其余跟 Windows CheckVerdict::conclude
/// 同一张表、同一套文案）；会更新 [h]（上一次结论、连着几次、不回数据的线路）。
CheckVerdict concludeCheck(CheckInput i, CheckHistory h) {
  bool ok(String k) => i.rows[k] == 'ok';
  bool fail(String k) => i.rows[k] == 'fail';
  final line = i.line;
  final alt = i.alt;
  final lineChecked = i.rows.containsKey('line');
  final failedBefore = i.fault.isNotEmpty;
  final newAttempt = i.attempt != h.lastAttempt;
  final switchText = i.hasAlt ? '换到 $alt' : '自己选线路';
  final switchAct = i.hasAlt ? 'switch' : 'routes';
  const contact = '联系客服';
  String r;
  String title;
  String body;
  String pText;
  String pAct;
  var sText = '';
  var sAct = '';

  if (fail('local')) {
    // 先看本机：别的 VPN 占着时我们碰哪儿都可能不通，不能说成「没连上网」
    (r, title, body, pText, pAct) = ('R3', OtherVpn.title, OtherVpn.message, '打开 VPN 设置', 'vpn_settings');
    (sText, sAct) = (contact, 'contact');
  } else if (!ok('net') && !ok('api')) {
    (r, title, body, pText, pAct) = ('R1', '这台手机没连上网', '不是线路的问题。网络恢复后，再点「重新检查」。', '重新检查', 'recheck');
  } else if (!ok('api')) {
    (r, title, body, pText, pAct) =
        ('R2', '连不上光速雷达的服务器', '这台手机能上网。请稍后再点「重新检查」；一直这样的话，请到官网下载最新版。', '重新检查', 'recheck');
    (sText, sAct) = ('打开官网', 'site');
  } else if (i.canRepair && i.fault == 'engine_gone') {
    // 连接意外断了、网络和服务器都碰得到：是光速雷达自己的组件，修复帮得上（没联网时修复帮不上，上面先说）
    (r, title, body, pText, pAct) = ('R11', '光速雷达没能启动连接', '点「修复并重新连接」，再试一次。', '修复并重新连接', 'repair');
    (sText, sAct) = (contact, 'contact');
  } else if (i.fault == 'reality_mismatch') {
    (r, title, body, pText, pAct) = ('R9', '这条线路暂时用不了', realityMismatchCopy, switchText, switchAct);
    (sText, sAct) = (contact, 'contact');
  } else if (fail('others') && (fail('line') || failedBefore)) {
    // 其他人也连不上：刚才那条碰不到，或者碰得到但他刚才也没连成——是线路自己出了问题（不说「检查没发现问题」）
    (r, title, pText, pAct) = ('R4', '$line 出了问题', ok('alt') ? switchText : '自己选线路', ok('alt') ? switchAct : 'routes');
    body = '我们已经收到报警，正在处理。${ok('alt') ? '你可以先换到 $alt。' : '你可以先换一条线路。'}';
    (sText, sAct) = (contact, 'contact');
  } else if (fail('line') && !fail('alt')) {
    // 推荐那条有回应（或者没有可推荐的）：是他到这条线路的网络暂时不通
    (r, title, pText, pAct) = ('R5', '你的网络连不上 $line', ok('alt') ? switchText : '自己选线路', ok('alt') ? switchAct : 'routes');
    body = ok('alt') ? '换到 $alt 就能用。' : '换一条线路就能用。';
    // 正连着 / 正在连时不给「重新连接」（那一下会变成取消）
    if (!i.connected) (sText, sAct) = ('重新连接 $line', 'reconnect');
  } else if (fail('line')) {
    (r, title, body, pText, pAct) =
        ('R6', '两条线路都没有回应', '光速雷达的服务器能连上，但两条线路都没有回应，换线路也没用。请点「联系客服」，我们帮你查。', contact, 'contact');
    (sText, sAct) = ('重新检查', 'recheck');
  } else {
    // 都碰得到。碰得到只说明线路的服务器在，证明不了它会给我们回数据，所以不说「都正常了」。
    final host = i.lineHost;
    final sameAsLast = lineChecked && host == h.lastHost;
    final otherDataless = lineChecked && i.fault == 'dead_tunnel' && h.datalessHosts.isNotEmpty && !h.datalessHosts.contains(host);
    // 上次查完是 R7，他照做重连了（中间有一次新的连接）还是一样
    final againAfterR7 = failedBefore && newAttempt && h.lastResult == 'R7' && sameAsLast;
    // 上次已经是 R8：中间没再连过（只点重新检查），或者又照做重连了还是一样，都还是 R8（不会退回「检查没发现问题」）
    final afterR8 = h.lastResult == 'R8' && sameAsLast && (!newAttempt || failedBefore);
    if (i.fault == 'egress_mismatch' || otherDataless || ((againAfterR7 || (afterR8 && newAttempt)) && i.fault != 'dead_tunnel')) {
      // 网页没经过线路却查不出原因 / 换了一条还是碰得到不回数据 / 照做了还是一样：我们还没见过
      (r, title, body, pText, pAct) = ('R10', '连接没有完成', '这次的情况我们还没见过。点「联系客服」，我们帮你查。', contact, 'contact');
      (sText, sAct) = ('重新检查', 'recheck');
    } else if (againAfterR7 || afterR8) {
      h.datalessHosts.add(host);
      (r, title, pText, pAct) = ('R8', '$line 现在不通', switchText, switchAct);
      body = i.hasAlt ? '它能碰到，但不给光速雷达回数据。换到 $alt 就能用。' : '它能碰到，但不给光速雷达回数据。换一条线路就能用。';
      (sText, sAct) = (contact, 'contact');
    } else {
      r = 'R7';
      title = '检查没发现问题';
      final who = lineChecked ? '网络、光速雷达的服务器、$line' : '网络和光速雷达的服务器';
      if (i.connected) {
        (body, pText, pAct) = ('$who都有回应。', '知道了', 'close');
      } else {
        (body, pText, pAct) = ('$who现在都有回应。刚才可能是临时断了一下，点「重新连接」试试。', '重新连接', 'reconnect');
        if (i.hasAlt) (sText, sAct) = (switchText, switchAct);
      }
    }
  }

  // 同一个结论连着第二次（照处理办法做了还是不行）：联系客服升成主按钮（现有规矩）。只点「重新检查」不算一次。
  final same = r == h.lastResult && i.lineHost == h.lastHost;
  h.streak = !same ? 1 : (newAttempt ? h.streak + 1 : h.streak);
  if (h.streak >= 2 && (r == 'R4' || r == 'R5' || r == 'R8')) {
    (sText, sAct) = (pText, pAct);
    (pText, pAct) = (contact, 'contact');
  }
  h.lastResult = r;
  h.lastHost = i.lineHost;
  h.lastAttempt = i.attempt;
  return CheckVerdict(r, title, body, pText, pAct, sText, sAct);
}

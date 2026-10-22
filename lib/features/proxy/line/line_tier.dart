import 'dart:async';

import 'package:dio/dio.dart';
import 'package:hiddify/core/notification/in_app_notification_controller.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/core/utils/device_id.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/panel_auth/data/panel_api_base.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hiddify/features/proxy/line/line_isp.dart';
import 'package:hiddify/features/proxy/line/line_picker.dart';
import 'package:hiddify/features/proxy/line/line_source.dart';
import 'package:hiddify/features/proxy/model/node_display.dart';
import 'package:hiddify/features/purchase/notifier/purchase_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class ProLine {
  const ProLine({required this.name, required this.country, this.host = '', this.port = 0});
  final String name;
  final String country;
  final String host;
  final int port;
}

class LineTierState {
  const LineTierState({
    this.trial = '',
    this.seconds = 0,
    this.minutes = 60,
    this.proLines = const [],
    this.trialEnded = false,
    this.endedUnseen = false,
    this.upgrade = const {},
    this.endNote = '',
  });

  /// off / pro / active / used / no（不能领）/ can（能领，只在他点了精品线路、或购买页看了精品没买时问，运营 10-20）。
  final String trial;
  final int seconds;
  final int minutes;
  final List<ProLine> proLines;
  final bool trialEnded;

  /// 体验结束了、结束卡还没弹过（服务器记的，App 关着时结束的下次打开补弹一次）。
  final bool endedUnseen;

  /// 升级精品版月付要补多少：price_fen / credit_fen / pay_fen / std_days_after。不是标准版为空。
  final Map<String, dynamic> upgrade;

  /// 结束那一刻帮他做了什么（换到了哪条标准线路 / 断开了），给结束卡用。
  final String endNote;

  bool isProName(String name) {
    final head = splitNodeName(name).name;
    for (final line in proLines) {
      if (line.name == name || splitNodeName(line.name).name == head) return true;
    }
    return false;
  }

  LineTierState copyWith({
    String? trial,
    int? seconds,
    int? minutes,
    List<ProLine>? proLines,
    bool? trialEnded,
    bool? endedUnseen,
    Map<String, dynamic>? upgrade,
    String? endNote,
  }) {
    return LineTierState(
      trial: trial ?? this.trial,
      seconds: seconds ?? this.seconds,
      minutes: minutes ?? this.minutes,
      proLines: proLines ?? this.proLines,
      trialEnded: trialEnded ?? this.trialEnded,
      endedUnseen: endedUnseen ?? this.endedUnseen,
      upgrade: upgrade ?? this.upgrade,
      endNote: endNote ?? this.endNote,
    );
  }
}

final lineTierProvider = NotifierProvider<LineTierNotifier, LineTierState>(LineTierNotifier.new);

class LineTierNotifier extends Notifier<LineTierState> {
  Timer? _timer;
  String _prev = '';
  bool _endingNoted = false;   // 剩 5 分钟提示过了（每次体验一次）
  bool _endSeenSent = false;   // 结束卡弹过了、服务器还没回说看过

  @override
  LineTierState build() {
    ref.onDispose(() => _timer?.cancel());
    ref.listen(connectionNotifierProvider, (_, _) => _clearIfStdConnected());
    Future.microtask(refresh);
    return const LineTierState();
  }

  Future<void> refresh() async {
    final token = await ref.read(panelAuthProvider.notifier).currentToken();
    if (token == null || token.isEmpty) {
      state = state.copyWith(trial: '', proLines: const [], seconds: 0);
      return;
    }
    try {
      final res = await PanelApiBase.dio().get<dynamic>(
        '/api/v1/gsl_shop/line_tiers',
        options: Options(headers: {'auth_data': token, 'Authorization': token}),
      );
      final body = res.data;
      final data = (body is Map && body['data'] is Map) ? body['data'] as Map : null;
      if (data == null) return;
      final lines = <ProLine>[];
      final raw = data['pro_lines'];
      if (raw is List) {
        for (final row in raw) {
          if (row is! Map) continue;
          final name = '${row['name'] ?? ''}'.trim();
          if (name.isEmpty) continue;
          final port = row['port'];
          lines.add(ProLine(
            name: name,
            country: '${row['country'] ?? ''}'.trim(),
            host: '${row['host'] ?? ''}'.trim(),
            port: port is num ? port.toInt() : int.tryParse('$port') ?? 0,
          ));
        }
      }
      final trial = '${data['trial'] ?? ''}';
      final seconds = data['trial_seconds'] is num ? (data['trial_seconds'] as num).toInt() : 0;
      final minutes = data['trial_minutes'] is num ? (data['trial_minutes'] as num).toInt() : 60;
      final ended = _prev == 'active' && trial == 'used';
      if (data['trial_ended_unseen'] != true) _endSeenSent = false;
      _prev = trial;
      final up = data['upgrade'];
      // 先换好线路再更新状态：结束卡是看着 endedUnseen 弹的，那一刻就要有「换到了哪条」这句
      final note = ended ? await _leaveProLine() : null;
      state = state.copyWith(
        trial: trial,
        seconds: seconds,
        minutes: minutes <= 0 ? 60 : minutes,
        proLines: lines,
        trialEnded: ended || state.trialEnded,
        // 弹过、告诉过服务器了，服务器还没记上（seen 在路上 / 没发出去）：别再弹（Windows m_trialEndSeenSent 同一套）。
        endedUnseen: data['trial_ended_unseen'] == true && !_endSeenSent,
        upgrade: up is Map ? Map<String, dynamic>.from(up) : const {},
        endNote: note,
      );
      if (trial != 'active') {
        _endingNoted = false;
      } else if (!_endingNoted && seconds > 0 && seconds <= 300) {
        _endingNoted = true;
        ref.read(inAppNotificationControllerProvider).showInfoToast('精品线路体验还剩 ${(seconds / 60).ceil().clamp(1, 5)} 分钟');
      }
      _arm(trial);
      _clearIfStdConnected();
    } catch (_) {}
  }

  void _arm(String trial) {
    _timer?.cancel();
    if (trial != 'active') return;
    _timer = Timer.periodic(const Duration(seconds: 20), (_) => refresh());
  }

  /// 体验结束时正连着精品线路：换到同一个国家的标准线路接着用（不断网）；同一个国家没有就断开，让他自己选。
  /// 不换到别的国家：IP 突然换国家，ChatGPT 之类的账号容易被风控、封号（运营 10-20，Windows leaveProLine 同一套）。
  /// 返回给结束卡的那句话。
  Future<String> _leaveProLine() async {
    final name = ref.read(Preferences.lastNodeName);
    if (!state.isProName(name)) return '';
    final status = ref.read(connectionNotifierProvider).valueOrNull;
    // 正在连精品线路（还没连上）：不让它连上去用完就断，直接断开让他选标准线路（Windows leaveProLine 同一处）
    if (status is Connecting) {
      await ref.read(connectionNotifierProvider.notifier).abortConnection();
      return '精品线路已断开。选一条标准线路就能接着用。';
    }
    if (!(status?.isConnected ?? false)) return '';
    final country = lineCountry(splitNodeName(name).name);
    final isp = ref.read(panelAuthProvider).account?.isp ?? '';
    final down = ref.read(panelAuthProvider).account?.downLines ?? const <String>{};
    LineOption? pick;
    try {
      final set = await ref.read(lineSetProvider.future);
      final same = set.lines
          .where((o) => !state.isProName(o.name) && !down.contains(o.name) && lineCountry(o.name) == country)
          .toList();
      pick = ispFitFirst(same, isp, last: ref.read(panelAuthProvider).account?.busyLines ?? const {}).firstOrNull;
    } catch (_) {}
    if (pick == null) {
      await ref.read(connectionNotifierProvider.notifier).toggleConnection();
      return '精品线路已断开。选一条标准线路就能接着用。';
    }
    await rememberLine(ref.read, pick);
    return '已经帮你换到同一个国家的标准线路「${pick.name}」，网络没断。';
  }

  /// 购买页看了精品没买退出时问「先免费试」：每个账号只问一次（他在别处选过「直接升级」也算问过）。
  bool shopAsked() {
    final prefs = ref.read(sharedPreferencesProvider).valueOrNull;
    return prefs == null || (prefs.getBool(_shopAskKey()) ?? false);
  }

  Future<void> markShopAsked() async {
    await ref.read(sharedPreferencesProvider).valueOrNull?.setBool(_shopAskKey(), true);
  }

  // 按账号编号记（免注册号没有邮箱，按邮箱记会让这台手机上的免注册号共用一个记号；Windows takeShopTrialAsk 同一套）。
  String _shopAskKey() {
    final auth = ref.read(panelAuthProvider);
    return 'pro_trial_shop_asked_${auth.accountNo ?? (auth.account?.email ?? '').toLowerCase()}';
  }

  /// 体验结束卡弹过了：告诉服务器（没报上去下次刷新还会再弹一次，不要紧）。
  Future<void> markEndSeen() async {
    if (!state.endedUnseen) return;
    state = state.copyWith(endedUnseen: false);
    _endSeenSent = true;
    final token = await ref.read(panelAuthProvider.notifier).currentToken();
    if (token == null || token.isEmpty) return;
    try {
      await PanelApiBase.dio().post<dynamic>(
        '/api/v1/gsl_shop/pro_trial/seen',
        options: Options(headers: {'auth_data': token, 'Authorization': token}),
      );
    } catch (_) {}
  }

  void _clearIfStdConnected() {
    if (!state.trialEnded) return;
    final connected = ref.read(connectionNotifierProvider).valueOrNull?.isConnected ?? false;
    if (!connected) return;
    final name = ref.read(Preferences.lastNodeName);
    if (name.isNotEmpty && !state.isProName(name)) {
      state = state.copyWith(trialEnded: false);
    }
  }

  /// 领取成功返回 null，失败返回要给用户看的那句话。
  /// [why]：tap_line（点了锁着的精品线路）/ shop_view（购买页看了精品没买）。只给想试的人（运营 10-20）。
  Future<String?> claim(String why) async {
    final token = await ref.read(panelAuthProvider.notifier).currentToken();
    if (token == null || token.isEmpty) return '请先登录';
    final device = await DeviceId.read() ?? '';
    try {
      final res = await PanelApiBase.dio().post<dynamic>(
        '/api/v1/gsl_shop/pro_trial/claim',
        data: {'device_id': device, 'why': why},
        options: Options(headers: {'auth_data': token, 'Authorization': token}),
      );
      final body = res.data;
      if ((res.statusCode ?? 0) >= 400) {
        final msg = body is Map ? body['message'] : null;
        return msg is String && msg.isNotEmpty ? msg : '领不了';
      }
      await refresh();
      // 线路列表读的是本地订阅文件。领完不重拉的话，精品线路既不出现也连不上。
      await refreshAccountSubscription(ref);
      return null;
    } catch (_) {
      return '领不了';
    }
  }
}

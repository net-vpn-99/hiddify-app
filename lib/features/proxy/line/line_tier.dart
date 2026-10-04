import 'dart:async';

import 'package:dio/dio.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/utils/device_id.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/panel_auth/data/panel_api_base.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
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
  });

  final String trial;
  final int seconds;
  final int minutes;
  final List<ProLine> proLines;
  final bool trialEnded;

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
  }) {
    return LineTierState(
      trial: trial ?? this.trial,
      seconds: seconds ?? this.seconds,
      minutes: minutes ?? this.minutes,
      proLines: proLines ?? this.proLines,
      trialEnded: trialEnded ?? this.trialEnded,
    );
  }
}

final lineTierProvider = NotifierProvider<LineTierNotifier, LineTierState>(LineTierNotifier.new);

class LineTierNotifier extends Notifier<LineTierState> {
  Timer? _timer;
  String _prev = '';

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
      _prev = trial;
      state = state.copyWith(
        trial: trial,
        seconds: seconds,
        minutes: minutes <= 0 ? 60 : minutes,
        proLines: lines,
        trialEnded: ended || state.trialEnded,
      );
      if (ended) await _dropProLine();
      _arm(trial);
      _clearIfStdConnected();
    } catch (_) {}
  }

  void _arm(String trial) {
    _timer?.cancel();
    if (trial != 'active') return;
    _timer = Timer.periodic(const Duration(seconds: 20), (_) => refresh());
  }

  Future<void> _dropProLine() async {
    final name = ref.read(Preferences.lastNodeName);
    if (!state.isProName(name)) return;
    final connected = ref.read(connectionNotifierProvider).valueOrNull?.isConnected ?? false;
    if (!connected) return;
    await ref.read(connectionNotifierProvider.notifier).toggleConnection();
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
  Future<String?> claim() async {
    final token = await ref.read(panelAuthProvider.notifier).currentToken();
    if (token == null || token.isEmpty) return '请先登录';
    final device = await DeviceId.read() ?? '';
    try {
      final res = await PanelApiBase.dio().post<dynamic>(
        '/api/v1/gsl_shop/pro_trial/claim',
        data: {'device_id': device},
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

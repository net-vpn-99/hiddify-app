import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/model/node_display.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 线路远近，只给首页雷达摆光点用（跟 Windows `RouteListModel::measureLatencies` /
/// `applyBadgesAndSort` 同一套）：直连每条线路的端口握手 3 次取最快，再跟测得最快的那条比着分级
/// —— 1 最快、2 较快、3 一般、4 偏慢；没测到不在表里（不写「连不上」：隧道开着时直连探测常常全超时）。
/// 界面上不写毫秒、不写快慢字，也没有「测速」按钮（10-23 运营：自己网络慢会以为是我们的问题）。
/// 12 分钟内、同一个网络测过就不再测。一条都没测到（断网、刚换网还连不出去）不算测过、雷达照旧，
/// 隔 30 秒再测，连着 3 轮没测到就等 12 分钟。换了网络重测（新结果出来前雷达照旧，不闪）；App 在后台不看网络、不测。
class LineLatencyState {
  const LineLatencyState({this.levels = const {}});

  /// 线路名 → 1～4。
  final Map<String, int> levels;
}

final lineLatencyProvider = NotifierProvider<LineLatencyNotifier, LineLatencyState>(LineLatencyNotifier.new);

class LineLatencyNotifier extends Notifier<LineLatencyState> {
  Timer? _watch;
  bool _running = false;
  // 测的时候又有人叫（线路刷新了）：这一轮完了再来一次，免得新线路要等 12 分钟。
  bool _again = false;
  // 上一轮测的时候在哪个网络（null = 还没测过）、什么时候测到的。
  String? _net;
  DateTime? _measuredAt;
  // 上一轮测的是哪些线路（排好序的「地址:端口」）：换号、加了节点也要重测，不等 12 分钟。
  String _key = '';
  // 在这个网络上连着几轮一条都没测到、最后一轮是什么时候。
  int _misses = 0;
  DateTime? _missedAt;

  @override
  LineLatencyState build() {
    _watch = Timer.periodic(const Duration(seconds: 8), (_) => _tick());
    ref.onDispose(() => _watch?.cancel());
    return const LineLatencyState();
  }

  /// 雷达出来、线路变了、连接状态变了时叫；后台每 8 秒也叫（[tick]，只看网络和时间，不读订阅）。
  /// 该不该测只在 [_due] 和线路清单两处判断。
  Future<void> ensure({bool tick = false}) async {
    if (_running) {
      if (!tick) _again = true;
      return;
    }
    _running = true;
    try {
      final net = await _netKey();
      if (tick && !_due(net == _net)) return;
      final targets = await _targets();
      final key = (targets.map((t) => '${t.host.toLowerCase()}:${t.port}').toList()..sort()).join(',');
      if (targets.isEmpty) {
        // 没有线路（退出登录了）：不留上一个号的结果，8 秒巡检也停（跟 Windows 退出登录一样）。
        _net = null;
        _key = '';
        _measuredAt = null;
        _misses = 0;
        _missedAt = null;
        state = const LineLatencyState();
        return;
      }
      if (!_due(net == _net && key == _key)) return;
      final ms = List<int>.filled(targets.length, -1);
      var next = 0;
      Future<void> worker() async {
        while (true) {
          final i = next++;
          if (i >= targets.length) return;
          var best = -1;
          for (var attempt = 0; attempt < 3; attempt++) {
            final r = await _probe(targets[i].host, targets[i].port);
            if (r > 0 && (best < 0 || r < best)) best = r;
          }
          ms[i] = best;
        }
      }

      await Future.wait([for (var i = 0; i < (targets.length < 6 ? targets.length : 6); i++) worker()]);
      final levels = _grade(targets, ms);
      if (levels.isEmpty) {
        _misses = nextMisses(any: false, sameNet: net == _net, lastHadResult: _measuredAt != null, misses: _misses);
        _missedAt = DateTime.now();
        _measuredAt = null;
        _net = net;
        _key = key;
        return;
      }
      _misses = 0;
      _measuredAt = DateTime.now();
      _net = net;
      _key = key;
      state = LineLatencyState(levels: levels);
    } catch (_) {
      // 读不到订阅就当这次没测，下次再来。
    } finally {
      _running = false;
      if (_again) {
        _again = false;
        unawaited(ensure());
      }
    }
  }

  /// 规矩在 [latencyDue]（两端共用情况表）；这里只把上一轮记下的东西喂进去。
  bool _due(bool same) {
    final now = DateTime.now();
    final at = _measuredAt;
    final missed = _missedAt;
    return latencyDue(
      same: same,
      measuredAgoMs: at == null ? -1 : now.difference(at).inMilliseconds,
      misses: _misses,
      missedAgoMs: missed == null ? -1 : now.difference(missed).inMilliseconds,
    );
  }

  void _tick() {
    final life = WidgetsBinding.instance.lifecycleState;
    if (_net == null || (life != null && life != AppLifecycleState.resumed)) return;
    unawaited(ensure(tick: true));
  }

  Future<List<({String host, int port, List<String> names})>> _targets() async {
    final byKey = <String, ({String host, int port, List<String> names})>{};
    void add(String name, String host, int port) {
      final clean = host.trim();
      if (name.isEmpty || clean.isEmpty || port <= 0) return;
      final key = '${clean.toLowerCase()}:$port';
      final existing = byKey[key];
      if (existing == null) {
        byKey[key] = (host: clean, port: port, names: [name]);
      } else if (!existing.names.contains(name)) {
        existing.names.add(name);
      }
    }

    final profile = await ref.read(activeProfileProvider.future);
    if (profile != null) {
      final repo = await ref.read(profileRepositoryProvider.future);
      final raw = await repo.getRawConfig(profile.id).getOrElse((_) => '').run();
      for (final row in _profileEndpoints(raw)) {
        add(row.name, row.host, row.port);
      }
    }
    return byKey.values.toList();
  }
}

class _ProfileEndpoint {
  const _ProfileEndpoint(this.name, this.host, this.port);
  final String name;
  final String host;
  final int port;
}

List<_ProfileEndpoint> _profileEndpoints(String raw) {
  final out = <_ProfileEndpoint>[];
  try {
    final obj = jsonDecode(raw.trim());
    if (obj is Map && obj['outbounds'] is List) {
      for (final ob in obj['outbounds'] as List) {
        if (ob is! Map) continue;
        final tag = '${ob['tag'] ?? ''}'.trim();
        final host = '${ob['server'] ?? ''}'.trim();
        final port = ob['server_port'];
        final n = port is num ? port.toInt() : int.tryParse('$port') ?? 0;
        if (tag.isEmpty || host.isEmpty || n <= 0) continue;
        out.add(_ProfileEndpoint(splitNodeName(tag).name, host, n));
        out.add(_ProfileEndpoint(tag, host, n));
      }
    }
  } catch (_) {}
  return out;
}

/// 跟测得最快的那条比，带一个绝对下限：美国线路离国内谁都是 180 毫秒上下，照样好用，
/// 正在用的线路不能因为远一点就被摆到最外圈。
Map<String, int> _grade(List<({String host, int port, List<String> names})> targets, List<int> ms) {
  var fastest = -1;
  for (var i = 0; i < ms.length; i++) {
    if (ms[i] > 0 && (fastest < 0 || ms[i] < ms[fastest])) fastest = i;
  }
  final levels = <String, int>{};
  if (fastest < 0) return levels;
  final best = ms[fastest];
  for (var i = 0; i < targets.length; i++) {
    final m = ms[i];
    if (m <= 0) continue;
    final ratio = m / best;
    final level = i == fastest
        ? 1
        : (m <= 260 || ratio <= 1.8)
        ? 2
        : (m <= 500 || ratio <= 3.5)
        ? 3
        : 4;
    for (final name in targets[i].names) {
      levels[name] = level;
    }
  }
  return levels;
}

/// 雷达测延迟该不该测，跟 Windows `ui/one-ray/src/latencyrule.h` 同一套，情况表两端共用
/// （test/fixtures/latency_due_cases.json，VPN 仓库 ui/one-ray/tests 里一模一样一份）。
/// [same]：网络和线路清单都跟上一轮一样。[measuredAgoMs]：上一轮测到离现在多久，没测到过 = -1。
/// [missedAgoMs]：上一轮没测到离现在多久，没有 = -1。测到过：12 分钟内不再测；一条都没测到：隔 30 秒再测，
/// 连着 3 轮没测到就等 12 分钟。
bool latencyDue({required bool same, required int measuredAgoMs, required int misses, required int missedAgoMs}) {
  const cacheMs = 12 * 60 * 1000;
  if (!same) return true;
  if (measuredAgoMs >= 0) return measuredAgoMs >= cacheMs;
  if (missedAgoMs < 0) return true;
  return missedAgoMs >= (misses >= 3 ? cacheMs : 30 * 1000);
}

/// 这一轮测完以后连着没测到几轮：测到了清零；换了网络、或上一轮测到过，从 1 数起。
int nextMisses({required bool any, required bool sameNet, required bool lastHadResult, required int misses}) {
  if (any) return 0;
  return sameNet && !lastHadResult ? misses + 1 : 1;
}

/// 先解析域名再计时，只量握手（跟 Windows ProbeTcpBoundMs 一样，解析出来以后才开始算）。
Future<int> _probe(String host, int port) async {
  try {
    // 只测 IPv4（跟 Windows 一样，Windows 解析也只要 IPv4）。
    final literal = InternetAddress.tryParse(host);
    if (literal != null && literal.type != InternetAddressType.IPv4) return -1;
    final addr =
        literal ??
        (await InternetAddress.lookup(
          host,
          type: InternetAddressType.IPv4,
        ).timeout(const Duration(milliseconds: 1200))).first;
    final watch = Stopwatch()..start();
    final socket = await Socket.connect(addr, port, timeout: const Duration(milliseconds: 1200));
    socket.destroy();
    final ms = watch.elapsedMilliseconds;
    return ms <= 0 ? 1 : ms;
  } catch (_) {
    return -1;
  }
}

/// VPN 网卡不算「换了网络」。连上隧道会多出一块 tun，不能因此把刚测的结果清掉。
bool _isVpnInterface(String name) {
  final n = name.toLowerCase();
  return n.startsWith('tun') || n.startsWith('ppp') || n.startsWith('ipsec') || n.startsWith('wg');
}

/// 只比 IPv4：手机数据网的 IPv6 临时地址隔一阵就换、只有 IPv6 的网卡（IMS 之类）会来回出现，都不是换了网络。
Future<String> _netKey() async {
  try {
    final list = await NetworkInterface.list();
    final parts = <String>[];
    for (final iface in list) {
      if (_isVpnInterface(iface.name)) continue;
      final addrs = iface.addresses.where((a) => a.type == InternetAddressType.IPv4).map((a) => a.address).join(',');
      if (addrs.isEmpty) continue;
      parts.add('${iface.name}:$addrs');
    }
    parts.sort();
    return parts.join('|');
  } catch (_) {
    return '';
  }
}

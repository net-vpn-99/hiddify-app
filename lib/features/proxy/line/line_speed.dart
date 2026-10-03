import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hiddify/core/model/remote_site_config.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/line/line_tier.dart';
import 'package:hiddify/features/proxy/model/node_display.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class SpeedGrade {
  const SpeedGrade({required this.level, required this.word, required this.ms});

  /// 1 快 / 2 一般 / 3 慢 / 4 不通。
  final int level;
  final String word;
  final int ms;
}

class LineSpeedState {
  const LineSpeedState({
    this.grades = const {},
    this.running = false,
    this.done = 0,
    this.total = 0,
    this.finished,
    this.bestName = '',
  });

  final Map<String, SpeedGrade> grades;
  final bool running;
  final int done;
  final int total;
  final DateTime? finished;
  final String bestName;

  String get stamp {
    if (running || finished == null) return '';
    final minutes = DateTime.now().difference(finished!).inMinutes;
    if (minutes < 1) return '刚刚测的';
    return '$minutes 分钟前测的';
  }

  LineSpeedState copyWith({
    Map<String, SpeedGrade>? grades,
    bool? running,
    int? done,
    int? total,
    DateTime? finished,
    String? bestName,
    bool clearFinished = false,
  }) {
    return LineSpeedState(
      grades: grades ?? this.grades,
      running: running ?? this.running,
      done: done ?? this.done,
      total: total ?? this.total,
      finished: clearFinished ? null : (finished ?? this.finished),
      bestName: bestName ?? this.bestName,
    );
  }
}

final lineSpeedProvider = NotifierProvider<LineSpeedNotifier, LineSpeedState>(LineSpeedNotifier.new);

class LineSpeedNotifier extends Notifier<LineSpeedState> {
  Timer? _watch;
  String _net = '';
  int _serial = 0;

  @override
  LineSpeedState build() {
    _watch = Timer.periodic(const Duration(seconds: 8), (_) => _checkNet());
    ref.onDispose(() => _watch?.cancel());
    return const LineSpeedState();
  }

  Future<void> start() async {
    if (state.running) return;
    final targets = await _targets();
    if (targets.isEmpty) return;
    final net = await _netKey();
    _net = net;
    final serial = ++_serial;
    state = LineSpeedState(running: true, total: targets.length);
    final jitterMs = RemoteSiteConfig.speedJitterMs;
    final jitterPct = RemoteSiteConfig.speedJitterPct;
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    final grades = <String, SpeedGrade>{};
    var done = 0;
    var next = 0;
    Future<void> worker() async {
      while (serial == _serial) {
        final i = next;
        next++;
        if (i >= targets.length) return;
        final item = targets[i];
        final grade = await _measure(item.host, item.port, deadline, jitterMs, jitterPct);
        if (serial != _serial) return;
        for (final name in item.names) {
          grades[name] = grade;
        }
        done++;
        state = state.copyWith(grades: Map.of(grades), done: done);
      }
    }

    await Future.wait([for (var i = 0; i < 4 && i < targets.length; i++) worker()]);
    if (serial != _serial) return;
    var bestName = '';
    var bestMs = -1;
    var bestLevel = 0;
    for (final item in targets) {
      final grade = grades[item.names.first];
      if (grade == null || grade.ms <= 0) continue;
      if (grade.level != 1 && grade.level != 2) continue;
      if (bestLevel == 0 || grade.level < bestLevel || (grade.level == bestLevel && grade.ms < bestMs)) {
        bestLevel = grade.level;
        bestMs = grade.ms;
        bestName = item.names.first;
      }
    }
    state = state.copyWith(running: false, finished: DateTime.now(), bestName: bestName, grades: Map.of(grades));
  }

  Future<void> _checkNet() async {
    if (state.finished == null && !state.running) return;
    final net = await _netKey();
    if (_net.isNotEmpty && net != _net) {
      _serial++;
      _net = net;
      state = const LineSpeedState();
    }
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
    for (final line in ref.read(lineTierProvider).proLines) {
      add(splitNodeName(line.name).name, line.host, line.port);
      add(line.name, line.host, line.port);
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

Future<SpeedGrade> _measure(String host, int port, DateTime deadline, int jitterMs, int jitterPct) async {
  final samples = <int>[];
  var fails = 0;
  var finished = true;
  for (var i = 0; i < 5; i++) {
    final left = deadline.difference(DateTime.now());
    if (left.inMilliseconds < 50) {
      finished = false;
      break;
    }
    final ms = await _probe(host, port, left.inMilliseconds < 2000 ? left : const Duration(seconds: 2));
    if (ms < 0) {
      fails++;
    } else {
      samples.add(ms);
    }
    if (i < 4) await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  if (!finished && samples.length < 2) return const SpeedGrade(level: 5, word: '没测完', ms: -1);
  if (samples.isEmpty) return const SpeedGrade(level: 4, word: '连不上', ms: -1);
  samples.sort();
  final median = samples[samples.length ~/ 2];
  final jitter = samples.last - samples.first;
  final steady = jitter <= jitterMs || (median > 0 && jitter * 100 <= median * jitterPct);
  final int level;
  if (fails >= 2) {
    level = 3;
  } else if (fails == 0 && steady) {
    level = 1;
  } else {
    level = 2;
  }
  const words = {1: '稳定', 2: '有波动', 3: '容易卡', 4: '连不上'};
  return SpeedGrade(level: level, word: words[level] ?? '连不上', ms: median);
}

Future<int> _probe(String host, int port, Duration timeout) async {
  final watch = Stopwatch()..start();
  try {
    final socket = await Socket.connect(host, port, timeout: timeout);
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

Future<String> _netKey() async {
  try {
    final list = await NetworkInterface.list();
    final parts = <String>[];
    for (final iface in list) {
      if (_isVpnInterface(iface.name)) continue;
      final addrs = iface.addresses.map((a) => a.address).join(',');
      parts.add('${iface.name}:$addrs');
    }
    parts.sort();
    return parts.join('|');
  } catch (_) {
    return '';
  }
}

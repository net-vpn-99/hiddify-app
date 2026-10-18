import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/theme/oneray_tokens.dart';
import 'package:hiddify/features/proxy/line/line_isp.dart';
import 'package:hiddify/features/proxy/line/line_source.dart';
import 'package:hiddify/features/proxy/line/line_speed.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 雷达状态，跟 Windows RadarScope 的 visualState 一一对应。
enum RadarState { off, connecting, connected, failed }

/// 主页雷达（B 夜航 §3.5，跟 Windows `RadarScope.qml` 同一套规矩）：
/// 每个光点是一条线路，按快 / 中 / 慢三圈摆（line_speed 的分级：1 快 → 内圈，2 一般 → 中圈，
/// 3 慢 / 4 不通 / 没测 → 外圈），不按毫秒精确摆。角度按线路名算，同一条线永远在同一个方向。
/// 最多 8 个光点：正在用的 → 适合他宽带的 → 最快的。点光点 = 在线路列表里点它（onPick）。
class HomeRadar extends HookConsumerWidget {
  const HomeRadar({
    super.key,
    required this.size,
    required this.state,
    required this.isp,
    required this.onPick,
    this.step = 0,
    this.dimmed = false,
  });

  final double size;
  final RadarState state;
  final String isp;
  final int step;
  final bool dimmed;
  final void Function(LineOption line) onPick;

  static const _ringRadius = [60.0, 115.0, 165.0];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tk = OneRayTokens.of(context);
    final lines = ref.watch(lineSetProvider).valueOrNull?.lines ?? const <LineOption>[];
    final grades = ref.watch(lineSpeedProvider.select((s) => s.grades));
    final current = ref.watch(Preferences.lastNodeName);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final sweep = useAnimationController(duration: const Duration(milliseconds: 2400));
    final blink = useAnimationController(duration: const Duration(milliseconds: 900));
    final connecting = state == RadarState.connecting && !reduceMotion;
    useEffect(() {
      if (connecting) {
        sweep.repeat();
        blink.repeat(reverse: true);
      } else {
        sweep.stop();
        blink.value = 0;
        blink.stop();
      }
      return null;
    }, [connecting]);

    final k = size / 400;
    final blips = _blips(lines, grades, current, k);
    _Blip? cur;
    for (final b in blips) {
      if (b.current) cur = b;
    }
    final hollow = state == RadarState.off;

    return Opacity(
      opacity: dimmed ? 0.4 : (state == RadarState.failed ? 0.55 : 1),
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _ScopePainter(tk: tk, state: state, step: step, target: cur, k: k),
              ),
            ),
            if (state == RadarState.connecting || (state == RadarState.connected && cur != null))
              Positioned.fill(
                child: RepaintBoundary(
                  child: AnimatedBuilder(
                    animation: sweep,
                    builder: (context, _) => Transform.rotate(
                      angle: state == RadarState.connected ? cur!.deg * math.pi / 180 : sweep.value * 2 * math.pi,
                      child: CustomPaint(painter: _SweepPainter(color: tk.acc, k: k)),
                    ),
                  ),
                ),
              ),
            // 「快 / 中 / 慢」写在三块色块正下方，光点的名字会让开它们（Windows RadarScope 同一套）。
            for (final (t, y) in _bandLabels)
              Positioned(
                left: 0,
                right: 0,
                top: y * k - 8,
                child: Text(t, textAlign: TextAlign.center, style: TextStyle(fontSize: 10, height: 1.3, color: tk.dim.withValues(alpha: 0.7))),
              ),
            for (final b in blips)
              _blipWidget(context, tk, b, k, hollow, blink),
          ],
        ),
      ),
    );
  }

  Widget _blipWidget(BuildContext context, OneRayTokens tk, _Blip b, double k, bool hollow, AnimationController blink) {
    final dot = b.current ? (hollow ? 12.0 : 14.0) : 9.0;
    final ink = !b.measured && !b.current
        ? tk.dim
        : b.current
        ? (state == RadarState.failed ? tk.fault : tk.acc)
        : tk.blip;
    final labelLeft = b.labelLeft;
    final label = Text(
      b.line.name,
      style: TextStyle(
        fontSize: b.current ? 12 : 11,
        fontWeight: b.current ? FontWeight.w600 : FontWeight.w400,
        color: b.current ? tk.text : tk.sub,
      ),
    );
    Widget dotWidget = Container(
      width: dot,
      height: dot,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: hollow ? Colors.transparent : ink,
        border: hollow ? Border.all(color: ink, width: 2) : null,
        boxShadow: b.current && state == RadarState.connected
            ? [BoxShadow(color: tk.acc.withValues(alpha: .18), spreadRadius: 6)]
            : null,
      ),
    );
    if (b.current && state == RadarState.connecting) {
      dotWidget = FadeTransition(opacity: Tween(begin: 1.0, end: .25).animate(blink), child: dotWidget);
    }
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: labelLeft
          ? [label, const SizedBox(width: 5), dotWidget]
          : [dotWidget, const SizedBox(width: 5), label],
    );
    // 点按区域至少 44（规矩 §3.3）：光点外面包一圈透明的点按区。
    return Positioned(
      left: labelLeft ? null : b.x * k - dot / 2 - 8,
      right: labelLeft ? size - b.x * k - dot / 2 - 8 : null,
      top: b.y * k - 22,
      child: Semantics(
        button: true,
        label: b.current ? '${b.line.name}，正在用' : '换到 ${b.line.name}',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onPick(b.line),
          child: Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            alignment: Alignment.center,
            child: Opacity(opacity: b.available ? 1 : .45, child: row),
          ),
        ),
      ),
    );
  }

  List<_Blip> _blips(List<LineOption> lines, Map<String, SpeedGrade> grades, String current, double k) {
    int level(LineOption l) => grades[l.name]?.level ?? 0;
    int score(LineOption l) => level(l) > 0 && level(l) < 4 ? level(l) : 9;
    final picked = <LineOption>[];
    void take(LineOption l) {
      if (picked.length < 8 && !picked.contains(l)) picked.add(l);
    }

    lines.where((l) => l.name == current).forEach(take);
    (lines.where((l) => lineFitsIsp(l, isp)).toList()..sort((a, b) => score(a) - score(b))).forEach(take);
    (lines.toList()..sort((a, b) => score(a) - score(b))).forEach(take);

    // 一条条摆（正在用的先摆）：在自己那一圈上从固定角度起左右各挪 15° 试，名字放右边或左边；
    // 光点 + 名字这一块不能跟已经摆好的、中心点、「快 / 中 / 慢」叠上，也不能伸出雷达卡。都不行就放回原位。
    final pad = 3 / k;
    final taken = <Rect>[
      const Rect.fromLTWH(190, 190, 20, 20),
      for (final (_, y) in _bandLabels) Rect.fromCenter(center: Offset(200, y), width: 16 / k, height: 16 / k),
    ];
    return [
      for (final l in picked)
        () {
          final lv = level(l);
          final ring = lv == 1 ? 0 : (lv == 2 ? 1 : 2);
          final cur = l.name == current;
          final dot = (cur ? 14.0 : 9.0) / k;
          final w = dot + (5 + _textWidth(l.name, cur ? 12 : 11)) / k;
          final h = 18 / k;
          final base = _angleOf(l.name);
          (double, double, double, bool, Rect)? best;
          for (var i = 0; i < 24 && best == null; i++) {
            final deg = base + (i.isOdd ? -1 : 1) * ((i + 1) ~/ 2) * 15.0;
            final a = deg * math.pi / 180;
            final x = 200 + math.cos(a) * _ringRadius[ring];
            final y = 200 + math.sin(a) * _ringRadius[ring];
            for (final left in x > 285 ? [true, false] : [false, true]) {
              final box = Rect.fromLTWH(left ? x + dot / 2 - w : x - dot / 2, y - h / 2, w, h);
              if (box.left >= 4 && box.right <= 396 && !taken.any((t) => t.overlaps(box.inflate(pad)))) {
                best = (deg, x, y, left, box);
                break;
              }
            }
          }
          if (best == null) {
            final a = base * math.pi / 180;
            final x = 200 + math.cos(a) * _ringRadius[ring];
            final y = 200 + math.sin(a) * _ringRadius[ring];
            best = (base, x, y, x > 285, Rect.fromLTWH(x - dot / 2, y - h / 2, w, h));
          }
          final (deg, x, y, left, box) = best;
          taken.add(box);
          // 正在用的那条：中心到它的光束也算占地，别的名字别压在光束上。
          if (cur) {
            for (var t = 0.15; t < 1; t += 0.12) {
              taken.add(Rect.fromCenter(center: Offset(200 + (x - 200) * t, 200 + (y - 200) * t), width: 8, height: 8));
            }
          }
          return _Blip(
            line: l,
            current: cur,
            measured: lv > 0,
            available: lv != 4,
            deg: deg,
            x: x,
            y: y,
            labelLeft: left,
          );
        }(),
    ];
  }

  static const _bandLabels = [('快', 235.0), ('中', 300.0), ('慢', 358.0)];

  // 估一段字的宽度（像素）：汉字算一个字号宽，其余算 0.56 个。只用来避让，不求准。
  static double _textWidth(String s, double px) =>
      s.runes.fold(0.0, (w, r) => w + (r > 0x2e80 ? px : px * 0.56));

  static double _angleOf(String id) {
    var h = 7;
    for (final c in id.codeUnits) {
      h = (h * 31 + c) % 3607;
    }
    return (h % 360) - 180.0;
  }
}

class _Blip {
  const _Blip({
    required this.line,
    required this.current,
    required this.measured,
    required this.available,
    required this.deg,
    required this.x,
    required this.y,
    required this.labelLeft,
  });

  final LineOption line;
  final bool current;
  final bool measured;
  final bool available;
  final double deg;
  final double x;
  final double y;
  final bool labelLeft;
}

class _ScopePainter extends CustomPainter {
  _ScopePainter({required this.tk, required this.state, required this.step, required this.target, required this.k});

  final OneRayTokens tk;
  final RadarState state;
  final int step;
  final _Blip? target;
  final double k;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    // 雷达后面一块若隐若现的圆角淡卡（左上冷 → 右下暖）。
    final card = Offset.zero & size;
    canvas.drawRRect(
      RRect.fromRectAndRadius(card, Radius.circular(56 * k)),
      Paint()..shader = LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: tk.radarCard).createShader(card),
    );
    // 快 / 中 / 慢三圈不画线、不画十字：三块越往里越深的极淡强调色（10-18 雷达方案④，线条显廉价）。
    for (final (r, a) in [(190.0, .025), (130.0, .035), (70.0, .05)]) {
      canvas.drawCircle(c, r * k, Paint()..color = tk.acc.withValues(alpha: identical(tk, OneRayTokens.dark) ? a * 0.6 : a));
    }

    if (state == RadarState.connecting) {
      // 外圈五段，走到第几步亮到第几段。
      for (var i = 0; i < 5; i++) {
        final start = (-90 + i * 72 + 3) * math.pi / 180;
        canvas.drawArc(
          Rect.fromCircle(center: c, radius: 190 * k),
          start,
          (72 - 6) * math.pi / 180,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3
            ..color = i < step ? tk.acc : tk.ring,
        );
      }
    }

    final t = target;
    if (t != null && (state == RadarState.connected || state == RadarState.failed)) {
      final end = Offset(t.x * k, t.y * k);
      final beam = Paint()
        ..strokeWidth = 2.6
        ..color = state == RadarState.failed ? tk.fault : tk.acc;
      if (state == RadarState.failed) {
        // 失败：光束变虚线。
        final total = (end - c).distance;
        final dir = (end - c) / total;
        for (var d = 0.0; d < total; d += 8) {
          canvas.drawLine(c + dir * d, c + dir * math.min(d + 4, total), beam);
        }
      } else {
        canvas.drawLine(c, end, beam);
      }
    }
    canvas.drawCircle(c, 8 * k, Paint()..color = state == RadarState.connected ? tk.text : tk.sub);
  }

  @override
  bool shouldRepaint(_ScopePainter old) =>
      old.tk != tk || old.state != state || old.step != step || old.target?.line != target?.line || old.k != k;
}

class _SweepPainter extends CustomPainter {
  _SweepPainter({required this.color, required this.k});

  final Color color;
  final double k;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: 190 * k),
      -15 * math.pi / 180,
      30 * math.pi / 180,
      true,
      Paint()..color = color.withValues(alpha: .10),
    );
  }

  @override
  bool shouldRepaint(_SweepPainter old) => old.color != color || old.k != k;
}

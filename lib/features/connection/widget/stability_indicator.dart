import 'package:flutter/material.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/connection/notifier/stability_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 首页「连接稳定性」小指标。只在已连接时显示。
class StabilityIndicator extends ConsumerWidget {
  const StabilityIndicator({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connected =
        ref.watch(connectionNotifierProvider).valueOrNull?.isConnected ?? false;
    if (!connected) return const SizedBox.shrink();

    final s = ref.watch(stabilityProvider);
    final theme = Theme.of(context);
    final color = switch (s.score) {
      >= 8 => const Color(0xFF3FA372),
      >= 6 => theme.colorScheme.onSurfaceVariant,
      >= 4 => const Color(0xFFCF8A3B),
      >= 0 => theme.colorScheme.error,
      _ => theme.colorScheme.onSurfaceVariant,
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Bars(score: s.score, color: color),
          const SizedBox(width: 8),
          Text(
            s.measuring ? '稳定性测量中…' : '${s.label}（${s.score}/10）',
            style: theme.textTheme.bodySmall?.copyWith(color: color, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _Bars extends StatelessWidget {
  const _Bars({required this.score, required this.color});
  final int score;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final lit = score < 0 ? 0 : (score / 2.5).ceil().clamp(0, 4); // 0..4 格
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: List.generate(4, (i) {
        return Container(
          width: 3,
          height: 6.0 + i * 3,
          margin: const EdgeInsets.symmetric(horizontal: 1),
          decoration: BoxDecoration(
            color: i < lit ? color : color.withValues(alpha: 0.25),
            borderRadius: BorderRadius.circular(1),
          ),
        );
      }),
    );
  }
}

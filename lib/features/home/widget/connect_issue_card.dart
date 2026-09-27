import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/connection/notifier/stability_notifier.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/line/line_picker.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 首页：连上了却不通时，告诉用户为什么、下一步怎么做。两端同一套文案和按钮
/// （docs/连上但不通-两端统一-手册.md）。
///
///  - 10 秒一次都没通 → 已经断开，显示「这条线路现在连不通」；
///  - 用着用着约 1 分钟不通 → 不断开，显示「网络中断了约 1 分钟」，恢复后自己收起。
///
/// **不自动换线**：「换一条线路」只打开线路列表，让用户自己选。
class ConnectIssueCard extends ConsumerWidget {
  const ConnectIssueCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(connectionNotifierProvider).valueOrNull;
    final deadLine = ref.watch(deadLineProvider);
    final outage = ref.watch(stabilityProvider.select((s) => s.outage));

    final bool dead = deadLine && status is Disconnected;
    final bool broken = !dead && outage && status is Connected;
    if (!dead && !broken) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bg = dead ? scheme.errorContainer : scheme.tertiaryContainer;
    final fg = dead ? scheme.onErrorContainer : scheme.onTertiaryContainer;

    final String title = dead ? '这条线路现在连不通' : '网络中断了约 1 分钟';
    final String body = dead
        ? '已经连上了服务器，但打不开任何外网，所以先帮你断开了。\n'
            '常见原因：这条线路在你现在的网络下被挡住了，或者你的网络本身不稳定。'
        : '可能是这条线路临时波动，或者你的网络切换了。';

    Future<void> reconnect() async {
      ref.read(deadLineProvider.notifier).state = false;
      final notifier = ref.read(connectionNotifierProvider.notifier);
      if (status is Connected) {
        await notifier.reconnect(await ref.read(activeProfileProvider.future));
      } else {
        await notifier.toggleConnection();
      }
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(title, style: theme.textTheme.titleSmall?.copyWith(color: fg, fontWeight: FontWeight.w600)),
                ),
                if (dead)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: '关闭',
                    icon: Icon(Icons.close, size: 18, color: fg),
                    onPressed: () => ref.read(deadLineProvider.notifier).state = false,
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(body, style: theme.textTheme.bodySmall?.copyWith(color: fg, height: 1.5)),
            if (dead) ...[
              const SizedBox(height: 8),
              Text(
                '你可以：\n1. 换一条线路再连\n2. 切换 Wi-Fi / 手机流量后再试\n3. 还不行就联系客服',
                style: theme.textTheme.bodySmall?.copyWith(color: fg, height: 1.6),
              ),
            ],
            const SizedBox(height: 4),
            Wrap(
              spacing: 4,
              children: [
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: fg, minimumSize: const Size(48, 48)),
                  onPressed: () {
                    ref.read(deadLineProvider.notifier).state = false;
                    showLinePicker(context, ref);
                  },
                  child: const Text('换一条线路'),
                ),
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: fg, minimumSize: const Size(48, 48)),
                  onPressed: reconnect,
                  child: const Text('重新连接'),
                ),
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: fg, minimumSize: const Size(48, 48)),
                  onPressed: () => context.pushNamed('supportChat'),
                  child: const Text('联系客服'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

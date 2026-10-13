import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/features/common/guide_card.dart';
import 'package:hiddify/features/connection/data/connect_reporter.dart';
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
///
/// 10-13：只说查到的事实。「连接意外断开」（核心没走正常停止就没了）和「网页没走线路」
/// 原因查不到 → 给「怎么办」打开「原因不明」兜底卡；连续第二次自动弹（两端统一）。
final unknownFaultStreakProvider = StateProvider<int>((ref) => 0);

class ConnectIssueCard extends ConsumerWidget {
  const ConnectIssueCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(connectionNotifierProvider).valueOrNull;
    final deadLine = ref.watch(deadLineProvider);
    final fault = ref.watch(homeFaultProvider);
    final outage = ref.watch(stabilityProvider.select((s) => s.outage));
    final unreachable = ref.watch(unreachableNodesProvider);

    ref.listen<String>(homeFaultProvider, (prev, next) {
      if (next != 'engine' && next != 'egress') return;
      final n = ref.read(unknownFaultStreakProvider) + 1;
      ref.read(unknownFaultStreakProvider.notifier).state = n;
      if (n >= 2) showUnknownFaultGuide(context);
    });
    ref.listen<bool>(stabilityProvider.select((s) => s.confirmed), (prev, next) {
      if (next) ref.read(unknownFaultStreakProvider.notifier).state = 0;
    });
    final lastHost = ref.read(connectReporterProvider).lastNodeHost;

    // 断开后直接碰：两台不同的节点都没回音、接口服务器却通 → 自动弹一次引导卡（攒到 2 个那一刻）。
    ref.listen<Set<String>>(unreachableNodesProvider, (prev, next) {
      if (next.length >= 2 && (prev?.length ?? 0) < 2) {
        showNetBlockedGuide(context, next.length);
      }
    });

    final bool dead = (deadLine || fault == 'line') && status is Disconnected;
    final bool netBlocked = dead && unreachable.length >= 2;
    final bool thisLineBlocked = dead && !netBlocked && lastHost != null && unreachable.contains(lastHost);
    final bool revoked = fault == 'revoked' && status is Disconnected;
    final bool engine = (fault == 'engine' || revoked) && status is Disconnected;
    final bool egress = fault == 'egress' && status is Disconnected;
    final bool broken = !dead && !engine && !egress && outage && status is Connected;
    if (!dead && !engine && !egress && !broken) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bg = (dead || engine || egress) ? scheme.errorContainer : scheme.tertiaryContainer;
    final fg = (dead || engine || egress) ? scheme.onErrorContainer : scheme.onTertiaryContainer;

    final String title;
    final String body;
    if (revoked) {
      title = '连接断了';
      body = '连接被别的 VPN 或系统设置断开了。关掉别的 VPN 后，点「重新连接」';
    } else if (engine) {
      title = '连接断了';
      body = '连接意外断开了，点「重新连接」恢复。如果反复断开，点「怎么办」';
    } else if (egress) {
      title = '网页没有经过线路';
      body = '原因还没查到，点「怎么办」';
    } else if (netBlocked) {
      title = '你的网络连不上我们的线路';
      body = '试了 ${unreachable.length} 条线路都没有回应，换线路也没用';
    } else if (thisLineBlocked) {
      title = '这条线路现在不通';
      body = '你的网络连不上这条线路，换一条试试';
    } else if (dead) {
      title = '这条线路现在不通';
      body = '换一条线路试试，或者稍后点「重新连接」';
    } else {
      title = '网络中断了约 1 分钟';
      body = '可能是这条线路临时波动，或者你的网络切换了。';
    }

    Future<void> reconnect() async {
      ref.read(deadLineProvider.notifier).state = false;
      ref.read(homeFaultProvider.notifier).state = '';
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
                    onPressed: () {
                      ref.read(deadLineProvider.notifier).state = false;
                      ref.read(homeFaultProvider.notifier).state = '';
                    },
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(body, style: theme.textTheme.bodySmall?.copyWith(color: fg, height: 1.5)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 4,
              children: [
                if ((engine && !revoked) || egress)
                  TextButton(
                    style: TextButton.styleFrom(foregroundColor: fg, minimumSize: const Size(48, 48)),
                    onPressed: () => showUnknownFaultGuide(context),
                    child: const Text('怎么办'),
                  ),
                if (netBlocked)
                  TextButton(
                    style: TextButton.styleFrom(foregroundColor: fg, minimumSize: const Size(48, 48)),
                    onPressed: () => showNetBlockedGuide(context, unreachable.length),
                    child: const Text('怎么办'),
                  ),
                if (dead && !netBlocked)
                  TextButton(
                    style: TextButton.styleFrom(foregroundColor: fg, minimumSize: const Size(48, 48)),
                    onPressed: () {
                      ref.read(deadLineProvider.notifier).state = false;
                      ref.read(homeFaultProvider.notifier).state = '';
                      showLinePicker(context, ref);
                    },
                    child: const Text('换一条线路'),
                  ),
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: fg, minimumSize: const Size(48, 48)),
                  onPressed: reconnect,
                  child: const Text('重新连接'),
                ),
                if (broken)
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

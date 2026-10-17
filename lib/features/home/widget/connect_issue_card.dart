import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/common/guide_card.dart';
import 'package:hiddify/features/connection/data/connect_reporter.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/connection/notifier/local_repair.dart';
import 'package:hiddify/features/connection/notifier/stability_notifier.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/line/line_picker.dart';
import 'package:hiddify/features/settings/notifier/battery_optimization/battery_optimizations_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 首页：连上了却不通时，告诉用户为什么、下一步怎么做。两端同一套文案和按钮
/// （docs/连上但不通-两端统一-手册.md）。
///
///  - 10 秒一次都没通 → 已经断开，显示「这条线路现在连不通」；
///  - 用着用着约 1 分钟不通 → 不断开，显示「网络中断了约 1 分钟」，恢复后自己收起。
///
/// **不自动换线**：「换一条线路」只打开线路列表，让用户自己选。
///
/// 10-13：只说查到的事实。「网页没走线路」原因查不到 → 给「怎么办」打开「原因不明」兜底卡；
/// 「连接意外断开」（核心没走正常停止就没了）→ 10-15 起给一次「修复并重新连接」，修过还断就只剩
/// 「联系客服」（docs/计划/一键修复-初始化本地网络.md 第八节）。两种连续第二次都自动弹兜底卡（两端统一）。
final unknownFaultStreakProvider = StateProvider<int>((ref) => 0);

class ConnectIssueCard extends ConsumerWidget {
  const ConnectIssueCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(connectionNotifierProvider).valueOrNull;
    final deadLine = ref.watch(deadLineProvider);
    final fault = ref.watch(homeFaultProvider);
    final unreachable = ref.watch(unreachableNodesProvider);
    final reachableHost = ref.watch(reachableDeadNodeProvider);
    // 连接意外断开（不是系统收回）= 原因不明：给一次「修复并重新连接」，修过还断就只剩联系客服。
    final canRepair = ref.watch(repairedKindProvider) != 'engine';

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
    // 这条在维修（断开后 connection_notifier 重拉过一次账号）：说「正在维修」，只给换线路。
    final lineName = ref.watch(Preferences.lastNodeName);
    final bool lineDown = dead && ref.watch(panelAuthProvider.select((s) => s.account?.isLineDown(lineName) ?? false));
    final bool netBlocked = dead && !lineDown && unreachable.length >= 2;
    final bool thisLineBlocked = dead && !netBlocked && lastHost != null && unreachable.contains(lastHost);
    // 直连节点是通的、隧道没走通：线路是好的，问题在这台手机这边，不叫他换线（体检修复 R2，跟 Windows tunnel_local 同一句）。
    final bool localPath = dead && !lineDown && !netBlocked && !thisLineBlocked && lastHost != null && reachableHost == lastHost;
    final bool revoked = fault == 'revoked' && status is Disconnected;
    final bool engine = (fault == 'engine' || revoked) && status is Disconnected;
    final bool gone = engine && !revoked;
    // 意外断开时查一下有没有「后台运行」权限：没有的话省电模式会停掉后台的 VPN（10-16 查：
    // 近 7 天安卓 8 个人「核心没走正常停止就没了」）。只在查实没有权限时才说、才给按钮。
    final bool noBackground = gone && ref.watch(batteryOptimizationNotifierProvider).valueOrNull == false;
    final bool egress = fault == 'egress' && status is Disconnected;
    if (!dead && !engine && !egress) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bg = scheme.errorContainer;
    final fg = scheme.onErrorContainer;

    final String title;
    final String body;
    if (revoked) {
      title = '连接断了';
      // 只说查到的事实（10-13 / 10-15）：系统收回了我们的 VPN，不猜是谁。
      body = '手机系统断开了光速雷达的 VPN 连接。手机上开着别的 VPN 的话，先关掉它，再点「重新连接」';
    } else if (noBackground) {
      title = '连接断了';
      body = '光速雷达现在没有「后台运行」权限，手机省电时会停掉它的连接。点「允许后台运行」，在弹出的窗口里选「允许」，再点「重新连接」';
    } else if (engine) {
      title = '连接断了';
      body = canRepair ? '连接意外断开了，点「修复并重新连接」恢复' : '修复后还是断开了，请联系客服，我们帮你查';
    } else if (egress) {
      title = '网页没有经过线路';
      body = '原因还没查到，点「怎么办」';
    } else if (lineDown) {
      title = '$lineName 正在维修';
      body = '暂时连不上，请换一条线路';
    } else if (netBlocked) {
      title = '你的网络连不上我们的线路';
      body = '试了 ${unreachable.length} 条线路都没有回应，换线路也没用';
    } else if (thisLineBlocked) {
      title = '这条线路现在不通';
      body = '这条线路在你的网络里连不上，请换一条';
    } else if (localPath) {
      title = '这台手机没连通';
      body = '线路是好的，是这台手机这边没连通。点「重新连接」再试一次，还不行请联系客服';
    } else {
      title = '这条线路现在不通';
      body = '换一条线路试试，或者稍后点「重新连接」';
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
                if (noBackground)
                  TextButton(
                    style: TextButton.styleFrom(foregroundColor: fg, minimumSize: const Size(48, 48)),
                    onPressed: () => ref.read(batteryOptimizationNotifierProvider.notifier).requestToIgnore(),
                    child: const Text('允许后台运行'),
                  ),
                if (noBackground)
                  TextButton(
                    style: TextButton.styleFrom(foregroundColor: fg, minimumSize: const Size(48, 48)),
                    onPressed: reconnect,
                    child: const Text('重新连接'),
                  ),
                if (gone && canRepair && !noBackground)
                  TextButton(
                    style: TextButton.styleFrom(foregroundColor: fg, minimumSize: const Size(48, 48)),
                    onPressed: () => ref.read(localRepairProvider).repairAndReconnect('engine'),
                    child: const Text('修复并重新连接'),
                  ),
                if (egress)
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
                if (dead && !netBlocked && !localPath)
                  TextButton(
                    style: TextButton.styleFrom(foregroundColor: fg, minimumSize: const Size(48, 48)),
                    onPressed: () {
                      ref.read(deadLineProvider.notifier).state = false;
                      ref.read(homeFaultProvider.notifier).state = '';
                      showLinePicker(context, ref);
                    },
                    child: const Text('换一条线路'),
                  ),
                if (!gone && !lineDown)
                  TextButton(
                    style: TextButton.styleFrom(foregroundColor: fg, minimumSize: const Size(48, 48)),
                    onPressed: reconnect,
                    child: const Text('重新连接'),
                  ),
                if (localPath || (gone && !canRepair && !noBackground))
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

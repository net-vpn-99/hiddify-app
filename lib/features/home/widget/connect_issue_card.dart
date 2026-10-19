import 'package:flutter/material.dart';
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
/// （docs/计划/连上后判通-按节点回数据.md）。
///
///  - 检测连接被节点结束、一个字节没回 → 已经断开，按正面证据说原因（不再按「10 秒没通」判）；
///  - 用着用着约 1 分钟不通、节点也没再回数据 → 断开说原因。
///
/// **不自动换线**：「换一条线路」只打开线路列表，让用户自己选。
///
/// 按钮有主次（10-19 运营定）：第一个是主按钮。原因不明 / 线路设置对不上 / 同一种情况连着第二次（照办法做了
/// 还不行）→ 主按钮是「联系客服」，原来的处理办法挪到后面。只说查到的事实。
final unknownFaultStreakProvider = StateProvider<int>((ref) => 0);

/// 连着判「这条线路不通」几次（确认网通就清零）。
final deadStreakProvider = StateProvider<int>((ref) => 0);

class ConnectIssueCard extends ConsumerWidget {
  const ConnectIssueCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(connectionNotifierProvider).valueOrNull;
    final deadLine = ref.watch(deadLineProvider);
    final fault = ref.watch(homeFaultProvider);
    final unreachable = ref.watch(unreachableNodesProvider);
    // 连接意外断开（不是系统收回）= 原因不明：给一次「修复并重新连接」，修过还断就只剩联系客服。
    final canRepair = ref.watch(repairedKindProvider) != 'engine';

    ref.listen<String>(homeFaultProvider, (prev, next) {
      if (next != 'engine' && next != 'egress') return;
      final n = ref.read(unknownFaultStreakProvider) + 1;
      ref.read(unknownFaultStreakProvider.notifier).state = n;
      if (n >= 2) showUnknownFaultGuide(context);
    });
    ref.listen<bool>(stabilityProvider.select((s) => s.confirmed), (prev, next) {
      if (!next) return;
      ref.read(unknownFaultStreakProvider.notifier).state = 0;
      ref.read(deadStreakProvider.notifier).state = 0;
    });
    ref.listen<bool>(deadLineProvider, (prev, next) {
      if (next && prev != true) ref.read(deadStreakProvider.notifier).state++;
    });
    final evidence = ref.watch(deadEvidenceProvider);
    final refused = ref.watch(refusedNodesProvider);
    final deadStreak = ref.watch(deadStreakProvider);
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
    // 节点没认出我们（REALITY 校验失败）：线路配置的问题，不是用户的。
    final bool reality = dead && !lineDown && evidence == 'reality';
    // 两条不同的线都是「端口通、节点却把连接结束了、一个字节没回」：原因说不清。
    final bool unknown = dead && !lineDown && !netBlocked && !reality && refused.length >= 2;
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
    } else if (reality) {
      title = '这条线路暂时用不了';
      body = '这条线路的设置和服务器对不上，不是你的问题。请联系客服，我们来处理；你也可以先换一条线路';
    } else if (unknown) {
      title = '连接没有完成';
      body = unknownFaultCopy;
    } else if (thisLineBlocked) {
      title = '这条线路现在不通';
      body = '这条线路在你的网络里连不上，请换一条';
    } else if (evidence == 'refused') {
      title = '这条线路现在不通';
      body = '这条线路断开了光速雷达的连接。请换一条线路';
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

    void pickLine() {
      ref.read(deadLineProvider.notifier).state = false;
      ref.read(homeFaultProvider.notifier).state = '';
      showLinePicker(context, ref);
    }

    void support() => openSupportWithDiag(context);

    // 处理办法（原因已知时它们是主按钮）。
    final fixes = <(String, VoidCallback)>[
      if (noBackground) ('允许后台运行', () => ref.read(batteryOptimizationNotifierProvider.notifier).requestToIgnore()),
      if (noBackground) ('重新连接', reconnect),
      if (gone && canRepair && !noBackground) ('修复并重新连接', () => ref.read(localRepairProvider).repairAndReconnect('engine')),
      if (egress) ('怎么办', () => showUnknownFaultGuide(context)),
      if (netBlocked) ('怎么办', () => showNetBlockedGuide(context, unreachable.length)),
      if (dead && !netBlocked && !unknown) ('换一条线路', pickLine),
      if (!gone && !lineDown) ('重新连接', reconnect),
    ];
    // 联系客服当主按钮：原因不明 / 线路设置对不上 / 网页没走线路且查不到原因 / 修过还断 / 同一种不通连着第二次。
    final supportFirst = unknown ||
        reality ||
        egress ||
        (gone && !canRepair && !noBackground) ||
        (dead && !lineDown && !netBlocked && deadStreak >= 2);
    final actions = supportFirst ? [('联系客服', support), ...fixes] : fixes;

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
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final (i, act) in actions.indexed)
                  i == 0
                      ? FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: fg,
                            foregroundColor: bg,
                            minimumSize: const Size(48, 40),
                          ),
                          onPressed: act.$2,
                          child: Text(act.$1),
                        )
                      : TextButton(
                          style: TextButton.styleFrom(foregroundColor: fg, minimumSize: const Size(48, 48)),
                          onPressed: act.$2,
                          child: Text(act.$1),
                        ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/common/guide_card.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/connection/notifier/local_repair.dart';
import 'package:hiddify/features/connection/notifier/stability_notifier.dart';
import 'package:hiddify/features/connection/widget/connect_check_card.dart';
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
/// 按钮有主次（10-19 运营定）：第一个是主按钮。只说查到的事实。
/// 说不清原因的（这条线路不通 / 连接意外断了 / 网页没经过线路）主按钮是「帮我查一查」——连接检查当场查，
/// 查完给结论和办法（docs/计划/连接检查.md）；以前的「你的网络连不上我们的线路」「原因不明」两种判断都并进去了，
/// 「同一种情况连着第二次就让联系客服当主按钮」也在连接检查的结论里做。线路设置对不上主按钮仍是「联系客服」。

class ConnectIssueCard extends ConsumerWidget {
  const ConnectIssueCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(connectionNotifierProvider).valueOrNull;
    final deadLine = ref.watch(deadLineProvider);
    final fault = ref.watch(homeFaultProvider);
    // 连接意外断开时「修复并重新连接」帮不帮得上（修过一次还断就不再给），交给连接检查（R11）。
    final canRepair = ref.watch(repairedKindProvider) != 'engine';
    final evidence = ref.watch(deadEvidenceProvider);

    final bool dead = (deadLine || fault == 'line') && status is Disconnected;
    // 这条在维修（断开后 connection_notifier 重拉过一次账号）：说「正在维修」，只给换线路。
    final lineName = ref.watch(Preferences.lastNodeName);
    final bool lineDown = dead && ref.watch(panelAuthProvider.select((s) => s.account?.isLineDown(lineName) ?? false));
    // 节点没认出我们（REALITY 校验失败）：线路配置的问题，不是用户的。
    final bool reality = dead && !lineDown && evidence == 'reality';
    final bool revoked = fault == 'revoked' && status is Disconnected;
    final bool engine = (fault == 'engine' || revoked) && status is Disconnected;
    final bool gone = engine && !revoked;
    // 意外断开时查一下有没有「后台运行」权限：没有的话省电模式会停掉后台的 VPN（10-16 查：
    // 近 7 天安卓 8 个人「核心没走正常停止就没了」）。只在查实没有权限时才说、才给按钮。
    final bool noBackground = gone && ref.watch(batteryOptimizationNotifierProvider).valueOrNull == false;
    final bool egress = fault == 'egress' && status is Disconnected;
    // 判不通后直连一查：节点、接口服务器、百度都碰不到 = 这台手机没上网（connection_notifier._probeDeadLineDirect）。
    final bool offline = fault == 'offline' && status is Disconnected;
    if (!dead && !engine && !egress && !offline) return const SizedBox.shrink();
    // 说不清原因的：主按钮「帮我查一查」（原因已知的直接说：没网、维修中、系统收回、没后台权限、线路设置对不上）
    final bool checkable = (dead && !lineDown && !reality && !offline) || (gone && !noBackground) || egress;
    final String checkFault = dead ? 'dead_tunnel' : (gone ? 'engine_gone' : 'egress_mismatch');

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bg = scheme.errorContainer;
    final fg = scheme.onErrorContainer;

    final String title;
    final String body;
    if (offline) {
      title = '这台手机没连上网';
      body = '请先确认能打开网页，再点「重新连接」';
    } else if (revoked) {
      title = '连接断了';
      // 只说查到的事实（10-13 / 10-15）：系统收回了我们的 VPN，不猜是谁。
      body = '手机系统断开了光速雷达的 VPN 连接。手机上开着别的 VPN 的话，先关掉它，再点「重新连接」';
    } else if (noBackground) {
      title = '连接断了';
      body = '光速雷达现在没有「后台运行」权限，手机省电时会停掉它的连接。点「允许后台运行」，在弹出的窗口里选「允许」，再点「重新连接」';
    } else if (engine) {
      title = '连接断了';
      body = checkPrompt;
    } else if (egress) {
      title = '网页没有经过线路';
      body = checkPrompt;
    } else if (lineDown) {
      title = '$lineName 正在维修';
      body = '暂时连不上，请换一条线路';
    } else if (reality) {
      title = '这条线路暂时用不了';
      body = '这条线路的设置和服务器对不上，不是你的问题。请联系客服，我们来处理；你也可以先换一条线路';
    } else {
      title = '这条线路现在不通';
      body = checkPrompt;
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
      if (checkable) ('帮我查一查', () => showConnectCheck(context, ref, fault: checkFault, canRepair: gone && canRepair)),
      if (dead && !checkable) ('换一条线路', pickLine),
      if (!gone && !lineDown) ('重新连接', reconnect),
    ];
    // 联系客服当主按钮：线路设置对不上（不是用户的问题，要我们处理）。
    final supportFirst = reality;
    // 原因已知时「联系客服」也一直在（排最后），跟 Windows 失败卡下面那行「联系客服（会自动带上诊断码）」一样。
    final actions = supportFirst ? [('联系客服', support), ...fixes] : [...fixes, ('联系客服', support)];

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
                if (dead || offline)
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

/// 说不清原因时卡上那句（Windows describeLiveFault 同一句）。
const checkPrompt = '点「帮我查一查」，我们帮你看看是哪里出了问题。';

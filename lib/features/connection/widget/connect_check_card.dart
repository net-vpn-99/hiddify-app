import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/theme/oneray_tokens.dart';
import 'package:hiddify/features/common/guide_card.dart';
import 'package:hiddify/features/common/line_icon.dart';
import 'package:hiddify/features/connection/data/connect_check.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/connection/notifier/local_repair.dart';
import 'package:hiddify/features/connection/notifier/stability_notifier.dart';
import 'package:hiddify/features/diagnostic/diag_tile.dart';
import 'package:hiddify/features/home/widget/connect_progress.dart';
import 'package:hiddify/features/panel_auth/data/other_vpn.dart';
import 'package:hiddify/features/proxy/line/line_picker.dart';
import 'package:hiddify/features/proxy/line/line_source.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 未知情况（R10）卡上的小贴士（运营 10-19 定稿，两端同一句）：查清后发公告鼓励 + 送会员时长。
const checkRewardTip = '如果你愿意帮我们检查测试并解决，作为感谢，我们会发公告鼓励，并赠送相应的会员时长奖励。';

/// 连接检查结果卡（docs/计划/连接检查.md）：开始查并弹出来，查着时一行行转圈、查出结果才打勾 / 打叉；
/// 查完上面是结论，下面是查到的几行，按钮由 ConnectCheckNotifier 按结论表给。Windows 同款：HelpGuides.qml 的 checkCard。
/// [fault] / [canRepair] 见 ConnectCheckNotifier.start。
Future<void> showConnectCheck(BuildContext context, WidgetRef ref, {String fault = '', bool canRepair = false}) {
  final connected = ref.read(connectionNotifierProvider).valueOrNull is Connected;
  void run() => unawaited(ref.read(connectCheckProvider.notifier).start(fault: fault, connected: connected, canRepair: canRepair));
  run();
  return showDialog<void>(
    context: context,
    barrierColor: guideCanvasColor(context),
    builder: (ctx) => Consumer(
      // 卡片自己的 cref 只用来看检查进度；按钮要办的事用外面的 ref（卡片关掉后它的 ref 就不能用了）
      builder: (ctx, cref, _) {
        final s = cref.watch(connectCheckProvider);
        void act(String a) {
          if (a == 'recheck') {
            run();
            return;
          }
          Navigator.of(ctx).pop();
          unawaited(_runAct(context, ref, a));
        }

        return PopScope(
          // 查着时关掉（点「停止检查」、点外面、返回键）= 不查了
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) cref.read(connectCheckProvider.notifier).stop();
          },
          child: connectCheckCard(s, act),
        );
      },
    ),
  );
}

/// 检查结果卡本身（按状态画，按钮交给 [onAct]）。截图测试也用它（test/features/home/connect_check_preview_test.dart）。
Widget connectCheckCard(ConnectCheckState s, void Function(String act) onAct) => GuideCard(
      title: s.title,
      body: s.running ? '' : s.body,
      illustration: _CheckRows(state: s),
      tipTitle: s.reward ? '你的反馈能帮我们改进光速雷达' : '',
      tipText: checkRewardTip,
      tipIcon: LineIconName.gift,
      tipBelow: true,
      actionText: s.primaryText,
      onAction: () => onAct(s.primaryAct),
      secondaryText: s.secondaryText,
      onSecondary: () => onAct(s.secondaryAct),
      links: s.running
          ? const []
          : [
              GuideLink('更多办法：初始化本地网络', () => onAct('init')),
              GuideLink('导出诊断', () => onAct('diag')),
            ],
    );

Future<void> _runAct(BuildContext context, WidgetRef ref, String act) async {
  // 他照结果去做了：首页那张失败卡收掉
  void clearFault() {
    ref.read(deadLineProvider.notifier).state = false;
    ref.read(homeFaultProvider.notifier).state = '';
  }

  switch (act) {
    case 'switch':
      // 换到推荐那条（他点了才换）：是服务器排第一的那条 = 不再记「自己选的」，跟服务器排的走；不是 = 记成他选的
      // （跟线路下线卡的「换到 X」同一套，Windows switchToSource）。
      clearFault();
      final alt = ref.read(connectCheckProvider).altName;
      final first = (await ref.read(lineSetProvider.future)).lines.firstOrNull?.name;
      await ref.read(Preferences.preferredLineName.notifier).update(alt == first ? '' : alt);
      ref.read(connectRequestProvider.notifier).state++;
    case 'routes':
      clearFault();
      if (context.mounted) await showLinePicker(context, ref);
    case 'reconnect':
      clearFault();
      ref.read(connectRequestProvider.notifier).state++;
    case 'contact':
      ref.read(connectCheckProvider.notifier).markContacted();
      if (context.mounted) openSupportWithDiag(context);
    case 'repair':
      clearFault();
      await ref.read(localRepairProvider).repairAndReconnect('engine');
    case 'vpn_settings':
      await OtherVpn.openSettings();
    case 'site':
      await UriUtils.tryLaunch(Uri.parse(Constants.websiteUrl));
    case 'init':
      final done = await ref.read(localRepairProvider).initialize();
      if (done.isNotEmpty && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已$done')));
      }
    case 'diag':
      if (context.mounted) await exportDiagnostics(context, ref);
  }
}

/// 检查那几行：查着时转圈 + 一根匀速往前爬的进度条（只是画面，结论只看真实结果）。
class _CheckRows extends StatelessWidget {
  const _CheckRows({required this.state});

  final ConnectCheckState state;

  @override
  Widget build(BuildContext context) {
    final t = OneRayTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (state.running) ...[
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 0.85),
            duration: const Duration(seconds: 15),
            curve: Curves.easeOutQuad,
            builder: (_, v, _) => ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(value: v, minHeight: 3, color: t.acc, backgroundColor: t.ring),
            ),
          ),
          const SizedBox(height: 10),
        ],
        for (final r in state.rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: [
                SizedBox(
                  width: 18,
                  height: 18,
                  child: Center(
                    child: r.state == 'run'
                        ? SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: t.acc))
                        : Icon(
                            r.state == 'ok' ? Icons.check_rounded : Icons.close_rounded,
                            size: 17,
                            color: r.state == 'ok' ? t.ok : t.fault,
                          ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    r.text,
                    style: TextStyle(
                      fontSize: 13,
                      color: r.state == 'run' ? t.sub : t.text,
                      fontWeight: r.state == 'fail' ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

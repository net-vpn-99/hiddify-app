import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hiddify/core/model/constants.dart';
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
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 未知情况（R10）卡上的小贴士（运营 10-19 定稿，两端同一句）：查清后发公告鼓励 + 送会员时长。
const checkRewardTip = '如果你愿意帮我们检查测试并解决，作为感谢，我们会发公告鼓励，并赠送相应的会员时长奖励。';

/// 连接检查结果卡（docs/计划/连接检查.md）：开始查并弹出来，查着时一行行转圈、查出结果才打勾 / 打叉；
/// 查完上面是结论，下面是查到的几行，按钮由 ConnectCheckNotifier 按结论表给。Windows 同款：HelpGuides.qml 的 checkCard。
/// [fault]：打开时刚才失败的原因（首页卡认不出的那几种由调用方给，比如第 1～2 步的 account / nodes）。
/// 每次查（含「重新检查」）都按那一刻的状态重算：正连着 / 正在连、首页卡上的原因、修复帮不帮得上
/// （Windows 每次 startConnectCheck → startCheck 重算同一套）。
Future<void> showConnectCheck(BuildContext context, WidgetRef ref, {String fault = ''}) {
  void run() {
    final status = ref.read(connectionNotifierProvider).valueOrNull;
    // 正连着 / 正在连：结论不给「重新连接」，也不查「别的 VPN」（系统里那个就是我们）
    final connected = status is Connected || status is Connecting;
    // 调用方明说的原因优先（第 1～2 步的 account / nodes 首页卡认不出）；没给的看首页卡现在说的
    final f = connected ? '' : (fault.isNotEmpty ? fault : _homeFault(ref.read));
    unawaited(ref.read(connectCheckProvider.notifier).start(
          fault: f,
          connected: connected,
          canRepair: f == 'engine_gone' && ref.read(repairedKindProvider) != 'engine',
        ));
  }
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

/// 首页失败卡现在说的原因（Windows faultKind 同一套词），没有 = ''。
String _homeFault(T Function<T>(ProviderListenable<T>) read) {
  final home = read(homeFaultProvider);
  if (read(deadLineProvider) || home == 'line') {
    if (home == 'offline') return 'offline';
    return read(deadRealityProvider) ? 'reality_mismatch' : 'dead_tunnel';
  }
  return switch (home) {
    'engine' => 'engine_gone',
    'egress' => 'egress_mismatch',
    'revoked' || 'offline' => home,
    _ => '',
  };
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
      // 底部小字的「更多办法」只在查出问题时给；没发现问题（R7）不给，给了反而让人以为还有事要做（10-22 运营，两端统一）
      links: s.running || s.result == 'R7'
          ? const []
          : [
              GuideLink('更多办法：初始化本地网络', () => onAct('init')),
              GuideLink('导出诊断', () => onAct('diag')),
            ],
    );

Future<void> _runAct(BuildContext context, WidgetRef ref, String act) async {
  // 收掉首页失败卡会让打开检查的那张卡（ref 的主人）跟着拆掉：要办的事用整个 App 的 container，不用它的 ref
  final container = ProviderScope.containerOf(context, listen: false);
  final read = container.read;
  // 他照结果去做了：首页那张失败卡收掉
  void clearFault() {
    read(deadLineProvider.notifier).state = false;
    read(homeFaultProvider.notifier).state = '';
  }

  switch (act) {
    case 'switch':
      // 换到推荐那条（他点了才换，跟线路下线「换到 X」同一份 switchToLine）；线路清单刷新过、那条没了就让他自己选
      clearFault();
      if (!await switchToLine(read, read(connectCheckProvider).altName) && context.mounted) {
        await showLinePicker(context, ref);
      }
    case 'routes':
      // 先打开线路列表再收卡（收卡会拆掉 context 的主人）
      final picker = showLinePicker(context, ref);
      clearFault();
      await picker;
    case 'reconnect':
      clearFault();
      read(connectRequestProvider.notifier).state++;
    case 'contact':
      read(connectCheckProvider.notifier).markContacted();
      if (context.mounted) openSupportWithDiag(context);
    case 'repair':
      clearFault();
      await read(localRepairProvider).repairAndReconnect('engine');
    case 'vpn_settings':
      await OtherVpn.openSettings();
    case 'site':
      await UriUtils.tryLaunch(Uri.parse(Constants.websiteUrl));
    case 'init':
      // 先说清楚做什么，他点了「开始初始化」才做（10-22 运营：点了就开始，不知道是干嘛的；Windows initConfirmCard 同一个做法，正文按各自实际做的事写）
      if (!context.mounted) return;
      final go = await showDialog<bool>(
        context: context,
        barrierColor: guideCanvasColor(context),
        builder: (ctx) => GuideCard(
          title: '初始化本地网络？',
          body: '光速雷达会断开自己的连接，再重新获取线路。之前连着的话，会自动重新连上。手机的其他设置不会改动。',
          actionText: '开始初始化',
          onAction: () => Navigator.of(ctx).pop(true),
          secondaryText: '不用了',
          onSecondary: () => Navigator.of(ctx).pop(false),
        ),
      );
      if (go != true) return;
      final done = await read(localRepairProvider).initialize();
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

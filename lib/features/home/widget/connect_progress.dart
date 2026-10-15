import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hiddify/features/connection/data/connect_flow_clock.dart';
import 'package:hiddify/features/connection/data/connect_reporter.dart';
import 'package:hiddify/features/connection/data/system_settings.dart';
import 'package:hiddify/features/connection/data/vpn_permission.dart';
import 'package:hiddify/features/connection/model/connection_failure.dart';
import 'package:hiddify/features/panel_auth/data/other_vpn.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 一键连接的 5 步进度（两端统一，Windows 见 ConnectionController::connectStep）：
///   1 开通账号  2 获取线路  3 选择线路  4 启动连接  5 检查网络
///
/// 某一步真的做完了才算这一步完成（进度条在一格里匀速爬只是画面，见 [ConnectStepsBar]）。
/// 前三步由首页连接按钮的点击流程推（connection_button.dart），第 4 步看连接状态
/// （Connecting），第 5 步看 stabilityProvider.confirmed（第一次经隧道的请求成功）。
/// 哪一步失败就停在那一步，[failedStep] + [title] / [message] 说原因和下一步。
class ConnectProgress {
  const ConnectProgress({
    this.step = 0,
    this.failedStep = 0,
    this.title = '',
    this.message = '',
    this.action = SettingsAction.none,
    this.repair = false,
  });

  /// 点击流程正在做第几步（1~4），0 = 没在跑。
  final int step;

  /// 停在哪一步失败了，0 = 没失败。
  final int failedStep;
  final String title;
  final String message;

  /// 失败时按钮下面多给的一个「去设置」按钮（没有就是 none）。
  final SettingsAction action;

  /// 失败时给「修复并重新连接」（local_repair.dart）。只在连接没启动起来、原因不明时给，
  /// 同一种失败修过一次就不再给（docs/计划/一键修复-初始化本地网络.md 第三、八节）。
  final bool repair;
}

final connectProgressProvider = StateProvider<ConnectProgress>((ref) => const ConnectProgress());

/// 别的地方要「像点了连接按钮一样」走一遍一键连接（没连接时在线路列表里选了线路，10-14 运营定）。
/// 数字加一 = 请求一次；首页连接按钮听到后，没在连就走同一套多米诺流程。
final connectRequestProvider = StateProvider<int>((ref) => 0);

const connectStepLabels = ['开通账号', '获取线路', '选择线路', '启动连接', '检查网络'];

/// 第 4 步（启动连接）失败时给客户看的：标题直说要允许什么、「下一步怎么做」、能直接去的设置页。
/// 两端统一，Windows 见 ConnectionController::engineFaultCopy。原始报错只进上报和 app.log。
/// [repaired] = 这种失败已经修过一次了（见 repairedKindProvider）。
ConnectProgress connectFailProgress(Object? err, {bool repaired = false}) => switch (err) {
  MissingVpnPermission() => _vpnDeniedProgress(),
  MissingNotificationPermission() => const ConnectProgress(
    failedStep: 4,
    title: '请允许光速雷达发通知',
    message: '连接要在通知栏显示才能一直开着。点「打开通知设置」允许后，再点一下按钮',
    action: SettingsAction.notifications,
  ),
  MissingPrivilege() || BackgroundCoreNotAvailable() => const ConnectProgress(
    failedStep: 4,
    title: '请允许光速雷达在后台运行',
    message: '点「允许后台运行」，在弹出的窗口里选「允许」，再点一下按钮。还不行的话，请到官网下载最新版重新安装',
    action: SettingsAction.battery,
  ),
  // 连接没启动起来、原因不明：不猜原因（以前劝「换一条线路」，线路根本还没用上）。
  _ when repaired => const ConnectProgress(failedStep: 4, title: '连接没成功', message: '修复后还是没连上，请联系客服，我们帮你查'),
  _ => const ConnectProgress(failedStep: 4, title: '连接没成功', message: '光速雷达没能启动连接', repair: true),
};

/// 别的 App 占着 VPN，我们的起不来（被系统拒 / 初始化本地网络时查到）。说法只用 OtherVpn 那一份。
const otherVpnProgress = ConnectProgress(
  failedStep: 4,
  title: OtherVpn.title,
  message: '${OtherVpn.message}${OtherVpn.howTo}',
  action: SettingsAction.vpn,
);

/// 系统没让光速雷达建 VPN：按证据分两种说，不把两种情况塞进一句话（10-14 运营：看着脑壳疼）。
ConnectProgress _vpnDeniedProgress() {
  VpnPermission.noteDenied(_flowTicket);
  if (VpnPermission.otherVpnBeforeConnect || VpnPermission.deniedStreak >= 2) return otherVpnProgress;
  return const ConnectProgress(
    failedStep: 4,
    title: '需要你允许一次',
    message: '再点一下按钮，手机弹出「网络连接请求」时，请点「确定」。',
  );
}

/// 点击流程的「票」：每点一次连接领一张新票，点取消就作废当前这张。流程每走完一步
/// 都看一眼票还有没有效，作废了就停下 —— 取消靠这个，不靠计时。
int _flowTicket = 0;

int beginConnectFlow() {
  ConnectFlowClock.begin();
  return ++_flowTicket;
}

bool connectFlowAlive(int ticket) => ticket == _flowTicket;

void cancelConnectFlow(WidgetRef ref) {
  _flowTicket++;
  // 准备那几步（1~3）他点了取消：记一条，看大家在哪一步等不及。
  final step = ref.read(connectProgressProvider).step;
  if (ConnectFlowClock.isOpen && step >= 1 && step <= 3) {
    unawaited(ref.read(connectReporterProvider).reportCancel(ConnectFlowClock.slug(step)));
  }
  ref.read(connectProgressProvider.notifier).state = const ConnectProgress();
}

/// 连接进度条（10-13 改，两端统一；Windows 是 qml/components/ConnectSteps.qml，两边一起改）：
///   一根细长的条，从左往右线性地走，像加载条。
///   **一整根，不分格、不露出有几步**（运营定：别让人看出我们做了几步）。里面还是按步骤算：
///   只算这一次真要做的步骤（已经登录的人没有「开通账号」，已经有线路的人没有「获取线路」），
///   第一次看到的那一步（_first）往后几步平分整根；正在做的那一段匀速往前爬到八成五就停住等，
///   这一步真做完了（step 往前走）才补满这一段、接着爬。爬只是画面，连接逻辑不看时间。
///   失败：原地停住变红。连上：整根补满变绿。
///   正在做什么写在按钮下面那行字里，条上不写字。
class ConnectStepsBar extends StatefulWidget {
  const ConnectStepsBar({super.key, required this.step, required this.failedStep, required this.done});

  final int step;
  final int failedStep;
  final bool done;

  @override
  State<ConnectStepsBar> createState() => _ConnectStepsBarState();
}

class _ConnectStepsBarState extends State<ConnectStepsBar> with SingleTickerProviderStateMixin {
  // 整根条填到哪（0~1）。
  late final AnimationController _fill = AnimationController(vsync: this);
  int _first = 0;
  String _mode = 'idle';

  int get _count => _first > 0 ? 6 - _first : 0;

  String _modeOf(ConnectStepsBar w) => w.failedStep > 0
      ? 'fail'
      : w.step > 0
      ? 'working'
      : w.done
      ? 'done'
      : 'idle';

  // 每一步大概要多久，只用来定「匀速爬」的速度（画面），不拿来判断任何事。
  static int _typicalMs(int s) => switch (s) {
    1 => 2500,
    2 => 2000,
    3 => 1200,
    4 => 5000,
    _ => 2500,
  };

  @override
  void initState() {
    super.initState();
    // 要读 MediaQuery（系统「减少动画」），等第一帧挂好再开始。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _sync();
    });
  }

  @override
  void didUpdateWidget(covariant ConnectStepsBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.step != widget.step || oldWidget.failedStep != widget.failedStep || oldWidget.done != widget.done) {
      _sync();
    }
  }

  Future<void> _sync() async {
    final m = _modeOf(widget);
    if (m == 'working' && (_mode != 'working' || _first == 0 || widget.step < _first)) {
      _first = widget.step;
      _fill.value = 0;
    }
    if (m == 'fail' && _first == 0) _first = widget.failedStep;
    if (m == 'done' && _first == 0) _first = 5;
    _mode = m;
    // 格数、哪一格变红都跟着 _first / _mode 变，重画一次。
    if (mounted) setState(() {});
    _fill.stop();
    if (m == 'idle') {
      _first = 0;
      _fill.value = 0;
      return;
    }
    if (m == 'fail') return; // 原地停住
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (m == 'done') {
      await _fill.animateTo(1, duration: const Duration(milliseconds: 220), curve: Curves.easeOutCubic).orCancel.catchError((_) {});
      return;
    }
    final w = 1 / _count;
    final from = (widget.step - _first) / _count;
    final ticket = widget.step;
    if (_fill.value < from) {
      await _fill.animateTo(from, duration: const Duration(milliseconds: 220), curve: Curves.easeOutCubic).orCancel.catchError((_) {});
    }
    if (!mounted || _mode != 'working' || widget.step != ticket) return;
    await _fill
        .animateTo(from + w * 0.85, duration: Duration(milliseconds: reduce ? 0 : _typicalMs(widget.step)))
        .orCancel
        .catchError((_) {});
  }

  @override
  void dispose() {
    _fill.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const green = Color(0xFF2E9E5B);
    const gold = Color(0xFFE1B83F);
    final n = _count;
    if (n == 0) return const SizedBox(width: 180, height: 4);
    return Semantics(
      label: _mode == 'fail'
          ? '连接没有完成'
          : _mode == 'done'
          ? '连接完成'
          : '正在连接',
      child: SizedBox(
        width: 180,
        height: 4,
        child: AnimatedBuilder(
          animation: _fill,
          builder: (context, _) {
            final color = _mode == 'done'
                ? green
                : _mode == 'fail'
                ? scheme.error
                : gold;
            return Stack(
              children: [
                Container(
                  decoration: BoxDecoration(color: scheme.outlineVariant, borderRadius: BorderRadius.circular(2)),
                ),
                FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: _fill.value,
                  child: Container(
                    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hiddify/features/connection/data/connect_flow_clock.dart';
import 'package:hiddify/features/connection/data/connect_reporter.dart';
import 'package:hiddify/features/connection/model/connection_failure.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 一键连接的 5 步进度（两端统一，Windows 见 ConnectionController::connectStep）：
///   1 开通账号  2 获取线路  3 选择线路  4 启动连接  5 检查网络
///
/// 像游戏加载那样一步一步走，但**只在某一步真的做完时才往前走**，绝不按时间往前爬。
/// 前三步由首页连接按钮的点击流程推（connection_button.dart），第 4 步看连接状态
/// （Connecting），第 5 步看 stabilityProvider.confirmed（第一次经隧道的请求成功）。
/// 哪一步失败就停在那一步，[failedStep] + [title] / [message] 说原因和下一步。
class ConnectProgress {
  const ConnectProgress({this.step = 0, this.failedStep = 0, this.title = '', this.message = ''});

  /// 点击流程正在做第几步（1~4），0 = 没在跑。
  final int step;

  /// 停在哪一步失败了，0 = 没失败。
  final int failedStep;
  final String title;
  final String message;
}

final connectProgressProvider = StateProvider<ConnectProgress>((ref) => const ConnectProgress());

const connectStepLabels = ['开通账号', '获取线路', '选择线路', '启动连接', '检查网络'];

/// 第 4 步（启动连接）失败时给客户看的标题和「下一步怎么做」。两端统一，
/// Windows 见 ConnectionController::engineFaultCopy。原始报错只进上报和 app.log，不给客户看。
({String title, String message}) connectFailCopy(Object? err) => switch (err) {
  MissingVpnPermission() => (
    title: '需要你允许一次',
    message: '系统问「是否允许建立 VPN 连接」时，请点「确定」，然后再点一下按钮',
  ),
  MissingNotificationPermission() => (
    title: '需要你允许通知',
    message: '请在手机设置里允许光速雷达发通知，然后再点一下按钮',
  ),
  MissingPrivilege() || BackgroundCoreNotAvailable() => (
    title: '光速雷达被拦住了',
    message: '请在手机管家里允许光速雷达后台运行，再点一下按钮。如果还不行，请到官网下载最新版重新安装',
  ),
  _ => (title: '连接没成功', message: '请再点一下按钮。如果还不行，请换一条线路'),
};

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

/// 5 段进度条：做完的绿、正在做的闪、失败的红、没到的灰。手机上放 5 个字标签太挤，
/// 所以只画段，当前这步在做什么写在按钮下面那行字里。
class ConnectStepsBar extends StatefulWidget {
  const ConnectStepsBar({super.key, required this.step, required this.failedStep, required this.done});

  final int step;
  final int failedStep;
  final bool done;

  @override
  State<ConnectStepsBar> createState() => _ConnectStepsBarState();
}

class _ConnectStepsBarState extends State<ConnectStepsBar> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 560),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const green = Color(0xFF2E9E5B);
    const amber = Color(0xFFE0A530);
    return Semantics(
      label: widget.failedStep > 0
          ? '第 ${widget.failedStep} 步没有完成'
          : widget.done
          ? '连接完成'
          : '第 ${widget.step} 步，共 5 步',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 1; i <= 5; i++) ...[
            if (i > 1) const SizedBox(width: 4),
            AnimatedBuilder(
              animation: _pulse,
              builder: (context, _) {
                final Color color;
                var opacity = 1.0;
                if (widget.done) {
                  color = green;
                } else if (widget.failedStep > 0) {
                  color = i < widget.failedStep
                      ? green
                      : i == widget.failedStep
                      ? scheme.error
                      : scheme.outlineVariant;
                } else if (i < widget.step) {
                  color = green;
                } else if (i == widget.step) {
                  color = amber;
                  opacity = 0.35 + 0.65 * (1 - _pulse.value);
                } else {
                  color = scheme.outlineVariant;
                }
                return Opacity(
                  opacity: opacity,
                  child: Container(
                    width: 30,
                    height: 4,
                    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
                  ),
                );
              },
            ),
          ],
        ],
      ),
    );
  }
}

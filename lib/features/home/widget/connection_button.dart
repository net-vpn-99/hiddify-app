import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/core/theme/theme_extensions.dart';
import 'package:hiddify/core/widget/animated_text.dart';
import 'package:hiddify/features/connection/data/connect_flow_clock.dart';
import 'package:hiddify/features/connection/data/connect_reporter.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/connection/notifier/stability_notifier.dart';
import 'package:hiddify/features/home/widget/connect_progress.dart';
import 'package:hiddify/features/panel_auth/notifier/guest_bootstrap.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/profile/notifier/profile_notifier.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/features/settings/notifier/config_option/config_option_notifier.dart';
import 'package:hiddify/gen/assets.gen.dart';
import 'package:hiddify/singbox/model/singbox_config_enum.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

// TODO: rewrite
class ConnectionButton extends HookConsumerWidget {
  const ConnectionButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final connectionStatus = ref.watch(connectionNotifierProvider);
    final activeProxy = ref.watch(activeProxyNotifierProvider);
    final delay = activeProxy.valueOrNull?.urlTestDelay ?? 0;
    // 两端统一：第一次经隧道的请求成功之前，按钮还是「连接中」（见 stability_notifier）。
    final confirmed = ref.watch(stabilityProvider.select((s) => s.confirmed));

    final requiresReconnect = ref.watch(configOptionNotifierProvider).valueOrNull;
    // final animationController = useAnimationController(
    //   duration: const Duration(seconds: 1),
    // )..repeat(reverse: true); // Ensure the animation loops indefinitely

    //   // Listen to the animation's value
    //   final animationValue = useAnimation(Tween<double>(begin: 0.8, end: 1).animate(animationController));

    //   // useEffect(() {
    //   //   if (true) {
    //   // Start repeating animation
    //   //   } else {
    //   //     animationController.stop(); // Stop animation if connected, disconnected, or error
    //   //   }

    //   //   // Cleanup when widget is disposed
    //   //   return animationController.dispose;
    //   // }, [connectionStatus.value]);

    //   // ref.listen(
    //   //   connectionNotifierProvider,
    //   //   (_, next) {
    //   //     if (next case AsyncError(:final error)) {
    //   //       CustomAlertDialog.fromErr(t.presentError(error)).show(context);
    //   //     }
    //   //     if (next case AsyncData(value: Disconnected(:final connectionFailure?))) {
    //   //       CustomAlertDialog.fromErr(t.presentError(connectionFailure)).show(context);
    //   //     }
    //   //   },
    //   // );

    const buttonTheme = ConnectionButtonTheme.light;
    final account = ref.watch(panelAuthProvider.select((s) => s.account));
    final quotaEnded = account?.exhausted == true;

    var secureLabel =
        (ref.watch(ConfigOptions.enableWarp) && ref.watch(ConfigOptions.warpDetourMode) == WarpDetourMode.warpOverProxy)
        ? t.connection.secure
        : "";
    if (quotaEnded || delay <= 0 || delay > 65000 || connectionStatus.value != const Connected()) {
      secureLabel = "";
    }

    if (quotaEnded) {
      return _ConnectionButton(
        onTap: () async {
          await ref.read(connectionNotifierProvider.notifier).abortConnection();
          await ref.read(dialogNotifierProvider.notifier).showQuotaExhausted(account!, force: true);
        },
        enabled: true,
        label: account?.stateSlug != 'expired'
            ? '流量已用完'
            : (ref.watch(panelAuthProvider.select((s) => s.isGuest)) ? '试用已结束' : '会员已到期'),
        hint: '点一下买套餐继续用',
        buttonColor: buttonTheme.idleColor!,
        newButtonColor: buttonTheme.idleColor!,
        animated: false,
        secureLabel: '',
      );
    }

    // OneRay: 点下去到状态变「连接中」之间要跑几步准备工作（开号 / 拉线路 / 切到自家订阅），
    // 这几步就是进度条的第 1~3 步。点下去立刻震一下，按钮下面写第几步、在做什么；
    // 这期间再点一下 = 取消（不再是点了没反应）。
    final preparing = useState(false);
    VoidCallback guard(Future<void> Function() action) => () async {
      if (preparing.value) {
        cancelConnectFlow(ref);
        preparing.value = false;
        return;
      }
      preparing.value = true;
      unawaited(HapticFeedback.mediumImpact());
      try {
        await action();
      } finally {
        if (context.mounted) preparing.value = false;
      }
    };
    final busy = preparing.value && connectionStatus.valueOrNull is! Connected;

    // ---- 进度条（第 4、5 步看连接状态和「第一次经隧道的请求成功」）----
    final progress = ref.watch(connectProgressProvider);
    final deadLine = ref.watch(deadLineProvider);
    final status = connectionStatus.valueOrNull;
    ref.listen(connectionNotifierProvider, (prev, next) {
      final p = ref.read(connectProgressProvider);
      final s = next.valueOrNull;
      // 引擎接手了：第 4 步之后由连接状态自己说话（之前停在第 4 步的失败也一并收掉）。
      if ((p.step == 4 || p.failedStep == 4) && (s is Connecting || s is Connected)) {
        ref.read(connectProgressProvider.notifier).state = const ConnectProgress();
        return;
      }
      // 在「启动连接」这一步倒下了：核心说了为什么（拒绝 VPN 授权、启动失败……）才算失败，
      // 停在第 4 步并说下一步。授权弹窗是在 Connecting 之前问的，所以第 4 步进行中也算。
      final failedNow = next is AsyncError || (s is Disconnected && s.connectionFailure != null);
      if ((prev?.valueOrNull is Connecting || p.step == 4) && failedNow) {
        final copy = connectFailCopy(next is AsyncError ? next.error : (s is Disconnected ? s.connectionFailure : null));
        ref.read(connectProgressProvider.notifier).state = ConnectProgress(
          failedStep: 4,
          title: copy.title,
          message: copy.message,
        );
      }
    });
    // 刚确认网通：5 段全绿亮一下再收起来（纯显示）。
    final justDone = useState(false);
    ref.listen<bool>(stabilityProvider.select((s) => s.confirmed), (prev, next) {
      if (next && prev != true) {
        justDone.value = true;
        Future.delayed(const Duration(milliseconds: 1500), () {
          if (context.mounted) justDone.value = false;
        });
      }
    });
    final engineStep = switch (status) {
      Connecting() => 4,
      Connected() when !confirmed => 5,
      _ => 0,
    };
    final shownStep = progress.step > 0 ? progress.step : engineStep;
    final shownFailed = shownStep > 0 ? 0 : (progress.failedStep > 0 ? progress.failedStep : (deadLine ? 5 : 0));
    final bootMessage = ref.watch(guestBootstrapProvider.select((b) => b.working ? (b.message ?? '') : ''));
    final stepTitle = switch (shownStep) {
      1 => bootMessage.contains('人机验证') ? '正在进行人机验证' : '正在开通账号',
      2 => '正在获取线路',
      3 => '正在选择线路',
      4 => '正在启动连接',
      5 => '正在检查网络是否畅通',
      _ => '',
    };
    final Widget? stepsBar = shownStep > 0 || shownFailed > 0 || justDone.value
        ? ConnectStepsBar(step: shownStep, failedStep: shownFailed, done: justDone.value && shownStep == 0)
        : null;

    return _ConnectionButton(
      onTap: guard(switch (connectionStatus) {
        AsyncData(value: Connected()) when requiresReconnect == true => () async {
          final activeProfile = await ref.read(activeProfileProvider.future);
          return await ref.read(connectionNotifierProvider.notifier).reconnect(activeProfile);
        },
        // OneRay：一键连接 = 多米诺。每一步做完立刻接着下一步，任何一步失败就停在那一步
        // 说原因；点一下按钮随时取消（guard 里作废这张票）。以前这里开号 / 导入线路之后
        // 直接 return，用户得再点一次才真的连（10-12 查出来的断链）。
        AsyncData(value: Disconnected()) || AsyncError() => () async {
          final ticket = beginConnectFlow();
          final progressCtl = ref.read(connectProgressProvider.notifier);
          bool stopped() => !connectFlowAlive(ticket) || !context.mounted;
          void stepTo(int n) {
            ConnectFlowClock.at(n);
            progressCtl.state = ConnectProgress(step: n);
          }

          void failAt(int n, String title, String message) {
            progressCtl.state = ConnectProgress(failedStep: n, title: title, message: message);
            // 前三步停下的：上报写清停在哪步、什么原因（以前这几步失败服务器一条都没有）。
            // 第 4 步的失败由 connection_notifier 按连接尝试报，这里不重复。
            if (n <= 3) {
              final stage = switch (n) {
                1 => 'account',
                2 => 'sub_download',
                _ => 'route_pick',
              };
              unawaited(ref.read(connectReporterProvider).reportStepFailure(n, stage, '$title：$message'));
            }
          }

          // 不是失败也不是取消（去登录 / 去续费 / 没同意提示）：计时收掉，别算到下一次头上。
          void clear() {
            ConnectFlowClock.end('stop');
            progressCtl.state = const ConnectProgress();
          }
          ref.read(deadLineProvider.notifier).state = false;

          // ① 开通账号：没账号先把游客号补开一次（首页开号可能还没跑完，或者上次网络
          // 不好失败了）。1.1.28 起不再直接把人踢去登录页：首页不拦人，点下去才说话。
          stepTo(1);
          if (!ref.read(Preferences.panelLoggedIn)) {
            await ref.read(guestBootstrapProvider.notifier).ensure();
            if (stopped()) return;
            final boot = ref.read(guestBootstrapProvider);
            if (!ref.read(Preferences.panelLoggedIn) && boot.knownAccountMask != null) {
              clear();
              if (context.mounted) context.pushNamed('login');
              return;
            }
            if (!ref.read(Preferences.panelLoggedIn) && boot.reason != GuestBlockReason.unavailable) {
              await ref.read(Preferences.guestOptOut.notifier).update(false);
              ref.read(guestBootstrapProvider.notifier).reset();
              await ref.read(guestBootstrapProvider.notifier).ensure();
            }
            if (stopped()) return;
            if (!ref.read(Preferences.panelLoggedIn)) {
              final why = ref.read(guestBootstrapProvider).message ?? '';
              failAt(1, '账号没开通', why.isEmpty ? '检查网络后再点一次' : why);
              await ref.read(dialogNotifierProvider.notifier).showNeedAccount(message: why);
              return;
            }
          }
          if (stopped()) return;

          // ② 获取线路。开号那一步（guest_bootstrap）通常已经把线路导进来了 ——
          // **这里重新看一眼**，有了就直接往下走（以前用的是点按钮那一刻的旧判断）。
          stepTo(2);
          if ((await ref.read(activeProfileProvider.future)) == null) {
            // 登录了却没有可用订阅：多半是试用 / 会员到期或流量用完。补一次账号再判断，
            // 别再给用户看「还没有 VPN 服务器？免费设置一个」那种误导文案。
            try {
              await ref.read(panelAuthProvider.notifier).syncAccountQuietly();
            } catch (_) {}
            if (stopped()) return;
            final acc = ref.read(panelAuthProvider).account;
            if (acc != null && (acc.exhausted || acc.stateSlug == 'no_plan')) {
              clear();
              await ref.read(dialogNotifierProvider.notifier).showQuotaExhausted(acc, force: true);
              return;
            }
            // 账号正常却没订阅 —— 订阅同步掉了，重新拉一次地址并导入（跟登录时同一条路）。
            final url = await ref.read(panelAuthProvider.notifier).refreshSubscribeUrl();
            if (stopped()) return;
            if (url == null || url.isEmpty) {
              failAt(2, '线路没拿到', '检查网络后再点一次；还不行在「我的」页联系客服');
              return;
            }
            await ref.read(addProfileNotifierProvider.notifier).addAccountSubscription(url);
            if (stopped()) return;
            if (ref.read(addProfileNotifierProvider) is AsyncError) {
              failAt(2, '线路没拿到', '检查网络后再点一次；还不行在「我的」页联系客服');
              return;
            }
          }

          // ③ 选择线路：选中的是别家订阅（旧版能导入别家的）→ 连之前切回自家那份。
          stepTo(3);
          if (!await ref.read(addProfileNotifierProvider.notifier).ensureAccountProfileActive()) {
            if (stopped()) return;
            failAt(3, '线路没切换过来', '稍后再点一次；还不行在「我的」页联系客服');
            return;
          }
          if (stopped()) return;
          if (!await ref.read(dialogNotifierProvider.notifier).showExperimentalFeatureNotice()) {
            clear();
            return;
          }
          if (stopped()) return;

          // ④ 启动连接。之后的进度由连接状态推（上面的 ref.listen）。
          stepTo(4);
          // 第 4 步的结果只看连接状态的事件（上面的 ref.listen）：Connecting / Connected 往前走，
          // 核心报了失败（含拒绝 VPN 授权）就停在第 4 步。以前这里在 toggleConnection 一返回就
          // 看状态，那时核心常常还没报 Connecting，把正在连的当成「被拒绝授权」（10-13 TEST 真机）。
          await ref.read(connectionNotifierProvider.notifier).toggleConnection();
        },
        AsyncData(value: Connected()) => () async {
          if (requiresReconnect == true &&
              await ref.read(dialogNotifierProvider.notifier).showExperimentalFeatureNotice()) {
            return await ref
                .read(connectionNotifierProvider.notifier)
                .reconnect(await ref.read(activeProfileProvider.future));
          }
          return await ref.read(connectionNotifierProvider.notifier).toggleConnection();
        },
        _ => () async {},
      }),
      // 准备那几步里按钮可以点（= 取消）；引擎在起的那一下（Connecting）不能点。
      enabled:
          busy ||
          switch (connectionStatus) {
            AsyncData(value: Connected()) || AsyncData(value: Disconnected()) || AsyncError() => true,
            _ => false,
          },
      label: stepTitle.isNotEmpty
          ? stepTitle
          : shownFailed > 0 && shownFailed < 5 && progress.title.isNotEmpty
          ? progress.title
          : switch (connectionStatus) {
              AsyncData(value: Connected()) when requiresReconnect == true => t.connection.reconnect,
              AsyncData(value: Connected()) when !confirmed => t.connection.connecting,
              AsyncData(value: final status) => status.present(t),
              _ => "",
            },
      hint: shownStep > 0 && shownStep <= 3
          ? '第 $shownStep/5 步 · 点一下取消'
          : shownStep > 0
          ? '第 $shownStep/5 步'
          : shownFailed > 0 && shownFailed < 5
          ? progress.message
          : null,
      steps: stepsBar,
      buttonColor: switch (connectionStatus) {
        AsyncData(value: Connected()) when requiresReconnect == true => Colors.teal,
        AsyncData(value: Connected()) when !confirmed => const Color.fromARGB(255, 185, 176, 103),
        AsyncData(value: Connected()) => buttonTheme.connectedColor!,
        AsyncData(value: _) => buttonTheme.idleColor!,
        _ => Colors.red,
      },
      newButtonColor: switch (connectionStatus) {
        AsyncData(value: Connected()) when requiresReconnect == true => Colors.teal,
        AsyncData(value: Connected()) when !confirmed => const Color.fromARGB(255, 185, 176, 103),
        AsyncData(value: Connected()) => buttonTheme.connectedColor!,
        AsyncData(value: _) => buttonTheme.idleColor!,
        _ => Colors.red,
      },
      animated:
          busy ||
          switch (connectionStatus) {
            AsyncData(value: Connected()) when requiresReconnect == true => false,
            AsyncData(value: Connected()) when !confirmed => false,
            AsyncData(value: Connected()) => true,
            AsyncData(value: _) => true,
            _ => false,
          },
      secureLabel: secureLabel,
    );
  }
}

class _ConnectionButton extends StatelessWidget {
  const _ConnectionButton({
    required this.onTap,
    required this.enabled,
    required this.label,
    required this.buttonColor,
    required this.newButtonColor,
    required this.animated,
    required this.secureLabel,
    this.hint,
    this.steps,
  });

  final VoidCallback onTap;
  final bool enabled;
  final String label;
  final String? hint;
  // 一键连接的 5 段进度条（connect_progress.dart），只在连接途中 / 失败时有。
  final Widget? steps;
  final Color buttonColor;
  final String secureLabel;

  final Color newButtonColor;

  final bool animated;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // CircleDesignWidget(newButtonColor: newButtonColor, onTap: onTap, animated: animated),
        Semantics(
          button: true,
          enabled: enabled,
          label: label,
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(blurRadius: 16, color: buttonColor.withValues(alpha: .5))],
            ),
            width: 148,
            height: 148,
            child: Material(
              key: const ValueKey("home_connection_button"),
              shape: const CircleBorder(),
              color: Colors.white,
              child: InkWell(
                focusColor: Colors.grey,
                onTap: onTap,
                child: Padding(
                  padding: const EdgeInsets.all(36),
                  child: TweenAnimationBuilder(
                    tween: ColorTween(end: buttonColor),
                    duration: const Duration(milliseconds: 250),
                    builder: (context, value, child) {
                      return Assets.images.logo.svg(colorFilter: ColorFilter.mode(value!, BlendMode.srcIn));
                    },
                  ),
                ),
              ),
            ).animate(target: enabled ? 0 : 1).blurXY(end: 1),
          ).animate(target: enabled ? 0 : 1).scaleXY(end: .88, curve: Curves.easeIn),
        ),
        const Gap(16),
        ExcludeSemantics(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedText(label, style: Theme.of(context).textTheme.titleMedium),
              if (steps != null) ...[const Gap(8), steps!],
              if (hint != null && hint!.isNotEmpty) ...[
                const Gap(4),
                Text(
                  hint!,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ],
              if (secureLabel.isNotEmpty) ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // const Gap(8),
                    Icon(FontAwesomeIcons.shieldHalved, size: 16, color: Theme.of(context).colorScheme.secondary),
                    const Gap(4),
                    Text(
                      secureLabel,
                      style: Theme.of(
                        context,
                      ).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.secondary),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

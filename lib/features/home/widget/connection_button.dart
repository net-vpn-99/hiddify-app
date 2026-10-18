import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/core/theme/oneray_tokens.dart';
import 'package:hiddify/features/app/notifier/app_foreground.dart';
import 'package:hiddify/features/common/guide_card.dart';
import 'package:hiddify/features/common/text_link.dart';
import 'package:hiddify/features/connection/data/connect_flow_clock.dart';
import 'package:hiddify/features/connection/data/connect_reporter.dart';
import 'package:hiddify/features/connection/data/system_settings.dart';
import 'package:hiddify/features/connection/data/vpn_permission.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/connection/notifier/local_repair.dart';
import 'package:hiddify/features/connection/notifier/stability_notifier.dart';
import 'package:hiddify/features/home/widget/connect_progress.dart';
import 'package:hiddify/features/home/widget/home_radar.dart';
import 'package:hiddify/features/panel_auth/data/other_vpn.dart';
import 'package:hiddify/features/panel_auth/notifier/guest_bootstrap.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hiddify/features/panel_auth/widget/invite_gate.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/profile/notifier/profile_notifier.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/features/proxy/line/line_picker.dart';
import 'package:hiddify/features/proxy/line/line_source.dart';
import 'package:hiddify/features/proxy/line/line_tier.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/features/settings/notifier/config_option/config_option_notifier.dart';
import 'package:hiddify/singbox/model/singbox_config_enum.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

// TODO: rewrite
class ConnectionButton extends HookConsumerWidget {
  const ConnectionButton({super.key, this.statusExtra = const [], this.middle = const []});

  /// 状态下面紧跟的几行（速率、稳定度、提示）。
  final List<Widget> statusExtra;

  /// 状态和按钮之间的卡片（失败卡、活动卡、常用网站）。
  final List<Widget> middle;

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

    final account = ref.watch(panelAuthProvider.select((s) => s.account));
    final quotaEnded = account?.exhausted == true;

    var secureLabel =
        (ref.watch(ConfigOptions.enableWarp) && ref.watch(ConfigOptions.warpDetourMode) == WarpDetourMode.warpOverProxy)
        ? t.connection.secure
        : "";
    if (quotaEnded || delay <= 0 || delay > 65000 || connectionStatus.value != const Connected()) {
      secureLabel = "";
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
        ref.read(connectProgressProvider.notifier).state = connectFailProgress(
          next is AsyncError ? next.error : (s is Disconnected ? s.connectionFailure : null),
          repaired: ref.read(repairedKindProvider) == 'start',
        );
      }
    });
    // 刚确认网通：5 段全绿亮一下再收起来（纯显示）。
    final justDone = useState(false);
    ref.listen<bool>(stabilityProvider.select((s) => s.confirmed), (prev, next) {
      if (next && prev != true) {
        VpnPermission.noteConnected();
        ref.read(repairedKindProvider.notifier).state = '';
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

    // 一键连接 = 多米诺（按钮和「没连接时选了线路」共用这一套）。
    Future<void> connectFlow() async {
      final ticket = beginConnectFlow();
      final progressCtl = ref.read(connectProgressProvider.notifier);
      bool stopped() => !connectFlowAlive(ticket) || !context.mounted;
      void stepTo(int n) {
        ConnectFlowClock.at(n);
        progressCtl.state = ConnectProgress(step: n);
      }

      void failAt(int n, String title, String message, {String? reportStage, SettingsAction action = SettingsAction.none}) {
        progressCtl.state = ConnectProgress(failedStep: n, title: title, message: message, action: action);
        // 前三步停下的：上报写清停在哪步、什么原因（以前这几步失败服务器一条都没有）。
        // 第 4 步的失败由 connection_notifier 按连接尝试报，这里不重复。
        if (n <= 3) {
          final stage = reportStage ?? switch (n) {
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
          final boot = ref.read(guestBootstrapProvider);
          final why = boot.message ?? '';
          failAt(1, '账号没开通', why.isEmpty ? '检查网络后再点一次' : why);
          await ref.read(dialogNotifierProvider.notifier).showNeedAccount(message: why);
          return;
        }
      }
      if (stopped()) return;

      // ② 获取线路。开号那一步（guest_bootstrap）通常已经把线路导进来了 ——
      // **这里重新看一眼**，有了就直接往下走（以前用的是点按钮那一刻的旧判断）。
      stepTo(2);
      // 首次打开时自动开号还在导入线路：等它导完再看有没有订阅，别自己再拉一遍导一遍
      // （体检修复 A1：首次打开马上点连接的 19% 导入了两遍，线路列表闪一下、多等 1～2 秒）。
      // 只等「正在开号」那种（working）；已登录的人启动时那次读账号不用等，订阅本来就在。
      final opening = ref.read(guestBootstrapProvider).working ? ref.read(guestBootstrapProvider.notifier).inflight : null;
      if (opening != null) {
        await opening;
        if (stopped()) return;
      }
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
      // 选的线路在维修：不去连，说清楚，让他自己换（不自动换线；Windows 同一句，route_down）。
      final line = ref.read(Preferences.preferredLineName);
      if (ref.read(panelAuthProvider).account?.isLineDown(line) ?? false) {
        failAt(3, '$line 正在维修', '暂时连不上，请换一条线路', reportStage: 'route_down');
        return;
      }
      if (!await ref.read(dialogNotifierProvider.notifier).showExperimentalFeatureNotice()) {
        clear();
        return;
      }
      if (stopped()) return;

      // ④ 启动连接。之后的进度由连接状态推（上面的 ref.listen）。
      stepTo(4);
      // 开着别家 VPN 照常连：系统只留一个 VPN，我们连上就把它顶掉。这里只记下来，万一被系统拒了
      // （别家设了「始终开启」）好说清楚是它挡着（我们自己的这时还没连，不会把自己算进去）。
      VpnPermission.otherVpnBeforeConnect = await OtherVpn.isActive();
      if (stopped()) return;
      // 这台手机还没允许过光速雷达建 VPN：系统马上要弹「网络连接请求」，先说清楚点哪个
      // （10-14 客户 ID 1725 看到系统那段「监控网络流量…请勿接受」不敢点，一直连不上）。
      if (!await VpnPermission.granted()) {
        if (stopped() || !context.mounted) return;
        // 10-16 运营：改成底部面板（按钮在拇指够得到的地方）；示意图画成一看就是插图的样子，
        // 不跟真窗口一模一样（以前有人去点图里的「确定」；各品牌手机的窗口也长得不一样）。
        await showGuideSheet(
          context,
          title: '接下来手机会问你一次',
          body: '点「确定」，光速雷达才能连接。所有 VPN 软件第一次连接都会问一次。',
          illustration: const VpnPromptSketch(),
          fineprint: '光速雷达不记录你的上网内容',
          actionText: '知道了，去连接',
        );
        if (stopped()) return;
      }
      // 第 4 步的结果只看连接状态的事件（上面的 ref.listen）：Connecting / Connected 往前走，
      // 核心报了失败（含拒绝 VPN 授权）就停在第 4 步。以前这里在 toggleConnection 一返回就
      // 看状态，那时核心常常还没报 Connecting，把正在连的当成「被拒绝授权」（10-13 TEST 真机）。
      await ref.read(connectionNotifierProvider.notifier).toggleConnection();
    }

    // 从 VPN 设置回来（App 回到前台这个事件）：别的 VPN 已经关了就直接接着连，不用他再点（体检修复 R5）。
    ref.listen<bool>(appForegroundProvider, (prev, next) async {
      if (!next || prev == true || !resumeAfterVpnSettings) return;
      resumeAfterVpnSettings = false;
      if (await OtherVpn.isActive()) return;
      ref.read(connectProgressProvider.notifier).state = const ConnectProgress();
      ref.read(connectRequestProvider.notifier).state++;
    });
    ref.listen<int>(connectRequestProvider, (prev, next) {
      if (next == prev || preparing.value) return;
      final now = ref.read(connectionNotifierProvider);
      if (now is AsyncError || now.valueOrNull is Disconnected) guard(connectFlow)();
    });

    final lineName = ref.watch(Preferences.lastNodeName);
    final lineDesc = ref.watch(Preferences.lastNodeDesc);
    final connected = status is Connected;
    // 免费试用中或精品体验中：没连接时说「免费试用中」、底下给「看套餐」（跟 Windows homeKicker / homeThird 一样）。
    final freeTrial = ref.watch(panelAuthProvider.select((s) => s.freeTrial));
    final tierTrial = ref.watch(lineTierProvider.select((x) => x.trial == 'active'));
    final trialing = freeTrial || tierTrial;
    final failedNow = shownFailed > 0 || connectionStatus is AsyncError ||
        (status is Disconnected && status.connectionFailure != null);
    final radarState = busy || shownStep > 0
        ? RadarState.connecting
        : connected
        ? RadarState.connected
        : failedNow
        ? RadarState.failed
        : RadarState.off;

    final onTap = guard(switch (connectionStatus) {
      AsyncData(value: Connected()) when requiresReconnect == true => () async {
        final activeProfile = await ref.read(activeProfileProvider.future);
        return await ref.read(connectionNotifierProvider.notifier).reconnect(activeProfile);
      },
      // OneRay：一键连接 = 多米诺。每一步做完立刻接着下一步，任何一步失败就停在那一步
      // 说原因；点一下按钮随时取消（guard 里作废这张票）。以前这里开号 / 导入线路之后
      // 直接 return，用户得再点一次才真的连（10-12 查出来的断链）。
      AsyncData(value: Disconnected()) || AsyncError() => connectFlow,
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
    });

    // ---- 三种「还不能连」的主页（两端同一张表：docs/计划/主页状态表.md）----
    // 放在所有 hook 之后：以前到期那段在 useState 前面就 return，账号一恢复 hook 个数变了会出错。
    final loggedIn = ref.watch(Preferences.panelLoggedIn);
    Widget blocked({
      required VoidCallback go,
      required String title,
      required String sub,
      required String button,
      String kicker = '',
      String link = '',
      VoidCallback? onLink,
      bool dimmed = true,
      bool enabled = true,
    }) => HomeConnectPanel(
      radar: (size) => HomeRadar(size: size, state: RadarState.off, isp: account?.isp ?? '', dimmed: dimmed, onPick: (_) => go()),
      onTap: go,
      enabled: enabled,
      kicker: kicker,
      title: title,
      sub: sub,
      statusExtra: statusExtra,
      middle: middle,
      buttonLabel: button,
      linkLabel: link,
      onLink: onLink,
    );

    // ① 到期 / 流量用完：雷达变暗，主按钮「去续费」，下面「邀请好友」（免费试用的号不给）。
    if (quotaEnded) {
      Future<void> renew() async {
        await ref.read(connectionNotifierProvider.notifier).abortConnection();
        await ref.read(dialogNotifierProvider.notifier).showQuotaExhausted(account!, force: true);
      }

      final expDay = account?.stateSlug == 'expired' ? account!.expiryDay : '';
      return blocked(
        go: renew,
        kicker: expDay.isEmpty ? '' : '$expDay 到期',
        title: account?.stateSlug != 'expired' ? '流量已用完' : (freeTrial ? '试用已结束' : '会员已到期'),
        sub: '线路、账号都还在。续费以后点「开始连接」就行。',
        button: '去续费',
        link: freeTrial ? '' : '邀请好友，各得 1 天',
        onLink: () => openInvite(context),
      );
    }

    if (radarState == RadarState.off) {
      // ② 有账号、没套餐：直接让他选套餐（以前照常显示线路和「开始连接」，点了才弹窗）。
      if (loggedIn && account?.stateSlug == 'no_plan') {
        return blocked(go: () => context.pushNamed('purchase'), title: '尚未开通', sub: '还没有套餐，点下面选一个', button: '选择套餐');
      }
      // ③ 没账号：哪一种只看 noAccountState（跟顶上账户胶囊同一份）。
      if (!loggedIn) {
        final boot = ref.watch(guestBootstrapProvider);
        void login() => context.pushNamed('login');
        final mask = boot.knownAccountMask ?? '';
        return switch (boot.noAccountState) {
          NoAccountState.opening => blocked(
            go: () {},
            enabled: false,
            dimmed: false,
            title: '正在开通…',
            sub: '正在为你开通免费试用，稍等一下',
            button: '正在开通…',
            link: '已经有账号？登录',
            onLink: login,
          ),
          NoAccountState.knownAccount => blocked(
            go: login,
            dimmed: false,
            kicker: '这台手机登录过',
            title: mask.isEmpty ? '登录你的账号' : mask,
            sub: '输入密码就能回到这个账号',
            button: '登录',
            link: '用别的账号',
            onLink: login,
          ),
          // 服务器不给试用（名额满 / 后台关了）：重试没用，直接去注册。
          NoAccountState.unavailable => blocked(
            go: () => context.pushNamed('register'),
            dimmed: false,
            kicker: '还没有账号',
            title: '免费试用',
            sub: boot.message ?? '免费试用暂时开不了',
            button: '去注册',
            link: '已经有账号？登录',
            onLink: login,
          ),
          // 「重试 / 免费开始使用」走一键连接：第 1 步就是开号，开成了接着连。
          NoAccountState.retryable || NoAccountState.fresh => blocked(
            go: guard(connectFlow),
            dimmed: false,
            kicker: '还没有账号',
            title: '免费试用',
            sub: boot.noAccountState == NoAccountState.retryable
                ? (boot.message ?? '免费试用暂时开不了，请稍后重试')
                : '不用注册，点下面的按钮就能开始免费试用',
            button: boot.noAccountState == NoAccountState.retryable ? '重试' : '免费开始使用',
            link: '已经有账号？登录',
            onLink: login,
          ),
        };
      }
    }

    return HomeConnectPanel(
      radar: (size) => HomeRadar(
        size: size,
        state: radarState,
        step: shownStep,
        isp: account?.isp ?? '',
        onPick: (line) async {
          final set = await ref.read(lineSetProvider.future);
          if (!context.mounted) return;
          if (set.locked) {
            await promptUnlockLines(ref);
          } else if (!(connected && line.name == lineName)) {
            await chooseLine(context, ref, line);
          }
        },
      ),
      onTap: onTap,
      // 准备那几步里按钮可以点（= 取消）；引擎在起的那一下（Connecting）不能点。
      enabled:
          busy ||
          switch (connectionStatus) {
            AsyncData(value: Connected()) || AsyncData(value: Disconnected()) || AsyncError() => true,
            _ => false,
          },
      kicker: shownStep > 0
          ? '第 $shownStep/5 步 · $stepTitle'
          : connected && confirmed
          ? ''
          : connected
          ? t.connection.connecting
          : failedNow
          ? ''
          : trialing
          ? '未连接 · 免费试用中'
          : '未连接 · 上次用的线路',
      connectedDot: connected && confirmed,
      faultTag: radarState == RadarState.failed ? '连接失败' : '',
      title: shownStep > 0
          ? (lineName.isEmpty ? '正在连接…' : '正在连接 $lineName…')
          : radarState == RadarState.failed && progress.title.isNotEmpty
          ? progress.title
          : lineName.isEmpty
          ? '自动选择线路'
          : lineName,
      sub: shownStep > 0
          ? '一般 5 秒内连好。10 秒还没好会停下来告诉你原因，不会自己换线路。'
          : radarState == RadarState.failed && progress.message.isNotEmpty
          ? progress.message
          : lineDesc,
      steps: stepsBar,
      statusExtra: statusExtra,
      middle: middle,
      // 一屏只有一颗主按钮：连接中 / 已连上是描边的「取消 / 断开连接」。
      buttonLabel: busy && shownStep > 0 && shownStep <= 3
          ? '取消'
          : switch (connectionStatus) {
              AsyncData(value: Connected()) when requiresReconnect == true => t.connection.reconnect,
              AsyncData(value: Connected()) => '断开连接',
              AsyncData(value: Connecting()) => '正在连接…',
              AsyncData(value: Disconnecting()) => '正在断开…',
              _ when radarState == RadarState.failed => '重新连接',
              _ => '开始连接',
            },
      buttonOutlined: busy || (connected && requiresReconnect != true) || status is Connecting || status is Disconnecting,
      showAllLines: connected,
      secondLabel: radarState == RadarState.failed ? '换一条线路' : '',
      // 没连接时最下面那行：试用中给「看套餐」，付过钱的给「换一条线路」（跟 Windows homeThird 一样）。
      linkLabel: radarState != RadarState.off
          ? ''
          : trialing
          ? '看套餐'
          : '换一条线路',
      onLink: trialing ? () => context.pushNamed('purchase') : null,
      onAllLines: () => showLinePicker(context, ref),
      // 失败时能直接去的设置页（授权 / 通知 / 后台运行），没有就不显示。
      hintAction: shownFailed == 4 ? progress.action : SettingsAction.none,
      onRepair: shownFailed == 4 && progress.repair
          ? () => ref.read(localRepairProvider).repairAndReconnect('start')
          : null,
      secureLabel: secureLabel,
    );
  }
}

/// 主页（B 夜航 §3.3 / §3.5）：雷达占住多出来的高度（在剩余空间里居中，屏幕矮先缩雷达、最小 220），
/// 下面一组「状态 / 提示 / 活动卡 / 常用网站 / 按钮」挨在一起，大拇指够得着。
class HomeConnectPanel extends StatelessWidget {
  const HomeConnectPanel({
    super.key,
    required this.radar,
    required this.onTap,
    required this.enabled,
    required this.kicker,
    required this.title,
    required this.sub,
    required this.buttonLabel,
    this.connectedDot = false,
    this.faultTag = '',
    this.steps,
    this.statusExtra = const [],
    this.middle = const [],
    this.buttonOutlined = false,
    this.showAllLines = false,
    this.secondLabel = '',
    this.linkLabel = '',
    this.onLink,
    this.onAllLines,
    this.hintAction = SettingsAction.none,
    this.onRepair,
    this.secureLabel = '',
  });

  final Widget Function(double size) radar;
  final VoidCallback onTap;
  final bool enabled;
  final String kicker;
  final bool connectedDot;
  final String faultTag;
  final String title;
  final String sub;
  /// 一键连接的 5 段进度条（connect_progress.dart），只在连接途中 / 失败时有。
  final Widget? steps;
  final List<Widget> statusExtra;
  final List<Widget> middle;
  final String buttonLabel;
  final bool buttonOutlined;
  final bool showAllLines;
  final String secondLabel;
  final String linkLabel;

  /// 最下面那行文字链接点了做什么；不给就跟「全部线路」一样打开线路列表。
  final VoidCallback? onLink;
  final VoidCallback? onAllLines;
  final SettingsAction hintAction;
  final VoidCallback? onRepair;
  final String secureLabel;

  @override
  Widget build(BuildContext context) {
    final tk = OneRayTokens.of(context);
    final mainButton = SizedBox(
      height: 52,
      child: buttonOutlined
          ? OutlinedButton(
              key: const ValueKey('home_connection_button'),
              onPressed: enabled ? onTap : null,
              child: Text(buttonLabel, style: const TextStyle(fontSize: 15)),
            )
          : FilledButton(
              key: const ValueKey('home_connection_button'),
              onPressed: enabled ? onTap : null,
              child: Text(buttonLabel),
            ),
    );
    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, c) {
              final size = math.max(220.0, math.min(320.0, math.min(c.maxWidth - 40, c.maxHeight - 8)));
              return Center(child: radar(size));
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            children: [
              if (faultTag.isNotEmpty)
                Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                  decoration: BoxDecoration(color: tk.faultSoft, borderRadius: BorderRadius.circular(10)),
                  child: Text(faultTag, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: tk.fault)),
                ),
              if (kicker.isNotEmpty || connectedDot)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (connectedDot) ...[
                      Container(width: 8, height: 8, decoration: BoxDecoration(color: tk.ok, shape: BoxShape.circle)),
                      const SizedBox(width: 6),
                    ],
                    Text(
                      connectedDot ? '已连接' : kicker,
                      style: TextStyle(fontSize: 13, color: connectedDot ? tk.ok : tk.sub),
                    ),
                  ],
                ),
              const SizedBox(height: 2),
              Semantics(
                button: true,
                label: '全部线路',
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: onAllLines,
                  child: Text(
                    title,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: title.length > 10 ? 20 : 26, fontWeight: FontWeight.w700, color: tk.text),
                  ),
                ),
              ),
              if (sub.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(
                    sub,
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, height: 1.5, color: tk.sub),
                  ),
                ),
              if (steps != null) Padding(padding: const EdgeInsets.only(top: 8), child: steps),
              ...statusExtra,
              if (hintAction != SettingsAction.none)
                TextButton(
                  onPressed: () {
                    if (hintAction == SettingsAction.vpn) resumeAfterVpnSettings = true;
                    hintAction.open();
                  },
                  child: Text(hintAction.label),
                ),
              if (onRepair != null) TextButton(onPressed: onRepair, child: const Text('修复并重新连接')),
              if (secureLabel.isNotEmpty)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(FontAwesomeIcons.shieldHalved, size: 14, color: tk.sub),
                    const SizedBox(width: 4),
                    Text(secureLabel, style: TextStyle(fontSize: 12, color: tk.sub)),
                  ],
                ),
              ...middle,
              const SizedBox(height: 14),
              if (showAllLines)
                Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 52,
                        // 已连接时「全部线路」是这一屏的主按钮（实心强调色）。
                        child: FilledButton(onPressed: onAllLines, child: const Text('全部线路')),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: mainButton),
                  ],
                )
              else
                SizedBox(width: double.infinity, child: mainButton),
              if (secondLabel.isNotEmpty) ...[
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: tk.card),
                    onPressed: onAllLines,
                    child: Text(secondLabel),
                  ),
                ),
              ],
              if (linkLabel.isNotEmpty) TextLink(linkLabel, onTap: onLink ?? onAllLines),
            ],
          ),
        ),
      ],
    );
  }
}

/// 说明卡里的示意图：照着系统「网络连接请求」画个缩小版，「确定」高亮。
class VpnPromptSketch extends StatelessWidget {
  const VpnPromptSketch();

  // 示意图：缩小的系统窗口轮廓，正文画成灰条（一看就是插图，不是能点的窗口），只把「确定」圈出来。
  @override
  Widget build(BuildContext context) {
    final t = OneRayTokens.of(context);
    Widget bar(double w) => Container(
          width: w,
          height: 6,
          decoration: BoxDecoration(color: t.ring, borderRadius: BorderRadius.circular(3)),
        );
    return SizedBox(
      width: 236,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            decoration: BoxDecoration(
              color: t.bg,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: t.ring),
            ),
            child: Column(
              children: [
                Text('网络连接请求', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.sub)),
                const SizedBox(height: 10),
                bar(170),
                const SizedBox(height: 6),
                bar(120),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        height: 28,
                        alignment: Alignment.center,
                        child: Text('取消', style: TextStyle(fontSize: 12, color: t.sub)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Container(
                        height: 28,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: t.accSoft,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: t.acc, width: 2),
                        ),
                        child: Text('确定', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.text)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Align(
            alignment: const Alignment(0.55, 0),
            child: Text('↑ 点这个', style: TextStyle(fontSize: 11, color: t.acc, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}

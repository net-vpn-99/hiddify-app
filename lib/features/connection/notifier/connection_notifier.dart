import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:hiddify/core/haptic/haptic_service.dart';
import 'package:hiddify/core/model/remote_site_config.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/features/app/notifier/app_foreground.dart';
import 'package:hiddify/features/connection/data/connect_flow_clock.dart';
import 'package:hiddify/features/connection/data/connect_reporter.dart';
import 'package:hiddify/features/connection/data/connection_data_providers.dart';
import 'package:hiddify/features/connection/data/connection_repository.dart';
import 'package:hiddify/features/connection/data/drop_notice.dart';
import 'package:hiddify/features/connection/data/vpn_permission.dart';
import 'package:hiddify/features/connection/model/connection_failure.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/stability_notifier.dart';
import 'package:hiddify/features/home/widget/connect_progress.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/profile/notifier/profiles_update_notifier.dart';
import 'package:hiddify/features/settings/notifier/battery_optimization/battery_optimizations_notifier.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service_provider.dart';
import 'package:hiddify/hiddifycore/init_signal.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:rxdart/rxdart.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

part 'connection_notifier.g.dart';

/// 用户自己点了「连接」才算刚连上。
///
/// App 切到后台再回来，连接状态流会重放一遍（先来个空值 / 断开，再 Connected），
/// 原来那一下被当成「刚连上」，于是每次切回 App 都震一下（1.1.30 修）。记在模块级，
/// provider 重建也留得住。自动连接（快捷开关、启动自动连）不震，本来也不该震。
bool _userAskedToConnect = false;

/// 每次进入 Connected +1，让「判不通」认得出自己是不是还是那一次连接。
int _connectedSerial = 0;


@Riverpod(keepAlive: true)
class ConnectionNotifier extends _$ConnectionNotifier with AppLogger {
  /// 判出不通时人在后台：先不断开，回到前台再判（concludeNoAnswer）。
  bool _deadlineHeld = false;
  /// 这个进程里看到过「正在连接」：没看到就来了 Connected = 接回已经在跑的连接（App 重开、内核没重启）。
  bool _sawConnecting = false;
  bool _wasUp = false;
  bool _userStop = false;
  // connect() 还没返回（含失败分支里复核账号那一下网络请求）。这期间核心报的 Disconnected
  // 不能把这次尝试作废：失败分支马上要按它报 fail（10-14 C2A4：端口被占启动失败，复核账号
  // 那 0.4 秒里 Disconnected 先到、abandon 掉，服务器一条都没收到）。
  bool _connectInFlight = false;
  // 首连 tun permission denied 后等核心真的报「已停止」（状态流里的 Disconnected）再重连。
  Completer<void>? _coreStopped;
  int _heldSerial = 0;

  @override
  Stream<ConnectionStatus> build() async* {
    // 一键连接每一步的计时写进 app.log（以前安卓的点击流程一行日志都没有）。
    ConnectFlowClock.log = (line) => loggy.info(line);
    if (Platform.isIOS) {
      await _connectionRepo.setup().mapLeft((l) {
        loggy.error("error setting up connection repository", l);
      }).run();
    }

    listenSelf((previous, next) async {
      if (previous == next) return;
      if (previous case AsyncData(:final value) when !value.isConnected) {
        if (next case AsyncData(value: final Connected _)) {
          if (!_userAskedToConnect) return;
          _userAskedToConnect = false;
          await ref.read(hapticServiceProvider.notifier).heavyImpact();

          if (Platform.isAndroid && !ref.read(Preferences.storeReviewedByUser)) {
            if (await InAppReview.instance.isAvailable()) {
              InAppReview.instance.requestReview();
              ref.read(Preferences.storeReviewedByUser.notifier).update(true);
            }
          }
        }
      }
    });

    // 流量用完 / 会员到期：立刻拆隧道，别让主按钮停在「连接中」。
    // 从「还能用」变成「用尽」时自动弹一次；用户点按钮再弹走 force。
    ref.listen(panelAuthProvider.select((s) => s.account?.exhausted ?? false), (previous, next) {
      if (next != true) {
        ref.read(dialogNotifierProvider.notifier).clearQuotaNotice();
        return;
      }
      Future(() async {
        await abortConnection();
        if (previous == true) return;
        final acc = ref.read(panelAuthProvider).account;
        if (acc == null || !acc.exhausted) return;
        await ref.read(dialogNotifierProvider.notifier).showQuotaExhausted(acc);
      });
    });

    ref.listen(activeProfileProvider.select((value) => value.asData?.value), (previous, next) async {
      if (previous == null) return;
      final shouldReconnect = next == null || previous.id != next.id;
      if (shouldReconnect) {
        await reconnect(next);
      }
    });
    ref.watch(coreRestartSignalProvider);
    ref.listen<bool>(appForegroundProvider, (previous, next) {
      if (next != true || !_deadlineHeld) return;
      final serial = _heldSerial;
      _deadlineHeld = false;
      if (serial != _connectedSerial) return;
      if (state.valueOrNull is! Connected) return;
      if (ref.read(stabilityProvider).confirmed) return;
      unawaited(concludeNoAnswer());
    });
    ref.onDispose(() {
      _stopQuotaPoll();
      _deviceKeepWarm?.cancel();
      _deviceKeepWarm = null;
    });

    yield* _connectionRepo.watchConnectionStatus().doOnData((event) {
      if (event is Disconnected) {
        _coreStopped?.complete();
        _coreStopped = null;
      }
      if (event case Disconnected(connectionFailure: final _?) when PlatformUtils.isDesktop) {
        ref.read(Preferences.startedByUser.notifier).update(false);
      }
      // Connect-trace reporter (GslInviteBonus 1.17.0): the Go core is up (TUN +
      // routes) at Connected -- as far as this signal proves. The attempt is only
      // reported "ok" once a real request goes through the tunnel (stability
      // probe); if none has by 10s, it is a proxy_request failure. A teardown
      // before the attempt resolves is inconclusive -> abandon.
      final reporter = ref.read(connectReporterProvider);
      switch (event) {
        case Connecting():
          // 第 4 步（启动连接）。换线路 / 自动连这种不经过按钮的，从这里开始计时。
          ConnectFlowClock.at(4);
          noteConnectAttempt();
          reporter.markStage(ConnectReporter.stageCoreStarted);
          ref.read(deadLineProvider.notifier).state = false;
          ref.read(homeFaultProvider.notifier).state = '';
          ref.read(deadRealityProvider.notifier).state = false;
          _sawConnecting = true;
        case Connected():
          if (!ref.read(stabilityProvider).confirmed) ConnectFlowClock.at(5);
          _wasUp = true;
          _userStop = false;
          reporter.markStage(ConnectReporter.stageTunnelReady);
          _startQuotaPoll();
          _startDeviceKeepWarm();
          // 快捷开关 / 开机自动连这种原生起的连接、App 重开接回的连接也要盯住内核日志大小（App 里点的在 start 里开过）
          ref.read(hiddifyCoreServiceProvider).watchCoreLogSize();
          // 这次连接的日志从这里算起（原生起的连接不清日志，前面是上一次连接的；判不通找证据只看这之后的）
          if (!ref.read(stabilityProvider).confirmed) reporter.markCoreLogStart();
          ref.read(deadLineProvider.notifier).state = false;
          _deadlineHeld = false;
          // 还没确认过的这次必须重计。已经确认过的状态流重放不要打回「连接中」。
          if (!ref.read(stabilityProvider).confirmed) {
            ref.read(stabilityProvider.notifier).restart(attach: !_sawConnecting);
          }
          _sawConnecting = false;
          // 判通 / 判不通由 stability 按「节点有没有回数据」和正面证据来（concludeNoAnswer），不再计时。
          ++_connectedSerial;
        case Disconnected() || Disconnecting():
          var judging = false;
          if (event is Disconnected && _wasUp && !_userStop && ref.read(homeFaultProvider).isEmpty) {
            // App 里没点断开、也不是我们判断开的。先问原生那边是谁停的：通知栏「停止」、
            // 下拉快捷开关也是用户自己停的，不能说成「被系统关掉」。问完再定（上报要等它）。
            judging = true;
            unawaited(_judgeUnexpectedStop(event));
          }
          if (event is Disconnected) {
            _wasUp = false;
            // 只在真断开了才清：以前 Disconnecting 就清掉了，紧跟着的 Disconnected 以为不是他点的，
            // 自己点断开也显示「连接被系统关掉了」（10-13 运营真机）。
            _userStop = false;
          }
          _deadlineHeld = false;
          _stopQuotaPoll();
          _stopDeviceKeepWarm();
          if (!judging && !_connectInFlight) reporter.abandon();
      }
      loggy.info("connection status: ${event.format()}");
    });
  }

  /// 核心停了，但不是在 App 里点的断开、也不是我们判断开的：按原生记下的停止原因定性。
  ///  - user：通知栏「停止」/ 下拉快捷开关 —— 他自己停的，什么都不说。
  ///  - revoked：系统收回了 VPN（开了别的 VPN，或在系统设置里断开）。
  ///  - 其他（空）：核心进程没走正常停止就没了（被系统杀掉 / 崩溃）。
  Future<void> _judgeUnexpectedStop(Disconnected event) async {
    final reporter = ref.read(connectReporterProvider);
    final confirmed = ref.read(stabilityProvider).confirmed;
    final secs = ref.read(stabilityProvider.notifier).confirmedSeconds;
    final fg = ref.read(appForegroundProvider) ? '前台' : '后台';
    final probeLog = ref.read(stabilityProvider.notifier).probeLog();
    final reason = await NativeStopReason.read();
    // 问的这一下他已经又点了连接：这次断开的结论作废。
    if (state.valueOrNull is! Disconnected || ref.read(homeFaultProvider).isNotEmpty) {
      reporter.abandon();
      return;
    }
    if (reason == 'user') {
      if (confirmed) {
        reporter.abandon();
      } else if (reporter.attemptOpen) {
        unawaited(reporter.reportCancel(ConnectFlowClock.slug(5), detail: ref.read(stabilityProvider.notifier).byteDetail()));
      }
      return;
    }
    final revoked = reason == 'revoked';
    ref.read(homeFaultProvider.notifier).state = revoked ? 'revoked' : 'engine';
    final failure = event.connectionFailure;
    final why = revoked ? '系统收回 VPN（别的 VPN / 系统设置）' : '核心没走正常停止就没了';
    if (confirmed) {
      // 用着用着断的：单报一条「掉线」，并发系统通知（App 在后台也看得到）。
      unawaited(
        reporter.reportDrop(
          'engine_gone',
          '已连 $secs 秒｜$why${failure == null ? '' : '：${_truncate(failure.toString(), 120)}'}｜App 在$fg',
        ),
      );
      // 原因已知的直接说（系统收回 / 没有后台运行权限，首页卡同一句）；说不清原因的叫他回来点「帮我查一查」
      // （连接检查，首页失败卡同一套，Windows 只在 checkFault 时这么写）
      final noBackground = !revoked && ref.read(batteryOptimizationNotifierProvider).valueOrNull == false;
      unawaited(DropNotice.show(revoked
          ? '手机系统断开了光速雷达的 VPN 连接。手机上开着别的 VPN 的话，先关掉它，再打开光速雷达点「连接」'
          : noBackground
          ? '光速雷达没有「后台运行」权限，手机省电时停掉了它的连接。打开光速雷达，点「允许后台运行」'
          : '连接意外断开了。打开光速雷达，点「帮我查一查」'));
      reporter.abandon();
    } else if (reporter.attemptOpen) {
      // 第 5 步还没确认网通核心就停了：这是一次失败（以前直接丢掉，后台看不到）。
      reporter.captureCoreLogSync();
      unawaited(
        reporter.reportFailure(
          '确认网通前$why${failure == null ? '' : '：$failure'}',
          forcedStage: 'engine_gone',
          appForeground: ref.read(appForegroundProvider),
          probeLog: probeLog,
        ),
      );
    }
  }

  /// 还没确认通，检测连接一条条被结束、节点一个字节没回（stability 数够了）：按正面证据下结论、停下说原因。
  /// 不再按「10 秒内有没有成功」判（10-19 运营定，两端统一，Windows ConnectionController::concludeNoAnswer）。
  /// **不自动换线**。人在后台时先不下结论（手机会限制后台联网），回到前台再判。
  Future<void> concludeNoAnswer() async {
    final serial = _connectedSerial;
    if (state.valueOrNull is! Connected) return;
    if (ref.read(stabilityProvider).confirmed) return;
    if (!ref.read(appForegroundProvider)) {
      _deadlineHeld = true;
      _heldSerial = serial;
      return;
    }
    final stability = ref.read(stabilityProvider.notifier);
    // 最后现读一次字节：这期间节点回了数据（比如在后台等过一阵）就是通的，不下结论。
    if (await stability.sentDataNow()) return;
    if (serial != _connectedSerial || state.valueOrNull is! Connected) return;
    final reporter = ref.read(connectReporterProvider);
    // 节点没认出我们（REALITY 校验失败）是线路配置的问题，不是用户的；其余只能说「节点结束了连接」，
    // 断开后直连节点的结果再细分（被挡 / 两条线都这样 = 原因不明）。
    final reality = await reporter.coreLogHas('reality verification failed');
    ref.read(deadRealityProvider.notifier).state = reality;
    // 这次真的报了失败，直连节点的结果才补进去（没报就别去改上一条不相干的记录）。
    final reported = reporter.attemptOpen;
    if (reported) {
      reporter.captureCoreLogSync();
      // 先看是不是这段时间流量用完了。是账号原因：sync 会触发上面的 listen，拆隧道并弹窗，这里不要记成节点失败。
      if (await _accountExhaustedAfterFailure(reporter)) return;
      await reporter.reportFailure(
        '节点一个字节没回，${stability.zeroEnds} 个检测连接被结束｜${reality ? 'REALITY 校验失败' : '节点结束了连接'}｜${stability.zeroWhy()}',
        forcedStage: 'dead_tunnel',
        fault: reality ? 'reality_mismatch' : 'dead_tunnel',
        probeNode: false,
        appForeground: ref.read(appForegroundProvider),
        probeLog: ref.read(stabilityProvider.notifier).probeLog(),
      );
    }
    // 等上报的这一会儿里用户可能自己断了 / 重连了，或者恰好通了。
    if (serial != _connectedSerial || state.valueOrNull is! Connected) return;
    if (ref.read(stabilityProvider).confirmed) return;
    ref.read(deadLineProvider.notifier).state = true;
    await abortConnection();
    await _probeDeadLineDirect(reporter, serial, amend: reported);
  }

  /// 「这条线路现在不通」断开之后：绕开 VPN 直接碰节点 + 接口服务器 + 百度。只把查实的直接改过来（没上网）；
  /// 其余（这个网络挡了线路、两条线都不回数据）不再靠「试了几条」的计数猜，交给连接检查当场查
  /// （docs/计划/连接检查.md 第八节，Windows onNodeProbed 同一套）。直连结果照样补进刚才那条失败记录。
  /// [serial] = 判不通的那一次连接：查的这一会儿里他又连了（或者关掉了这张卡），结果就不往首页上写了。
  Future<void> _probeDeadLineDirect(ConnectReporter reporter, int serial, {bool amend = false}) async {
    final host = reporter.lastNodeHost;
    if (host == null) return;
    bool stillThisFailure() =>
        serial == _connectedSerial && state.valueOrNull is Disconnected && ref.read(deadLineProvider);
    // 先重拉一次账号（里面带维修中名单）：这条在维修，首页就说「正在维修」（connect_issue_card），
    // 也不算进「试了几条都没回应」——那会说成换线路也没用。
    try {
      await ref.read(panelAuthProvider.notifier).syncAccountQuietly();
    } catch (_) {}
    if (ref.read(panelAuthProvider).account?.isLineDown(ref.read(Preferences.lastNodeName)) ?? false) return;
    final r = await reporter.probeLastNodeDirect();
    // 节点和接口服务器、百度都碰不到：是这台手机没上网，不是这条线路的事（两端统一，Windows onNodeProbed）。
    if (!r.nodeOk && !r.online) {
      if (stillThisFailure()) ref.read(homeFaultProvider.notifier).state = 'offline';
      if (amend) unawaited(reporter.amendFailure(r.tcp, fault: 'offline'));
      return;
    }
    // 直连节点的结果补进刚才那条失败记录（同一个 attempt_id，跟 Windows 一样）：失败先发、不等它。
    if (amend) unawaited(reporter.amendFailure(r.tcp));
  }

  ConnectionRepository get _connectionRepo => ref.read(connectionRepositoryProvider);

  Timer? _quotaPoll;
  bool _quotaInflight = false;
  int _quotaFailStreak = 0;

  void _startQuotaPoll() {
    if (_quotaPoll != null) return;
    unawaited(RemoteSiteConfig.ensureLoaded());
    _scheduleQuotaPoll();
  }

  void _scheduleQuotaPoll() {
    _quotaPoll?.cancel();
    final delay = _jittered(RemoteSiteConfig.quotaPoll, _quotaFailStreak, cap: const Duration(minutes: 3));
    _quotaPoll = Timer(delay, () async {
      if (_quotaInflight) {
        if (_quotaPoll != null) _scheduleQuotaPoll();
        return;
      }
      _quotaInflight = true;
      try {
        final acc = await ref.read(panelAuthProvider.notifier).fetchAccount();
        _quotaFailStreak = acc != null ? 0 : (_quotaFailStreak + 1).clamp(0, 5);
      } catch (_) {
        _quotaFailStreak = (_quotaFailStreak + 1).clamp(0, 5);
      } finally {
        _quotaInflight = false;
        if (_quotaPoll != null) _scheduleQuotaPoll();
      }
    });
  }

  void _stopQuotaPoll() {
    _quotaPoll?.cancel();
    _quotaPoll = null;
    _quotaFailStreak = 0;
  }

  Timer? _deviceKeepWarm;
  bool _deviceInflight = false;

  // 设备闸：隧道连着时约每 4 分钟 claim 一次（connected=true），跟 Windows
  // keep-warm 同一个道理——只 claim 一次的话，设备闸自己不知道隧道后来又
  // 断了，「在连」会一直卡在上次的值。
  void _startDeviceKeepWarm() {
    if (!Platform.isAndroid || _deviceKeepWarm != null) return;
    _scheduleDeviceKeepWarm();
  }

  void _scheduleDeviceKeepWarm() {
    _deviceKeepWarm?.cancel();
    final delay = _jittered(const Duration(minutes: 4), 0, cap: const Duration(minutes: 6));
    _deviceKeepWarm = Timer(delay, () async {
      if (_deviceInflight) {
        if (_deviceKeepWarm != null) _scheduleDeviceKeepWarm();
        return;
      }
      _deviceInflight = true;
      try {
        await ref.read(panelAuthProvider.notifier).claimDevice(connected: true);
      } catch (_) {
      } finally {
        _deviceInflight = false;
        if (_deviceKeepWarm != null) _scheduleDeviceKeepWarm();
      }
    });
  }

  Duration _jittered(Duration base, int failStreak, {required Duration cap}) {
    var ms = base.inMilliseconds;
    for (var i = 0; i < failStreak.clamp(0, 4); i++) {
      ms = min(ms * 2, cap.inMilliseconds);
    }
    final span = max(250, ms ~/ 5);
    final delta = Random().nextInt(span * 2 + 1) - span;
    return Duration(milliseconds: max(1000, ms + delta));
  }

  // 断开（用户主动 / 失败 / 账号原因）一律补发一次 connected=false——失败
  // 忽略，不影响断开流程。哪怕从没进入过 Connected（keep-warm 没起来过）
  // 也要发，防止 connectionRepo.connect 之前的那次 connected=true claim
  // 因为随后连接失败而永远卡在「在连」。
  void _stopDeviceKeepWarm() {
    _deviceKeepWarm?.cancel();
    _deviceKeepWarm = null;
    if (Platform.isAndroid) {
      unawaited(ref.read(panelAuthProvider.notifier).claimDevice(connected: false));
    }
  }

  Future<void> mayConnect() async {
    if (state case AsyncData(:final value)) {
      if (value case Disconnected()) return _connect();
    }
  }

  Future<void> toggleConnection() async {
    final haptic = ref.read(hapticServiceProvider.notifier);
    if (state case AsyncError()) {
      _userAskedToConnect = true;
      await haptic.lightImpact();
      await _connect();
    } else if (state case AsyncData(:final value)) {
      switch (value) {
        case Disconnected():
          _userAskedToConnect = true;
          await haptic.lightImpact();
          await ref.read(Preferences.startedByUser.notifier).update(true);
          await _connect();
        case Connected():
          // default:
          // 还没确认网通（第 5 步）就点了：这是取消，记一条（看大家在哪一步等不及）。
          final reporter = ref.read(connectReporterProvider);
          if (!ref.read(stabilityProvider).confirmed && reporter.attemptOpen) {
            unawaited(reporter.reportCancel(ConnectFlowClock.slug(5), detail: ref.read(stabilityProvider.notifier).byteDetail()));
          }
          _userAskedToConnect = false;
          await haptic.mediumImpact();
          await ref.read(Preferences.startedByUser.notifier).update(false);
          await _disconnect();
        default:
          loggy.warning("switching status, debounce");
      }
    }
  }

  Future<void> reconnect(ProfileEntity? profile) async {
    if (state case AsyncData(:final value) when value == const Connected()) {
      if (profile == null) {
        loggy.info("no active profile, disconnecting");
        return _disconnect();
      }
      loggy.info("active profile changed, reconnecting");
      _userAskedToConnect = true;
      await ref.read(Preferences.startedByUser.notifier).update(true);
      await _connectionRepo.reconnect(profile, ref.read(Preferences.disableMemoryLimit)).mapLeft((err) async {
        loggy.warning("error reconnecting", err);
        state = AsyncError(err, StackTrace.current);
        // 给客户看「下一步怎么做」，原始报错只进 app.log。
        final copy = connectFailProgress(err);
        await ref.read(dialogNotifierProvider.notifier).showCustomAlert(title: copy.title, message: copy.message);
      }).run();
    }
  }

  Future<void> abortConnection() async {
    if (state case AsyncData(:final value)) {
      switch (value) {
        case Connected() || Connecting():
          loggy.debug("aborting connection");
          await _disconnect();
        default:
      }
    }
  }

  final _singleStart = SingleCall();

  Future<void> _connect() async {
    _singleStart.run(
      () async {
        await _connectThrottled();
      },
      onIgnored: () {
        loggy.debug("connect called while another connect/disconnect is still running, ignoring");
      },
    );
  }

  /// 连接失败后复核账号：若是流量用完 / 会员到期，当「账号原因」处理（不记节点失败），
  /// 返回 true 表示已按账号原因处理完。
  Future<bool> _accountExhaustedAfterFailure(ConnectReporter reporter) async {
    try {
      await ref.read(panelAuthProvider.notifier).syncAccountQuietly();
    } catch (_) {}
    final acc = ref.read(panelAuthProvider).account;
    if (acc != null && acc.exhausted) {
      reporter.abandon();
      return true;
    }
    return false;
  }

  Future<void> _connectThrottled() async {
    final reporter = ref.read(connectReporterProvider);
    final activeProfile = await ref.read(activeProfileProvider.future);
    if (activeProfile == null) {
      loggy.info("no active profile, not connecting");
      // 没订阅最常见的原因是试用 / 会员到期或流量用完（到期后订阅接口返回空、
      // 本地订阅被清掉）。复核一次账号，是账号原因就引导续费，别只报「无节点」。
      try {
        await ref.read(panelAuthProvider.notifier).syncAccountQuietly();
      } catch (_) {}
      final acc = ref.read(panelAuthProvider).account;
      if (acc != null && (acc.exhausted || acc.stateSlug == 'no_plan')) {
        await ref.read(dialogNotifierProvider.notifier).showQuotaExhausted(acc, force: true);
        await ref.read(Preferences.startedByUser.notifier).update(false);
        return;
      }
      // Pressed connect with a plan but no profile: the subscription fetch is
      // why. reportNoRoute() reads runtime/sub-fetch.json for the reason.
      unawaited(reporter.reportNoRoute());
      return;
    }

    // 流量用完 / 会员到期：不发起这次注定失败的连接（只会在连接轨迹里留一条 fail、
    // 把节点失败率带脏，用户看到的还是「连接失败」于是一直重试）。直接引导续费。
    final acc = ref.read(panelAuthProvider).account;
    if (acc != null && acc.exhausted) {
      await ref.read(dialogNotifierProvider.notifier).showQuotaExhausted(acc, force: true);
      await ref.read(Preferences.startedByUser.notifier).update(false);
      return;
    }
    // 流量用量本地可能已过时——连接前静默补一次（不阻塞本次；真超额了下次点击会拦）。
    unawaited(ref.read(panelAuthProvider.notifier).syncAccountQuietly());

    // 设备闸：真正拨号前 claim 一次（connected=true）。401/403 是网关的决定性
    // 拒绝——不要连；网络问题/404/5xx 已经在 claimDevice 内部 fail-open 成
    // allowed=true，不会走到这里拦人。
    if (Platform.isAndroid) {
      final claim = await ref.read(panelAuthProvider.notifier).claimDevice(connected: true);
      if (!claim.allowed) {
        await ref.read(dialogNotifierProvider.notifier).showCustomAlert(message: claim.blockMessage ?? '设备校验失败，请稍后重试');
        await ref.read(Preferences.startedByUser.notifier).update(false);
        return;
      }
    }

    await reporter.beginAttempt(activeProfile.name, preferredLine: ref.read(Preferences.preferredLineName));
    _connectInFlight = true;
    try {
      var outcome = await _connectionRepo.connect(activeProfile, ref.read(Preferences.disableMemoryLimit)).run();
      // 核心建网卡被拒（tun permission denied）：刚在系统弹窗里允许 VPN 的新用户最常见（OPPO / vivo /
      // 真我 / 华为：允许之前就起来的后台核心建不了网卡），刚断开马上再连也会碰到。核心随即停下，
      // 再连一次就好。这时 VPN 授权必须已经有了，否则是真没授权，照常报。
      // 必须等核心在状态流里报「已停止」再连：connect() 返回比 Disconnected 早几毫秒，1.1.64 在返回那一刻
      // 就看状态，永远还是「连接中」，自动重连一次都没触发过（10-16～17 新用户 8 个首连失败都要自己再点）。
      // 等待从 connect() 返回这一刻开始（同步挂上，中间插不进状态事件）：授权弹窗那会儿状态流里也闪过
      // 一次 Disconnected，从连接前就等会被它提前放行。15 秒是放弃线：核心一直不报停就不重连，照常报这次失败。
      final firstErr = outcome.getLeft().toNullable();
      final stopped = firstErr != null && state.valueOrNull is! Disconnected ? (_coreStopped = Completer<void>()) : null;
      if (firstErr != null &&
          firstErr.toString().contains('configure tun interface: permission denied') &&
          await VpnPermission.granted()) {
        final didStop = stopped == null ||
            await stopped.future.then((_) => true).timeout(const Duration(seconds: 15), onTimeout: () => false);
        if (didStop) {
          loggy.info('tun permission denied, core stopped, starting once more');
          _coreStopped = null;
          outcome = await _connectionRepo.connect(activeProfile, ref.read(Preferences.disableMemoryLimit)).run();
        } else {
          loggy.info('tun permission denied, core did not report stopped in 15s, not retrying');
        }
      }
      _coreStopped = null;
      final result = outcome.mapLeft((ConnectionFailure err) async {
        loggy.warning("error connecting", err);
        //Go err is not normal object to see the go errors are string and need to be dumped
        // MissingWarpLicense = user declined a prompt, not a connectivity failure.
        if (err is MissingWarpLicense) {
          reporter.abandon();
        } else {
          // snapshot box.log NOW, synchronously, before any retry start() truncates it
          reporter.captureCoreLogSync();
          // 失败也可能只是这次连接期间流量用完了：复核账号，是账号原因就别记成节点失败，
          // 直接弹「流量用完 · 去续费」而不是笼统的连接错误。
          if (await _accountExhaustedAfterFailure(reporter)) {
            await ref.read(Preferences.startedByUser.notifier).update(false);
            await abortConnection();
            return;
          }
          unawaited(ref.read(foregroundProfilesUpdateNotifierProvider.notifier).trigger());
          // 用 typed ConnectionFailure 判断，别只在字符串里猜关键词——拒绝 VPN 授权这种
          // 有专门的类型（MissingVpnPermission），直接给出准确的 vpn_permission/note，
          // 不用等服务端/人工再去猜「vivo 所以是权限问题」。
          final (vpnPerm, tunnelNote) = switch (err) {
            MissingVpnPermission() => ('denied', '用户拒绝了 VPN 连接授权弹窗'),
            MissingPrivilege() => ('unknown', '系统权限不足（不是 VPN 授权弹窗，是别的系统限制）'),
            MissingNotificationPermission() => ('granted', '缺通知权限，前台服务起不来（VPN 授权本身没问题）'),
            BackgroundCoreNotAvailable() => ('granted', '后台核心服务没能启动（可能被系统省电策略杀了）'),
            _ => ('granted', 'start() 失败：${_truncate(err.toString(), 160)}'),
          };
          unawaited(reporter.reportFailure(err.toString(), tunnelVpnPermission: vpnPerm, tunnelNote: tunnelNote));
        }
        // 原来弹 Hiddify 的报错框（原始报错，客户看不懂）。现在进度条停在第 4 步，
        // 写「下一步怎么做」（connectFailCopy，两端统一）；原始报错只进上报和 app.log。
        ref.read(connectProgressProvider.notifier).state = connectFailProgress(err);
        loggy.warning(err);
        if (err.toString().contains("panic")) {
          await Sentry.captureException(Exception(err.toString()));
        }
        await ref.read(Preferences.startedByUser.notifier).update(false);
        state = AsyncError(err, StackTrace.current);
      });
      // mapLeft 的回调是 async：返回时它还没跑完（复核账号、上报都在里面），要等它。
      final pending = result.match((f) => f, (_) => null);
      if (pending != null) await pending;
    } finally {
      _connectInFlight = false;
    }
  }

  Future<void> _disconnect() async {
    _userStop = true;
    ref.read(connectReporterProvider).abandon();
    await _connectionRepo.disconnect().mapLeft((err) {
      loggy.warning("error disconnecting", err);
      ref.read(dialogNotifierProvider.notifier).showCustomAlert(title: '断开没成功', message: '请再点一下按钮。如果还不行，请把光速雷达关掉再打开');
      state = AsyncError(err, StackTrace.current);
    }).run();
  }
}

@Riverpod(keepAlive: true)
Future<bool> serviceRunning(Ref ref) async {
  // ref.watch(coreRestartSignalProvider);
  return await ref
      .watch(connectionNotifierProvider.selectAsync((data) => data.isConnected))
      .onError((error, stackTrace) => false);
}

/// Rune-safe truncate (see ConnectReporter._truncateRunes for why not `.substring`).
String _truncate(String s, int maxChars) {
  if (s.length <= maxChars) return s;
  final runes = s.runes.toList();
  return runes.length <= maxChars ? s : String.fromCharCodes(runes.take(maxChars));
}

class SingleCall {
  bool _running = false;

  Future<T> run<T>(Future<T> Function() task, {required T onIgnored}) async {
    if (_running) return onIgnored;

    _running = true;
    try {
      return await task();
    } finally {
      _running = false;
    }
  }
}

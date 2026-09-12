import 'dart:async';
import 'dart:io';

import 'package:hiddify/core/haptic/haptic_service.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/features/connection/data/connect_reporter.dart';
import 'package:hiddify/features/connection/data/connection_data_providers.dart';
import 'package:hiddify/features/connection/data/connection_repository.dart';
import 'package:hiddify/features/connection/model/connection_failure.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/hiddifycore/init_signal.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:rxdart/rxdart.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

part 'connection_notifier.g.dart';

@Riverpod(keepAlive: true)
class ConnectionNotifier extends _$ConnectionNotifier with AppLogger {
  @override
  Stream<ConnectionStatus> build() async* {
    if (Platform.isIOS) {
      await _connectionRepo.setup().mapLeft((l) {
        loggy.error("error setting up connection repository", l);
      }).run();
    }

    listenSelf((previous, next) async {
      if (previous == next) return;
      if (previous case AsyncData(:final value) when !value.isConnected) {
        if (next case AsyncData(value: final Connected _)) {
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
    ref.onDispose(_stopQuotaPoll);

    yield* _connectionRepo.watchConnectionStatus().doOnData((event) {
      if (event case Disconnected(connectionFailure: final _?) when PlatformUtils.isDesktop) {
        ref.read(Preferences.startedByUser.notifier).update(false);
      }
      // Connect-trace reporter (GslInviteBonus 1.17.0): the Go core is up (TUN +
      // routes) at Connected -- as far as this signal proves. The attempt is only
      // reported "ok" once a real request goes through the tunnel (stability
      // probe); if none has by 15s, it is a proxy_request failure. A teardown
      // before the attempt resolves is inconclusive -> abandon.
      final reporter = ref.read(connectReporterProvider);
      switch (event) {
        case Connecting():
          reporter.markStage(ConnectReporter.stageCoreStarted);
        case Connected():
          reporter.markStage(ConnectReporter.stageTunnelReady);
          _startQuotaPoll();
          _startDeviceKeepWarm();
          Future<void>.delayed(const Duration(seconds: 15), () async {
            if (!reporter.attemptOpen) return;
            reporter.captureCoreLogSync();
            // 连上了但 15 秒没有一次成功的隧道请求 —— 先看是不是这段时间流量用完了。
            // 是账号原因：sync 会触发上面的 listen，拆隧道并弹窗，这里不要记成节点失败。
            if (await _accountExhaustedAfterFailure(reporter)) return;
            // 这就是 proxy_request 阶段失败的定义本身（隧道已建好，只是没有一次请求
            // 成功穿过去），不用再让 _mapFailStage 去猜字符串——这条消息本来就不含任何
            // 关键词，猜的话会落进「reached>=tunnelReady 就默认 node_tcp」的兜底，
            // 明明 TCP 大概率是通的，却被标成"没通"。
            await reporter.reportFailure(
              "连接后 15 秒内没有一次通过隧道的请求成功（proxy_request）",
              forcedStage: 'proxy_request',
            );
          });
        case Disconnected() || Disconnecting():
          _stopQuotaPoll();
          _stopDeviceKeepWarm();
          reporter.abandon();
      }
      loggy.info("connection status: ${event.format()}");
    });
  }

  ConnectionRepository get _connectionRepo => ref.read(connectionRepositoryProvider);

  Timer? _quotaPoll;

  void _startQuotaPoll() {
    if (_quotaPoll != null) return;
    _quotaPoll = Timer.periodic(const Duration(seconds: 45), (_) {
      unawaited(ref.read(panelAuthProvider.notifier).syncAccountQuietly());
    });
  }

  void _stopQuotaPoll() {
    _quotaPoll?.cancel();
    _quotaPoll = null;
  }

  Timer? _deviceKeepWarm;

  // 设备闸：隧道连着时每 4 分钟 claim 一次（connected=true），跟 Windows
  // keep-warm 同一个道理——只 claim 一次的话，设备闸自己不知道隧道后来又
  // 断了，「在连」会一直卡在上次的值。
  void _startDeviceKeepWarm() {
    if (!Platform.isAndroid || _deviceKeepWarm != null) return;
    _deviceKeepWarm = Timer.periodic(const Duration(minutes: 4), (_) {
      unawaited(ref.read(panelAuthProvider.notifier).claimDevice(connected: true));
    });
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
      await haptic.lightImpact();
      await _connect();
    } else if (state case AsyncData(:final value)) {
      switch (value) {
        case Disconnected():
          await haptic.lightImpact();
          await ref.read(Preferences.startedByUser.notifier).update(true);
          await _connect();
        case Connected():
          // default:
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
      await ref.read(Preferences.startedByUser.notifier).update(true);
      await _connectionRepo.reconnect(profile, ref.read(Preferences.disableMemoryLimit)).mapLeft((err) async {
        loggy.warning("error reconnecting", err);
        state = AsyncError(err, StackTrace.current);
        await ref
            .read(dialogNotifierProvider.notifier)
            .showCustomAlertFromErr(err.present(ref.read(translationsProvider).requireValue));
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
        await ref
            .read(dialogNotifierProvider.notifier)
            .showCustomAlert(message: claim.blockMessage ?? '设备校验失败，请稍后重试');
        await ref.read(Preferences.startedByUser.notifier).update(false);
        return;
      }
    }

    await reporter.beginAttempt(
      activeProfile.name,
      preferredLine: ref.read(Preferences.preferredLineName),
    );
    await _connectionRepo.connect(activeProfile, ref.read(Preferences.disableMemoryLimit)).mapLeft((
      ConnectionFailure err,
    ) async {
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
        unawaited(reporter.reportFailure(
          err.toString(),
          tunnelVpnPermission: vpnPerm,
          tunnelNote: tunnelNote,
        ));
      }
      await ref
          .read(dialogNotifierProvider.notifier)
          .showCustomAlertFromErr(err.present(ref.read(translationsProvider).requireValue));
      loggy.warning(err);
      if (err.toString().contains("panic")) {
        await Sentry.captureException(Exception(err.toString()));
      }
      await ref.read(Preferences.startedByUser.notifier).update(false);
      state = AsyncError(err, StackTrace.current);
    }).run();
  }

  Future<void> _disconnect() async {
    ref.read(connectReporterProvider).abandon();
    await _connectionRepo.disconnect().mapLeft((err) {
      loggy.warning("error disconnecting", err);
      ref
          .read(dialogNotifierProvider.notifier)
          .showCustomAlertFromErr(err.present(ref.read(translationsProvider).requireValue));
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

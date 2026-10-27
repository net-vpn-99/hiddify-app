import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:fpdart/fpdart.dart';
import 'package:grpc/grpc.dart';
import 'package:hiddify/core/directories/directories_provider.dart';
import 'package:hiddify/core/model/directories.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/connection/model/connection_failure.dart';
import 'package:hiddify/features/log/data/log_data_providers.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/hiddifycore/core_interface/core_interface.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcommon/common.pb.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore_service.pbgrpc.dart';
import 'package:hiddify/hiddifycore/init_signal.dart';
import 'package:hiddify/singbox/model/singbox_config_option.dart';
import 'package:hiddify/features/log/model/log_level.dart' as config_log_level;
import 'package:hiddify/singbox/model/core_status.dart';
import 'package:hiddify/singbox/model/warp_account.dart';

import 'package:hiddify/hiddifycore/core_interface/core_interface_wrapper_stub.dart'
    if (dart.library.io) 'package:hiddify/hiddifycore/core_interface/core_interface_wrapper.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:hiddify/utils/platform_utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:loggy/loggy.dart' as loggyl;
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:rxdart/rxdart.dart';

class HiddifyCoreService with InfraLogger {
  HiddifyCoreService(this.ref);
  final Ref ref;

  // CoreHiddifyCoreService() {}
  final core = getCoreInterface();

  CoreStatus currentState = const CoreStatus.stopped();
  final statusController = BehaviorSubject<CoreStatus>();

  /// 状态通道是不是我们自己关掉的（切到后台时的 closeFront、重新订阅时取消旧的）。
  /// 是的话，通道断开不代表 VPN 停了，不能改 currentState。
  bool _statusClosedByUs = false;
  final logController = BehaviorSubject<List<LogMessage>>();
  final CallOptions? grpcOptions = null; //CallOptions(timeout: const Duration(milliseconds: 10000));
  final Map<String, StreamSubscription?> subscriptions = {};
  List<OutboundGroup> latest = [];

  Future<void> init() async {
    await setup()
        .mapLeft((e) {
          loggy.error(e);
          if (PlatformUtils.isIOS) return;
          // 回前台时前台这条通道偶尔没答上，原文是 gRPC Error (code: 14, UNAVAILABLE)。
          // 隧道在另一个进程里，上网和节点不受影响。原来把这句原文弹成红条，用户看不懂，也做不了什么。
          if (e.contains('code: 14') || e.contains('UNAVAILABLE')) return;
          statusController.add(const CoreStatus.stopped());
        })
        .map((_) {
          loggy.info("Hiddify-core setup done");
          ref.read(coreRestartSignalProvider.notifier).restart();
        })
        .run();
  }

  /// validates config by path and save it
  ///
  /// [path] is used to save validated config
  /// [tempPath] includes base config, possibly invalid
  /// [debug] indicates if debug mode (avoid in prod)

  TaskEither<String, Unit> validateConfigByPath(String path, String tempPath, bool debug) {
    return TaskEither(() async {
      try {
        final response = await core.fgClient.parse(ParseRequest(tempPath: tempPath, configPath: path, debug: false));
        if (response.responseCode != ResponseCode.OK) return left("${response.responseCode} ${response.message}");
      } catch (e) {
        await setup().run();
        final response = await core.fgClient.parse(ParseRequest(tempPath: tempPath, configPath: path, debug: false));
        if (response.responseCode != ResponseCode.OK) return left("${response.responseCode} ${response.message}");
      }
      return right(unit);
    });
  }

  TaskEither<String, String> generateFullConfigByPath(String path) {
    return TaskEither(() async {
      final response = await core.fgClient.parse(ParseRequest(configPath: path, debug: false));
      if (response.responseCode != ResponseCode.OK) return left("${response.responseCode} ${response.message}");
      return right(response.content);
    });
  }

  TaskEither<String, Unit> setup() {
    return TaskEither(() async {
      try {
        final directories = ref.read(appDirectoriesProvider).requireValue;
        final debug = ref.read(debugModeNotifierProvider);
        final setupResponse = await core.setup(directories, debug, 3);

        if (setupResponse.isNotEmpty) {
          return left(setupResponse);
        }

        await startListeningLogs("fg", core.fgClient);
        // await startListeningStatus("fg", core.fgClient);
        if (!core.isSingleChannel()) {
          await startListeningLogs("bg", core.bgClient);
        }
        statusController.add(currentState);
        await startListeningStatus("bg", core.bgClient);
        // ref.read(coreRestartSignalProvider.notifier).restart();
        return right(unit);
      } catch (e) {
        return left(e.toString());
      }
    });
  }

  TaskEither<String, Unit> changeOptions(SingboxConfigOption options) {
    return TaskEither(() async {
      loggy.debug("changing options");
      // latestOptions = options;
      try {
        final res = await core.fgClient.changeHiddifySettings(
          ChangeHiddifySettingsRequest(hiddifySettingsJson: jsonEncode(options.toJson())),
        );
        if (res.messageType != MessageType.EMPTY) return left("${res.messageType} ${res.message}");
        await core.bgClient.changeHiddifySettings(
          ChangeHiddifySettingsRequest(hiddifySettingsJson: jsonEncode(options.toJson())),
        );
      } on GrpcError catch (e) {
        if (e.code == StatusCode.unavailable) {
          loggy.debug("background core is not started yet! $e");
        } else {
          rethrow;
        }
      }

      return right(unit);
    });
  }

  /// 内核日志（data/box.log）是一直往后追加的，info 级每条连接一行。每次连接前清空（这次连接的日志从头记，
  /// 失败诊断、「走错了」读的都是这次的），连着时每 10 分钟看一眼，超过 16MB 也清空，免得占满手机。
  Timer? _coreLogGuard;

  /// 连着时盯住内核日志大小（每 10 分钟看一眼，超过 16MB 清空）。App 里点的连接在 [start] 里开；
  /// 快捷开关 / 开机自动连这种原生那边起的、App 重开接回已在跑的连接，在连上时开（connection_notifier）。
  void watchCoreLogSize() {
    _coreLogGuard ??= Timer.periodic(const Duration(minutes: 10), (_) => _truncateCoreLog(over: 16 << 20));
  }

  /// 超过 [over] 字节就清空（异步，不卡界面）。定时检查断开时停掉，下次连接再开。
  Future<void> _truncateCoreLog({int over = 0}) async {
    try {
      final f = ref.read(logPathResolverProvider).coreFile();
      if (!await f.exists() || await f.length() <= over) return;
      final raf = await f.open(mode: FileMode.append);
      await raf.truncate(0);
      await raf.close();
    } catch (_) {}
  }

  TaskEither<ConnectionFailure, Unit> start(String path, String name, bool disableMemoryLimit) {
    return TaskEither(() async {
      statusController.add(currentState = const CoreStatus.starting());
      await _truncateCoreLog();
      watchCoreLogSize();
      loggy.debug("starting");
      final background = await core.setupBackground(path, name);
      if (background != const CoreStatus.started()) {
        statusController.add(currentState = const CoreStatus.stopped());
        return left(background.getCoreAlert() ?? const ConnectionFailure.unexpected("failed to start core"));
      }
      if (!core.isSingleChannel()) {
        await startListeningLogs("bg", core.bgClient);
        await startListeningStatus("bg", core.bgClient);
      }
      // if (latestOptions != null) {
      //   await core.bgClient.changeHiddifySettings(
      //     ChangeHiddifySettingsRequest(
      //       hiddifySettingsJson: jsonEncode(latestOptions!.toJson()),
      //     ),
      //   );
      // }
      // final content = await File(path).readAsString();
      // loggy.debug("starting with content: $content");
      try {
        final request = StartRequest(
          configPath: path,
          configName: name,
          // configContent: content,
          disableMemoryLimit: disableMemoryLimit,
        );
        final res = await core.bgClient.start(request);
        ref.read(coreRestartSignalProvider.notifier).restart();
        if (res.messageType != MessageType.ALREADY_STARTED && res.messageType != MessageType.EMPTY) {
          final alert = res.message.contains("denied") ? CoreAlert.requestVPNPermission : CoreAlert.startFailed;
          currentState = CoreStatus.stopped(
            alert: alert,
            message: "failed to start core ${res.messageType} ${res.message}",
          );

          statusController.add(currentState);

          return left(
            currentState.getCoreAlert() ??
                ConnectionFailure.unexpected("failed to start core ${res.messageType} ${res.message}"),
          );
        }
      } on GrpcError catch (e) {
        loggy.error("failed to start bg core: $e");
        ref.read(coreRestartSignalProvider.notifier).restart();
        if (e.code == StatusCode.unavailable) {
          return left(const ConnectionFailure.unexpected("background core is not started yet!"));
        }
        // throw InvalidConfig(e.message);
        // throw DioException.connectionError(requestOptions: RequestOptions(), reason: e.codeName, error: e);

        // throw DioException(requestOptions: RequestOptions(), error: e);
        return left(ConnectionFailure.unexpected("failed to start background core (${e.codeName}: ${e.message})"));
      }

      // if (res.messageType != MessageType.EMPTY) return left(res);

      return right(unit);
    });
  }

  TaskEither<String, Unit> stop() {
    return TaskEither(() async {
      loggy.debug("stopping");
      var errMsg = "";
      try {
        final res = await core.bgClient.stop(Empty());
      } on GrpcError catch (e) {
        if (e.code == StatusCode.unknown && !(e.message?.contains("HTTP/2") ?? false)) {
          errMsg = e.message ?? "failed to stop core: $e";

          loggy.error("failed to stop bg core: $e");
        }
      } catch (e) {
        loggy.error("failed to stop bg core: $e");
        // left("failed to stop core: $e");
      }
      if (!await core.stop()) {}
      _coreLogGuard?.cancel();
      _coreLogGuard = null;
      statusController.add(currentState = const CoreStatus.stopped());
      if (errMsg.isNotEmpty) return left(errMsg);
      return right(unit);
    });
  }

  TaskEither<String, Unit> restart(String path, String name, bool disableMemoryLimit) {
    return TaskEither(() async {
      loggy.debug("restarting");
      // if (!await core.restart(path, name)) {
      try {
        final res = await core.bgClient.restart(
          StartRequest(configPath: path, configName: name, disableMemoryLimit: disableMemoryLimit, delayStart: true),
        );
        if (res.messageType != MessageType.EMPTY) return left("${res.messageType} ${res.message}");
      } on GrpcError catch (e) {
        loggy.error("failed to restart bg core: $e");
        if (e.code == StatusCode.unknown && !(e.message?.contains("HTTP/2 error") ?? false)) {
          return left("${e.message}");
        }
      }

      return right(unit);
      // await stop().run();
      // return await start(path, name, disableMemoryLimit).run();
      // }
      // if (!core.isSingleChannel()) {
      //   await startListeningStatus("bg", core.bgClient);
      //   await startListeningLogs("bg", core.bgClient);
      // }
      // return right(unit);
    });
  }

  TaskEither<String, Unit> resetTunnel() {
    return TaskEither(() async {
      // only available on iOS (and macOS later)
      if (!PlatformUtils.isIOS) {
        throw UnimplementedError("reset tunnel function unavailable on platform");
      }

      // loggy.debug("resetting tunnel");
      final res = await core.resetTunnel();
      if (res) {
        return right(unit);
      }
      return left("failed to reset tunnel");
    });
  }

  // Stream<List<OutboundGroup>> watchGroups() async* {
  //   loggy.debug("watching groups");
  //   yield* core.bgClient.outboundsInfo(Empty()).map((event) => event.items);
  //   // res?.cancel();
  // }

  Stream<OutboundGroup?> watchGroup() async* {
    loggy.debug("watching group");
    // interrupt managed by core

    if (!core.isInitialized()) {
      loggy.debug("core is not initialized, returning empty group stream");
      return;
    }
    try {
      yield* core.bgClient.outboundsInfo(Empty()).map((event) => event.items.isEmpty ? null : event.items.first);
    } catch (e) {
      loggy.error("error watching group: $e");
      rethrow;
    }
    // //emitting first event immediately
    // yield* core.bgClient.outboundsInfo(Empty()).take(1).map((event) => event.items.isEmpty ? null : event.items.first);
    // //emitting other event after every 4 seconds(latest event)
    // yield* core.bgClient.outboundsInfo(Empty()).throttleTime(const Duration(seconds: 4), leading: false, trailing: true).map((event) => event.items.isEmpty ? null : event.items.first);
  }

  Stream<List<OutboundGroup>> watchActiveGroups() async* {
    loggy.info("watching active groups");

    if (!core.isInitialized()) {
      loggy.debug("core is not initialized, returning empty group stream");
      return;
    }

    try {
      yield* core.bgClient
          .mainOutboundsInfo(Empty())
          .map((event) {
            return latest = event.items;
          })
          .startWith(latest);
    } catch (e) {
      loggy.error("error watching active groups: $e");
      rethrow;
    }
  }

  //
  // Stream<SingboxStatus> watchStatus() => _status;

  ResponseStream<SystemInfo> watchStats() {
    loggy.debug("watching stats");
    try {
      return core.bgClient.getSystemInfoStream(Empty());
    } catch (e) {
      loggy.error("error watching stats: $e");
      rethrow;
    }
  }

  /// 切过几次线路（发出切换就加一，在内核真切之前）。内核切线路时会把正在走的连接全部结束
  /// （selector 的 interrupt_exist_connections），判通据此认出「检测连接是被切线路结束的、没到节点」。
  int lineSwitches = 0;

  /// 正在切线路（切的请求发出去了、内核还没回话）：这时候被结束的检测连接，计数可能还没变（内核先掐连接、
  /// 后回话），也是被切线路结束的。
  bool get switchingLine => _selecting > 0;
  int _selecting = 0;

  /// 最近一次切线路做完（内核回话或出错）。被切断的检测连接等它再重问，不在切的过程中连着重问。
  Future<void> get lineSettled => _settled;
  Future<void> _settled = Future.value();

  TaskEither<String, Unit> selectOutbound(String groupTag, String outboundTag) {
    return TaskEither(() async {
      loggy.debug("selecting outbound");
      lineSwitches++;
      _selecting++;
      final done = Completer<void>();
      _settled = done.future;
      try {
        final res = await core.bgClient.selectOutbound(
          SelectOutboundRequest(groupTag: groupTag, outboundTag: outboundTag),
          options: CallOptions(timeout: const Duration(seconds: 1)),
        );
        if (res.code != ResponseCode.OK) return left("${res.code} ${res.message}");

        return right(unit);
      } catch (e) {
        loggy.error("error selecting outbound: $e");
        rethrow;
      } finally {
        // 内核切完（或出错）再加一次：切的这一会儿里发出去的检测连接也会被结束，它们记的是第一次加之后的数，也要认得出来
        lineSwitches++;
        _selecting--;
        done.complete();
      }
    });
  }

  TaskEither<String, Unit> urlTest(String tag) {
    return TaskEither(() async {
      loggy.debug("url test");
      try {
        final res = await core.bgClient.urlTest(UrlTestRequest(tag: tag));
        if (res.code != ResponseCode.OK) return left("${res.code} ${res.message}");

        return right(unit);
      } catch (e) {
        loggy.error("error in url test: $e");
        rethrow;
      }
    });
  }

  /// 直接对当前选中的出站做一次 URL 测试，不经过界面上那条会断的状态流。
  ///
  /// 返回延迟毫秒。测完确认不通返回 0。通道断了、或者等了 2.5 秒还没读到
  /// 这次的新结果，返回 null（这次没测到，调用方不能当成不通）。
  Future<int?> probeActiveDelay() async {
    if (!core.isInitialized()) return null;
    try {
      // 读不到旧时间戳时，用「调用这一刻」当下限，避免把上一次的延迟当成这次的结果。
      var beforeUs = DateTime.now().toUtc().microsecondsSinceEpoch;
      final previous = await _activeUrlTestStamp();
      if (previous > 0) beforeUs = previous;
      final res = await core.bgClient
          .urlTest(UrlTestRequest(tag: ''))
          .timeout(const Duration(seconds: 3));
      if (res.code != ResponseCode.OK) return null;
      final deadline = DateTime.now().add(const Duration(milliseconds: 2500));
      while (DateTime.now().isBefore(deadline)) {
        final info = await _readSelectedOutbound();
        if (info != null && _urlTestStampUs(info) > beforeUs) {
          final delay = info.urlTestDelay;
          if (delay > 0 && delay < 60000) return delay;
          return 0;
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      return null;
    } catch (e) {
      loggy.debug("probeActiveDelay missed: $e");
      return null;
    }
  }

  /// 当前选中线路经节点回来的字节（判通用，跟 Windows 读 xray 统计同一个意思，
  /// docs/计划/连上后判通-按节点回数据.md）。读不到返回 null。
  Future<int?> selectedOutboundDownload() async {
    if (!core.isInitialized()) return null;
    try {
      final info = await _readSelectedOutbound();
      return info?.download.toInt();
    } catch (_) {
      return null;
    }
  }

  Future<int> _activeUrlTestStamp() async {
    try {
      final info = await _readSelectedOutbound();
      if (info == null) return 0;
      return _urlTestStampUs(info);
    } catch (_) {
      return 0;
    }
  }

  Future<OutboundInfo?> _readSelectedOutbound() async {
    final list = await core.bgClient.mainOutboundsInfo(Empty()).first.timeout(const Duration(milliseconds: 800));
    if (list.items.isEmpty) return null;
    final group = list.items.first;
    if (group.items.isEmpty) return null;
    final selected = group.selected;
    for (final item in group.items) {
      if (selected.isNotEmpty && item.tag == selected) return item;
      if (item.isSelected) return item;
    }
    return group.items.first;
  }

  int _urlTestStampUs(OutboundInfo info) {
    if (!info.hasUrlTestTime()) return 0;
    final t = info.urlTestTime;
    return t.seconds.toInt() * 1000000 + t.nanos ~/ 1000;
  }

  List<LogMessage> logBuffer = [];

  // SingboxConfigOption? latestOptions;

  Stream<List<LogMessage>> watchLogs(String path) async* {
    if (!core.isInitialized()) {
      loggy.debug("core is not initialized, returning empty log stream");
      return;
    }
    await startListeningLogs("bg", core.bgClient);
    await startListeningLogs("fg", core.fgClient);
    try {
      yield* logController.stream;
    } catch (e) {
      loggy.error("error watching logs: $e");
      rethrow;
    }
    // Stream<List<String>> logStream(CoreClient coreClient) {
    //   return coreClient.logListener(Empty()).asBroadcastStream().map((event) => [event.message]).onErrorResume((error, stackTrace) {
    //     loggy.debug('Error in $coreClient: $error, retrying...');
    //     final delay = (currentState == const SingboxStatus.stopped()) ? 5 : 1;
    //     return const Stream<List<String>>.empty().delay(Duration(seconds: delay)).concatWith([logStream(coreClient)]);
    //   });
    // }

    // // Create streams for both fg and bg clients with retry logic
    // final fgLogStream = logStream(core.fgClient);

    // if (core.bgClient == core.fgClient) {
    //   yield* fgLogStream;
    //   return;
    // }
    // final bgLogStream = logStream(core.bgClient);
    // yield* MergeStream([bgLogStream, fgLogStream]);
  }

  TaskEither<String, Unit> clearLogs() {
    return TaskEither(() async {
      loggy.debug("clearing logs");
      logBuffer.clear();
      // final res = await core.bgClient(Empty());
      // if (res.code != ResponseCode.OK) return left("${res.code} ${res.message}");
      return right(unit);
    });
  }

  TaskEither<String, WarpResponse> generateWarpConfig({
    required String licenseKey,
    required String previousAccountId,
    required String previousAccessToken,
  }) {
    return TaskEither(() async {
      loggy.debug("generating warp config");
      final warpConfig = await core.fgClient.generateWarpConfig(
        GenerateWarpConfigRequest(
          licenseKey: licenseKey,
          accountId: previousAccountId,
          accessToken: previousAccessToken,
        ),
      );
      // if (warpConfig.code != ResponseCode.OK) return left("${warpConfig.code} ${warpConfig.message}");
      final WarpResponse warp = (
        log: warpConfig.log,
        accountId: warpConfig.account.accountId,
        accessToken: warpConfig.account.accessToken,
        wireguardConfig: jsonEncode(warpConfig.config.toProto3Json()),
      );
      return right(warp);
    });
  }

  Stream<CoreStatus> watchStatus() async* {
    await startListeningStatus("bg", core.bgClient);
    yield* statusController.stream;
    // .endWith(const CoreStatus.stopped());
  }

  Future<void> startListeningStatus(String key, CoreClient cc) async {
    // listenSingle 会先取消同名的旧订阅 —— 那也是我们自己关的，同样不能记成「已停止」。
    _statusClosedByUs = true;
    await listenSingle<CoreStatus>(
      "${key}StatusListener",
      () => cc
          .coreInfoListener(Empty(), options: grpcOptions)
          .doOnCancel(() {
            loggy.error("status", "Canceld");
            // OneRay：切到后台时是 closeFront() 自己把状态通道关掉的，VPN 还在跑。原来这里
            // 照样记成「已停止」，回前台 setup() 先把这个错的「已停止」报出去，首页就闪一下
            //「连接中」再「已连接」—— 用户觉得「一动它就断」（1.1.46 真机反馈）。
            // 我们自己关的通道不改状态；重新订阅后核心会报真实状态。
            if (_statusClosedByUs) return;
            if (currentState == const CoreStatus.started()) currentState = const CoreStatus.stopped();
          })
          .doOnData((event) {
            loggy.debug("status", event);
            if (currentState == const CoreStatus.started()) currentState = const CoreStatus.stopped();
          })
          .doOnDone(() {
            loggy.error("status", "done");
            if (currentState == const CoreStatus.started()) currentState = const CoreStatus.stopped();
          })
          .endWith(CoreInfoResponse(coreState: CoreStates.STOPPED))
          .map((event) {
            currentState = CoreStatus.fromCoreInfo(event);
            statusController.add(currentState);
            return currentState;
          }),
      // .endWith(const CoreStatus.stopped())
      onError: (error) {
        loggy.error("Stream error in ${key}StatusListener: $error");

        // currentState = const CoreStatus.stopped();
        // statusController.add(currentState);

        // startListeningStatus(key, cc);
      },
    );
    // 旧订阅已经取消完、新订阅已经挂上：从这里起通道再断开，就是真的断了。
    _statusClosedByUs = false;
  }

  Future<void> startListeningLogs(String key, CoreClient cc) async {
    final logLevel = ref.read(ConfigOptions.logLevel);
    final coreLogLevel = getCoreLogLevel(logLevel);
    final listenKey = "${key}LogListener";
    // await stopListenSingle(listenKey);
    await listenSingle<LogMessage>(listenKey, () {
      return cc.logListener(LogRequest(level: coreLogLevel), options: grpcOptions).map((event) {
        // Handle incoming event
        logBuffer.add(event);
        if (logBuffer.length > 300) {
          logBuffer.removeAt(0);
        }
        logController.add(logBuffer);
        // loggy.log(getLogLevel(event.level), event.message);
        event.message.split('\n').forEach((line) {
          loggy.log(getLogLevel(event.level), line);
        });
        return event;
      });
    });
  }

  Future<void> stopListenSingle(String key) async {
    // Collect keys to remove first
    final keysToRemove = subscriptions.entries
        .where((entry) => entry.key.startsWith(key))
        .map((entry) => entry.key)
        .toList();

    // Cancel and remove
    for (final k in keysToRemove) {
      final sub = subscriptions[k];
      await sub?.cancel(); // cancel the subscription

      subscriptions.remove(k);
    }
  }

  Future<StreamSubscription<T>?> listenSingle<T>(
    String key,
    Stream<T> Function() stream, {
    Function(dynamic error)? onError,
  }) async {
    if (subscriptions.containsKey(key)) {
      // return subscriptions[key] as StreamSubscription<T>?;
      await stopListenSingle(key);
    }
    subscriptions[key] = null;
    subscriptions[key] = stream().listen(
      (event) {
        // loggy.debug(event);
      },
      cancelOnError: true,
      onError: (error) {
        loggy.log(loggyl.LogLevel.error, 'Stream error: $error');
        onError?.call(error);
        subscriptions[key]?.cancel();
        subscriptions.remove(key);
      },
    );
    return subscriptions[key] as StreamSubscription<T>?;
  }

  loggyl.LogLevel getLogLevel(LogLevel level) {
    return switch (level) {
      LogLevel.DEBUG => loggyl.LogLevel.debug,
      LogLevel.INFO => loggyl.LogLevel.info,
      LogLevel.WARNING => loggyl.LogLevel.warning,
      LogLevel.ERROR => loggyl.LogLevel.error,
      LogLevel.FATAL => loggyl.LogLevel.error,
      _ => loggyl.LogLevel.info, // Default case
    };
  }

  LogLevel getCoreLogLevel(config_log_level.LogLevel level) {
    return switch (level) {
      config_log_level.LogLevel.trace => LogLevel.TRACE,
      config_log_level.LogLevel.debug => LogLevel.DEBUG,
      config_log_level.LogLevel.info => LogLevel.INFO,
      config_log_level.LogLevel.warn => LogLevel.WARNING,
      config_log_level.LogLevel.error => LogLevel.ERROR,
      config_log_level.LogLevel.fatal => LogLevel.FATAL,
      config_log_level.LogLevel.panic => LogLevel.FATAL,
      _ => LogLevel.INFO, // Default case
    };
  }

  Future<void> closeFront() async {
    if (!core.isInitialized()) {
      return;
    }
    if (!core.isSingleChannel()) {
      _statusClosedByUs = true;
      await stopListenSingle("fg");
      await stopListenSingle("bg");
      try {
        await core.fgClient.close(CloseRequest(mode: SetupMode.GRPC_NORMAL_INSECURE));
      } catch (e) {}
      try {
        await core.fgClient.close(CloseRequest(mode: SetupMode.GRPC_NORMAL));
      } catch (e) {}
    }
  }
}

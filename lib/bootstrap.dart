import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:hiddify/core/analytics/analytics_controller.dart';
import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/core/directories/directories_provider.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/logger/logger.dart';
import 'package:hiddify/core/logger/logger_controller.dart';
import 'package:hiddify/core/model/environment.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/preferences/preferences_migration.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/app/widget/app.dart';
import 'package:hiddify/features/auto_start/notifier/auto_start_notifier.dart';

import 'package:hiddify/features/log/data/log_data_providers.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/system_tray/notifier/system_tray_notifier.dart';
import 'package:hiddify/features/window/notifier/window_notifier.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service_provider.dart';
import 'package:hiddify/riverpod_observer.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

Future<void> lazyBootstrap(WidgetsBinding widgetsBinding, Environment env) async {
  if (!kIsWeb) {
    FlutterNativeSplash.preserve(widgetsBinding: widgetsBinding);
  }
  LoggerController.preInit();
  FlutterError.onError = Logger.logFlutterError;
  WidgetsBinding.instance.platformDispatcher.onError = Logger.logPlatformDispatcherError;

  final stopWatch = Stopwatch()..start();

  final container = ProviderContainer(overrides: [environmentProvider.overrideWithValue(env)]);

  await _init("directories", () => container.read(appDirectoriesProvider.future));
  LoggerController.init(container.read(logPathResolverProvider).appFile().path);

  final appInfo = await _init("app info", () => container.read(appInfoProvider.future));
  await _init("preferences", () => container.read(sharedPreferencesProvider.future));

  final enableAnalytics = await container.read(analyticsControllerProvider.future);
  if (enableAnalytics) {
    await _init("analytics", () => container.read(analyticsControllerProvider.notifier).enableAnalytics());
  }

  await _init("preferences migration", () async {
    try {
      await PreferencesMigration(sharedPreferences: container.read(sharedPreferencesProvider).requireValue).migrate();
    } catch (e, stackTrace) {
      Logger.bootstrap.error("preferences migration failed", e, stackTrace);
      if (env == Environment.dev) rethrow;
      Logger.bootstrap.info("clearing preferences");
      await container.read(sharedPreferencesProvider).requireValue.clear();
    }
  });

  // OneRay 1.1.50：核心的国内名单换成了自己服务器上那份（tool/patch_core_rules.py）。
  // 核心把下载过的名单缓存在 clash.db 里 5 天、按名字认不看地址，装过 1.1.49 的手机会
  // 继续用旧的残缺名单 —— 清一次缓存。只清一次（选中的线路 App 自己会再选回来）。
  await _init("core rule-set cache reset", () async {
    final prefs = container.read(sharedPreferencesProvider).requireValue;
    const flag = "oneray_ruleset_cache_reset_v1";
    if (prefs.getBool(flag) ?? false) return;
    final dirs = container.read(appDirectoriesProvider).requireValue;
    for (final dir in {dirs.baseDir.path, dirs.workingDir.path}) {
      for (final rel in ["data/clash.db", "clash.db"]) {
        final f = File("$dir/$rel");
        if (f.existsSync()) {
          try {
            await f.delete();
            Logger.bootstrap.info("deleted ${f.path}");
          } catch (e) {
            Logger.bootstrap.warning("delete ${f.path} failed: $e");
          }
        }
      }
    }
    await prefs.setBool(flag, true);
  });

  final debug = container.read(debugModeNotifierProvider) || kDebugMode;

  if (PlatformUtils.isDesktop) {
    await _init("window controller", () => container.read(windowNotifierProvider.future));

    final silentStart = container.read(Preferences.silentStart);
    Logger.bootstrap.debug("silent start [${silentStart ? "Enabled" : "Disabled"}]");
    if (!silentStart) {
      await container.read(windowNotifierProvider.notifier).show(focus: false);
    } else {
      Logger.bootstrap.debug("silent start, remain hidden accessible via tray");
    }
    await _init("auto start service", () => container.read(autoStartNotifierProvider.future));
  }
  await _init("logs repository", () => container.read(logRepositoryProvider.future));
  await _init("logger controller", () => LoggerController.postInit(debug));

  Logger.bootstrap.info(appInfo.format());

  // OneRay: 没有引导页了。第一次启动在这里把标记置上，并记下「这次是首启」——
  // 不能放进 router 的 redirect 里写：写入会通知 RefreshListenable，登录页被重建，
  // 自动开游客号会跑第二次（两次并发 → 可能导入两条重复订阅）。
  if (!container.read(Preferences.introCompleted)) {
    firstLaunchAfterInstall = true;
    await container.read(Preferences.introCompleted.notifier).update(true);
    Logger.bootstrap.info("first launch after install");
  }

  await _init("profile repository", () => container.read(profileRepositoryProvider.future));

  await _init("translations", () => container.read(translationsProvider.future));

  await _safeInit("active profile", () => container.read(activeProfileProvider.future), timeout: 1000);
  await _init("hiddify-core", () => container.read(hiddifyCoreServiceProvider).init());

  if (!kIsWeb) {
    // await _safeInit(
    //   "deep link service",
    //   () => container.read(deepLinkNotifierProvider.future),
    //   timeout: 1000,
    // );

    if (PlatformUtils.isDesktop) {
      await _safeInit("system tray", () => container.read(systemTrayNotifierProvider.future), timeout: 1000);
    }

    if (PlatformUtils.isAndroid) {
      await _safeInit("android display mode", () async {
        await FlutterDisplayMode.setHighRefreshRate();
      });
    }
  }

  Logger.bootstrap.info("bootstrap took [${stopWatch.elapsedMilliseconds}ms]");
  stopWatch.stop();

  runApp(
    ProviderScope(
      parent: container,
      observers: [RiverpodObserver()],
      child: SentryUserInteractionWidget(child: const App()),
    ),
  );

  if (!kIsWeb) {
    FlutterNativeSplash.remove();
  }
  // SentryFlutter.s(DateTime.now().toUtc());
}

Future<T> _init<T>(String name, Future<T> Function() initializer, {int? timeout}) async {
  final stopWatch = Stopwatch()..start();
  Logger.bootstrap.info("initializing [$name]");
  Future<T> func() => timeout != null ? initializer().timeout(Duration(milliseconds: timeout)) : initializer();
  try {
    final result = await func();
    Logger.bootstrap.debug("[$name] initialized in ${stopWatch.elapsedMilliseconds}ms");
    return result;
  } catch (e, stackTrace) {
    Logger.bootstrap.error("[$name] error initializing", e, stackTrace);
    rethrow;
  } finally {
    stopWatch.stop();
  }
}

Future<T?> _safeInit<T>(String name, Future<T> Function() initializer, {int? timeout}) async {
  try {
    return await _init(name, initializer, timeout: timeout);
  } catch (e) {
    return null;
  }
}

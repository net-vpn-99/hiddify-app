import 'dart:async';
import 'dart:math';

import 'package:dartx/dartx.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/remote_site_config.dart';
import 'package:hiddify/core/notification/in_app_notification_controller.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/panel_auth/data/own_subscribe.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/profile_notifier.dart' show freshAccountSubscribeUrlIfChanged;
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:meta/meta.dart';
import 'package:neat_periodic_task/neat_periodic_task.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'profiles_update_notifier.g.dart';

typedef ProfileUpdateStatus = ({String name, bool success});

@Riverpod(keepAlive: true)
class ForegroundProfilesUpdateNotifier extends _$ForegroundProfilesUpdateNotifier with AppLogger {
  static const prefKey = "profiles_update_check";

  static Duration get interval => RemoteSiteConfig.nodesPoll;

  @override
  Stream<ProfileUpdateStatus?> build() {
    var cycleCount = 0;
    var disposed = false;

    Future<void> boot() async {
      await RemoteSiteConfig.ensureLoaded();
      if (disposed) return;
      await _scheduler?.stop();
      _scheduler = NeatPeriodicTaskScheduler(
        name: 'profiles update worker',
        interval: RemoteSiteConfig.nodesPoll,
        timeout: const Duration(minutes: 5),
        task: () async {
          loggy.debug("cycle [${cycleCount++}]");
          await updateProfiles();
        },
      );
      if (disposed) return;
      if (ref.read(Preferences.introCompleted)) {
        loggy.debug("intro done, starting interval=${RemoteSiteConfig.nodesPoll}");
        _scheduler?.start();
      } else {
        loggy.debug("intro in process, skipping");
      }
    }

    ref.onDispose(() async {
      disposed = true;
      await _scheduler?.stop();
      _scheduler = null;
    });

    if (ref.watch(Preferences.introCompleted)) {
      unawaited(boot());
    }
    return const Stream.empty();
  }

  NeatPeriodicTaskScheduler? _scheduler;
  bool _forceNextRun = false;

  Future<void> trigger() async {
    loggy.debug("triggering update");
    _forceNextRun = true;
    await _scheduler?.trigger();
  }

  @visibleForTesting
  Future<void> updateProfiles() async {
    var force = false;
    if (_forceNextRun) {
      force = true;
      _forceNextRun = false;
    }

    try {
      final previousRun = DateTime.tryParse(ref.read(sharedPreferencesProvider).requireValue.getString(prefKey) ?? "");
      final wait = _jittered(interval);

      if (!force && previousRun != null && previousRun.add(wait) > DateTime.now()) {
        loggy.debug("too soon! previous run: [$previousRun]");
        return;
      }
      loggy.debug("${force ? "[FORCED] " : ""}running, previous run: [$previousRun]");

      final remoteProfiles = await ref
          .read(profileRepositoryProvider)
          .requireValue
          .watchAll()
          .map(
            (event) => event.getOrElse((f) {
              loggy.error("error getting profiles");
              throw f;
            }).whereType<RemoteProfileEntity>(),
          )
          .first;

      final boundId = await boundAccountProfileId();
      await for (final profile in Stream.fromIterable(remoteProfiles)) {
        final disabled = profile.userOverride?.isAutoUpdateDisable ?? false;
        if (!force && disabled) {
          loggy.debug("skipping profile [${profile.id}] auto-update disabled");
          continue;
        }
        final isAccount = isOwnAccountProfile(profile, boundId: boundId);
        final updateInterval = isAccount ? RemoteSiteConfig.nodesPoll : profile.options?.updateInterval;
        if (force || updateInterval != null && updateInterval <= DateTime.now().difference(profile.lastUpdate)) {
          final t = ref.read(translationsProvider).requireValue;
          // 账号自己那份订阅：先问一次面板拿当前真正生效的地址，不要用可能已经
          // 过期的 profile.url（跟手动更新入口同一条逻辑，见 profile_notifier.dart）。
          // 有新地址就按原 ID 更新，不走 upsertRemote 的按 URL 查找——避免这条
          // 记录的"账号订阅"身份标记（userOverride）在地址变了之后被弄丢。
          final freshUrl = await freshAccountSubscribeUrlIfChanged(ref, profile);
          final updateCall = freshUrl != null
              ? ref.read(profileRepositoryProvider).requireValue.updateRemoteUrl(profile.id, freshUrl)
              : ref.read(profileRepositoryProvider).requireValue.upsertRemote(profile.url);
          await updateCall
              .mapLeft((l) {
                loggy.debug("error updating profile [${profile.id}]", l);
                ref
                    .read(inAppNotificationControllerProvider)
                    .showErrorToast(t.pages.profiles.msg.update.failureNamed(name: profile.name));
                state = AsyncData((name: profile.name, success: false));
              })
              .map((_) {
                loggy.debug("profile [${profile.id}] updated successfully");
                ref
                    .read(inAppNotificationControllerProvider)
                    .showSuccessToast(t.pages.profiles.msg.update.successNamed(name: profile.name));
                state = AsyncData((name: profile.name, success: true));
              })
              .run();
        } else {
          loggy.debug(
            "skipping profile [${profile.id}] update. last successful update: [${profile.lastUpdate}] - interval: [${profile.options?.updateInterval}]",
          );
        }
      }
      await ref.read(sharedPreferencesProvider).requireValue.setString(prefKey, DateTime.now().toIso8601String());
    } catch (e) {
      loggy.error("profiles update failed", e);
      rethrow;
    }
  }

  Duration _jittered(Duration base) {
    final ms = base.inMilliseconds;
    final span = ms ~/ 5;
    if (span <= 0) return base;
    final delta = Random().nextInt(span * 2 + 1) - span;
    return Duration(milliseconds: ms + delta);
  }
}

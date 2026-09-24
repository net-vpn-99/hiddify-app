import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hiddify/core/haptic/haptic_service.dart';
import 'package:hiddify/core/http_client/http_client_provider.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/failures.dart';
import 'package:hiddify/core/notification/in_app_notification_controller.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/panel_auth/data/own_subscribe.dart';
import 'package:hiddify/features/panel_auth/data/panel_api.dart';
import 'package:hiddify/features/panel_auth/data/panel_api_base.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hiddify/features/profile/add/model/free_profiles_model.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/data/profile_repository.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/model/profile_failure.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/utils/riverpod_utils.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'profile_notifier.g.dart';

@riverpod
class AddProfileNotifier extends _$AddProfileNotifier with AppLogger {
  @override
  AsyncValue<Unit?> build() {
    ref.disposeDelay(const Duration(minutes: 1));
    ref.onDispose(() {
      loggy.debug("disposing");
      _cancelToken?.cancel();
    });
    listenSelf((previous, next) {
      final t = ref.read(translationsProvider).requireValue;
      final notification = ref.read(inAppNotificationControllerProvider);
      switch (next) {
        case AsyncData(value: final _?):
          notification.showSuccessToast(t.pages.profiles.msg.save.success);
        case AsyncError(:final error):
          if (error case ProfileInvalidUrlFailure()) {
            notification.showErrorToast(t.pages.profiles.msg.invalidUrl);
          } else if (error case ProfileCancelByUserFailure()) {
            return;
          } else if (error is ProfileFailure &&
              profileFailureIsSubscribeDenied(error) &&
              (ref.read(panelAuthProvider).account?.exhausted ?? false)) {
            // 试用结束拉不到节点。首页会自己弹「去买套餐」，不要再盖一层英文报错。
            return;
          } else {
            ref
                .read(dialogNotifierProvider.notifier)
                .showCustomAlertFromErr(t.presentError(error, action: t.pages.profiles.msg.add.failure));
          }
      }
    });
    ref.onDispose(() {
      if (!(_cancelToken?.isCancelled ?? true)) _cancelToken?.cancel();
    });
    return const AsyncData(null);
  }

  ProfileRepository get _profilesRepo => ref.read(profileRepositoryProvider).requireValue;
  CancelToken? _cancelToken;

  /// OneRay：只收自家账号订阅。别家机场订阅、手贴的节点 / 配置内容一律不收——免得客户
  /// 拿别家订阅用我们的 App，出了问题来找我们（2026-09-20 定）。所有导入入口（一键导入
  /// 深链、粘贴、手动填写、快捷键粘贴）最后都走 addClipboard / addManual，在这里拦一处。
  ///
  /// 判断**不靠域名名单**（换域走 feed 不发版）：域名已知直接收；域名不认识但长得像
  /// Xboard 订阅，就拿令牌去问当前可用的 API，面板认这个令牌才收，并把域名换成当前
  /// API。返回要导入的 URL，不收返回 null（已弹提示）。
  Future<String?> _ownUrlOrReject(String? url) async {
    if (url != null) {
      if (isOwnAccountSubscribeSource(url)) return url;
      final token = looksLikeOwnPanelSubscribe(url) ? subscribeTokenOf(url) : null;
      if (token != null && await PanelApi().isOwnSubscribeToken(token)) {
        return buildOwnSubscribeUrl(apiBase: PanelApiBase.current, token: token, originalUrl: url);
      }
    }
    loggy.info("rejected non-account subscription");
    ref.read(inAppNotificationControllerProvider).showErrorToast('只能导入光速雷达账号的订阅，登录后会自动导入');
    return null;
  }

  Future<void> addClipboard(String rawInput) async {
    if (state.isLoading) return;
    final rs = LinkParser.parse(rawInput);
    state = const AsyncLoading();
    final url = await _ownUrlOrReject(rs?.url);
    if (url == null) {
      state = const AsyncData(null);
      return;
    }
    state = await AsyncValue.guard(() async {
      loggy.debug("adding profile, url: [$url]");
      final TaskEither<ProfileFailure, Unit> task = _profilesRepo.upsertRemote(
        url,
        userOverride: rs!.name.isNotEmpty ? UserOverride(name: rs.name) : null,
        cancelToken: _cancelToken = CancelToken(),
      );
      return await task
          .match(
            (err) {
              loggy.warning("failed to add profile", err);
              throw err;
            },
            (_) {
              loggy.info("successfully added profile");
              return unit;
            },
          )
          .run();
    });
  }

  Future<void> addManual({required String url, required UserOverride userOverride}) async {
    if (state.isLoading) return;
    state = const AsyncLoading();
    final ownUrl = await _ownUrlOrReject(url);
    if (ownUrl == null) {
      state = const AsyncData(null);
      return;
    }
    state = await AsyncValue.guard(() async {
      return await _profilesRepo
          .upsertRemote(ownUrl, userOverride: userOverride)
          .match(
            (err) {
              loggy.warning("failed to add profile", err);
              throw err;
            },
            (r) {
              loggy.info("successfully added profile, mark as active? [true]");
              return r;
            },
          )
          .run();
    });
  }

  /// 登录 / 注册 / 账号补订阅。不看显示名称，先确认 URL 来源再按绑定 ID 更新。
  Future<void> addAccountSubscription(String url) async {
    if (state.isLoading) return;
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      // ⚠️「光速」是**内部标识**，不是给人看的名字，1.1.28 改品牌名时故意没动：
      // `own_subscribe.dart` 靠 `userOverride.name == '光速'` 认「这是自家账号的订阅」，
      // 改了老用户本地那份就认不出来，会被当成别家订阅重新导入。用户能看到它的地方
      // （首页卡片、通知栏）都已经改成显示线路名 / 品牌名了。
      const userOverride = UserOverride(name: '光速');
      return await (await _accountSubscribeTask(url, userOverride))
          .match(
            (err) {
              loggy.warning("failed to add account subscription", err);
              throw err;
            },
            (r) {
              loggy.info("successfully added account subscription");
              return r;
            },
          )
          .run();
    });
  }

  Future<TaskEither<ProfileFailure, Unit>> _accountSubscribeTask(String url, UserOverride userOverride) async {
    if (!isOwnAccountSubscribeSource(url)) {
      return TaskEither.left(ProfileFailure.invalidUrl());
    }
    final bound = await boundAccountProfileId();
    if (bound != null && bound.isNotEmpty) {
      return _profilesRepo.updateRemoteUrl(bound, url).orElse(
            (err) => err is ProfileNotFoundFailure
                ? _upsertAndBind(url, userOverride)
                : TaskEither.left(err),
          );
    }
    return _upsertAndBind(url, userOverride);
  }

  /// OneRay：已登录时保证当前选中的是账号自己那份订阅（2026-09-20 定）。
  /// 选中的是别家订阅 → 切回自家；自家那份被删了 → 重新拉地址导入再切过去。
  /// 没登录直接返回 true（没登录的连接入口本来就会先引导登录）。
  /// 返回 false = 登录了但没能切到自家订阅（通常是网络问题），调用方别再连。
  Future<bool> ensureAccountProfileActive() async {
    if (!ref.read(Preferences.panelLoggedIn)) return true;
    final bound = await boundAccountProfileId();
    bool isOwn(ProfileEntity? p) => p is RemoteProfileEntity && isOwnAccountProfile(p, boundId: bound);

    final active = await ref.read(activeProfileProvider.future);
    if (isOwn(active)) return true;

    Future<ProfileEntity?> findOwn() async {
      try {
        final all = await _profilesRepo
            .watchAll()
            .map((e) => e.getOrElse((_) => const <ProfileEntity>[]))
            .first
            .timeout(const Duration(seconds: 3));
        final b = await boundAccountProfileId();
        for (final p in all) {
          if (p is RemoteProfileEntity && isOwnAccountProfile(p, boundId: b)) return p;
        }
      } catch (_) {}
      return null;
    }

    var own = await findOwn();
    if (own == null) {
      final url = await ref.read(panelAuthProvider.notifier).refreshSubscribeUrl();
      if (url == null || url.isEmpty) return false;
      await addAccountSubscription(url);
      own = await findOwn();
      if (own == null) return false;
    }
    loggy.info("active profile is not the account's, switching back to [${own.id}]");
    final ok = await _profilesRepo.setAsActive(own.id).match((_) => false, (_) => true).run();
    if (!ok) return false;
    // 等 activeProfileProvider（DB watch）跟上，否则紧接着的连接可能还拿到旧的那份。
    for (var i = 0; i < 30; i++) {
      if ((await ref.read(activeProfileProvider.future))?.id == own.id) return true;
      await Future.delayed(const Duration(milliseconds: 100));
    }
    return true;
  }

  TaskEither<ProfileFailure, Unit> _upsertAndBind(String url, UserOverride userOverride) {
    return _profilesRepo.upsertRemote(url, userOverride: userOverride).flatMap((unit) {
      return TaskEither.tryCatch(() async {
        try {
          final existing = await _profilesRepo
              .watchAll()
              .map((e) => e.getOrElse((_) => const <ProfileEntity>[]))
              .first
              .timeout(const Duration(seconds: 3));
          for (final p in existing) {
            if (p is RemoteProfileEntity && p.url == url) {
              await bindAccountProfileId(p.id);
              break;
            }
          }
        } catch (_) {}
        return unit;
      }, ProfileFailure.unexpected);
    });
  }
}

@riverpod
class UpdateProfileNotifier extends _$UpdateProfileNotifier with AppLogger {
  @override
  AsyncValue<Unit?> build(String id) {
    ref.disposeDelay(const Duration(minutes: 1));
    listenSelf((previous, next) {
      final t = ref.read(translationsProvider).requireValue;
      final notification = ref.read(inAppNotificationControllerProvider);
      switch (next) {
        case AsyncData(value: final _?):
          notification.showSuccessToast(t.pages.profiles.msg.update.success);
        case AsyncError(:final error):
          if (error is ProfileFailure &&
              profileFailureIsSubscribeDenied(error) &&
              (ref.read(panelAuthProvider).account?.exhausted ?? false)) {
            return;
          }
          ref
              .read(dialogNotifierProvider.notifier)
              .showCustomAlertFromErr(t.presentError(error, action: t.pages.profiles.msg.update.failure));
      }
    });
    return const AsyncData(null);
  }

  ProfileRepository get _profilesRepo => ref.read(profileRepositoryProvider).requireValue;

  /// 返回这次更新是不是真的成功——`state` 只是给 UI 看的 toast/loading 状态，
  /// `AsyncValue.guard` 会把异常转成 `AsyncError` 正常返回，调用方 await 这个
  /// 方法本身看不出失败。购买后要判断"节点真的刷新成功了没有"，得看这个返回值，
  /// 不能只看方法有没有抛出去。
  Future<bool> updateProfile(RemoteProfileEntity profile) async {
    if (state.isLoading) return false;
    state = const AsyncLoading();
    await ref.read(hapticServiceProvider.notifier).lightImpact();
    state = await AsyncValue.guard(() async {
      final freshUrl = await freshAccountSubscribeUrlIfChanged(ref, profile);
      // 有新地址：按原 ID 更新（保留 userOverride/id/用户设置），不走 upsertRemote
      // 的按 URL 查找——那样会把这条记录的"账号订阅"身份标记弄丢，下次再换域
      // 就再也不会主动刷新了。没有新地址（没变/拿不到/不是账号自己那份）就走
      // 原来的路径，跟用户自己导入的第三方订阅完全一样对待。
      final target = freshUrl != null ? profile.copyWith(url: freshUrl) : profile;
      final call = freshUrl != null
          ? _profilesRepo.updateRemoteUrl(profile.id, freshUrl)
          : _profilesRepo.upsertRemote(profile.url);
      return await call
          .match(
            (err) {
              loggy.warning("failed to update profile", err);
              throw err;
            },
            (_) async {
              loggy.info('successfully updated profile');

              await ref.read(activeProfileProvider.future).then((active) async {
                if (active != null && active.id == target.id) {
                  await ref.read(connectionNotifierProvider.notifier).reconnect(target);
                }
              });
              return unit;
            },
          )
          .run();
    });
    return state is AsyncData;
  }
}

/// 这份订阅是不是账号自己那份（登录/注册走 `addAccountSubscription` 绑定 ID）。
/// 不是的话返回 null，绝不去碰用户自己导入的第三方订阅。
///
/// 是的话，先问一次面板拿当前真正生效的订阅地址：`profile.url` 只在上次成功
/// 更新时写入过，技术域换了之后就是死的。跟旧地址一样就返回 null（没有变化，
/// 调用方走原来的 `upsertRemote` 路径即可，不用多此一举按 ID 更新）；拿不到
/// 新地址（没登录/网络问题）也返回 null，不阻塞这次更新。
///
/// 公开（不带下划线）是因为 `profiles_update_notifier.dart`（自动更新的那条
/// 独立路径，走的是 repository 直调不是这个 notifier）也要用同一条判断逻辑。
Future<String?> freshAccountSubscribeUrlIfChanged(Ref ref, RemoteProfileEntity profile) async {
  final bound = await boundAccountProfileId();
  if (!isOwnAccountProfile(profile, boundId: bound)) return null;
  try {
    final fresh = await ref.read(panelAuthProvider.notifier).refreshSubscribeUrl();
    if (fresh != null && fresh.trim().isNotEmpty && fresh.trim() != profile.url) {
      return fresh.trim();
    }
  } catch (_) {}
  return null;
}

@riverpod
class FreeSwitchNotifier extends _$FreeSwitchNotifier {
  @override
  bool build() {
    return false;
  }

  Future<void> onChange(bool value) async => state = value;
}

@riverpod
class AddProfilePageNotifier extends _$AddProfilePageNotifier {
  @override
  AddProfilePages build() => AddProfilePages.options;

  void goOptions() => state = AddProfilePages.options;
  void goManual() => state = AddProfilePages.manual;
}

enum AddProfilePages { options, manual }

@riverpod
class FreeProfilesNotifier extends _$FreeProfilesNotifier {
  @override
  Future<List<FreeProfile>> build() async {
    final httpClient = ref.watch(httpClientProvider);
    final res = await httpClient.get(
      'https://raw.githubusercontent.com/hiddify/hiddify-app/refs/heads/main/test.configs/free_configs',
    );
    if (res.statusCode == 200) {
      return FreeProfilesModel.fromJson(jsonDecode(res.data.toString()) as Map<String, dynamic>).profiles;
    }
    return <FreeProfile>[];
  }
}

@riverpod
Future<List<FreeProfile>> freeProfilesFilteredByRegion(Ref ref) async {
  final freeProfiles = await ref.watch(freeProfilesNotifierProvider.future);
  final region = ref.watch(ConfigOptions.region);
  return freeProfiles.where((e) => e.region.contains(region.name) || e.region.isEmpty).toList();
}

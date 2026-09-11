import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/notification/in_app_notification_controller.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/core/theme/theme_extensions.dart';
import 'package:hiddify/core/widget/animated_text.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
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

    final requiresReconnect = ref.watch(configOptionNotifierProvider).valueOrNull;
    final today = DateTime.now();
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
        label: account?.stateSlug == 'expired' ? '会员已到期' : '流量已用完',
        hint: '点按钮邀请好友或续费',
        buttonColor: buttonTheme.idleColor!,
        image: Assets.images.disconnectNorouz,
        newButtonColor: buttonTheme.idleColor!,
        animated: false,
        useImage: today.day >= 19 && today.day <= 23 && today.month == 3,
        secureLabel: '',
      );
    }

    return _ConnectionButton(
      onTap: switch (connectionStatus) {
        AsyncData(value: Connected()) when requiresReconnect == true => () async {
          final activeProfile = await ref.read(activeProfileProvider.future);
          return await ref.read(connectionNotifierProvider.notifier).reconnect(activeProfile);
        },
        AsyncData(value: Disconnected()) || AsyncError() => () async {
          if (ref.read(activeProfileProvider).valueOrNull == null) {
            // OneRay: 没订阅 —— 没登录就先引导登录（订阅登录后自动导入），
            // 不再弹 Hiddify 那个「选择配置文件」通用空状态。
            if (!ref.read(Preferences.panelLoggedIn)) {
              ref.read(inAppNotificationControllerProvider).showInfoToast('请先登录光速账号');
              context.go('/login');
              return;
            }
            // 登录了却没有可用订阅：多半是试用 / 会员到期或流量用完。补一次账号再判断，
            // 别再给用户看「还没有 VPN 服务器？免费设置一个」那种误导文案。
            try {
              await ref.read(panelAuthProvider.notifier).syncAccountQuietly();
            } catch (_) {}
            final acc = ref.read(panelAuthProvider).account;
            if (acc != null && (acc.exhausted || acc.stateSlug == 'no_plan')) {
              await ref.read(dialogNotifierProvider.notifier).showQuotaExhausted(acc, force: true);
              return;
            }
            // 账号正常却没订阅 —— 订阅同步掉了，重新拉一次地址并导入（跟登录时同一条路，
            // addManual 自己会弹成功 / 失败提示）。
            final url = await ref.read(panelAuthProvider.notifier).refreshSubscribeUrl();
            if (url != null && url.isNotEmpty) {
              await ref
                  .read(addProfileNotifierProvider.notifier)
                  .addManual(url: url, userOverride: const UserOverride(name: '光速'));
              if (ref.read(addProfileNotifierProvider) is! AsyncError) return;
            }
            ref
                .read(inAppNotificationControllerProvider)
                .showErrorToast('订阅同步失败，请稍后重试，或在「我的」页联系客服');
            return;
          }
          if (await ref.read(dialogNotifierProvider.notifier).showExperimentalFeatureNotice()) {
            return await ref.read(connectionNotifierProvider.notifier).toggleConnection();
          }
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
        _ => () {},
      },
      enabled: switch (connectionStatus) {
        AsyncData(value: Connected()) || AsyncData(value: Disconnected()) || AsyncError() => true,
        _ => false,
      },
      label: switch (connectionStatus) {
        AsyncData(value: Connected()) when requiresReconnect == true => t.connection.reconnect,
        AsyncData(value: Connected()) when delay <= 0 || delay >= 65000 => t.connection.connecting,
        AsyncData(value: final status) => status.present(t),
        _ => "",
      },
      buttonColor: switch (connectionStatus) {
        AsyncData(value: Connected()) when requiresReconnect == true => Colors.teal,
        AsyncData(value: Connected()) when delay <= 0 || delay >= 65000 => const Color.fromARGB(255, 185, 176, 103),
        AsyncData(value: Connected()) => buttonTheme.connectedColor!,
        AsyncData(value: _) => buttonTheme.idleColor!,
        _ => Colors.red,
      },
      image: switch (connectionStatus) {
        AsyncData(value: Connected()) when requiresReconnect == true => Assets.images.disconnectNorouz,
        AsyncData(value: Connected()) => Assets.images.connectNorouz,
        _ => Assets.images.disconnectNorouz,
      },
      newButtonColor: switch (connectionStatus) {
        AsyncData(value: Connected()) when requiresReconnect == true => Colors.teal,
        AsyncData(value: Connected()) when delay <= 0 || delay >= 65000 => const Color.fromARGB(255, 185, 176, 103),
        AsyncData(value: Connected()) => buttonTheme.connectedColor!,
        AsyncData(value: _) => buttonTheme.idleColor!,
        _ => Colors.red,
      },
      animated: switch (connectionStatus) {
        AsyncData(value: Connected()) when requiresReconnect == true => false,
        AsyncData(value: Connected()) when delay <= 0 || delay >= 65000 => false,
        AsyncData(value: Connected()) => true,
        AsyncData(value: _) => true,
        _ => false,
      },
      useImage: today.day >= 19 && today.day <= 23 && today.month == 3,
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
    required this.image,
    required this.useImage,
    required this.newButtonColor,
    required this.animated,
    required this.secureLabel,
    this.hint,
  });

  final VoidCallback onTap;
  final bool enabled;
  final String label;
  final String? hint;
  final Color buttonColor;
  final AssetGenImage image;
  final bool useImage;
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
                      if (useImage) {
                        return image.image();
                      } else {
                        return Assets.images.logo.svg(colorFilter: ColorFilter.mode(value!, BlendMode.srcIn));
                      }
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
              if (hint != null && hint!.isNotEmpty) ...[
                const Gap(4),
                Text(
                  hint!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
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

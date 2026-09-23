import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/router/go_router/refresh_listenable.dart';
import 'package:hiddify/core/router/go_router/routing_config_notifier.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'go_router_notifier.g.dart';

// if 'stateful shell route' navigators not registered, this navigator key can be used for showing dialog or bottom sheet...
final rootNavKey = GlobalKey<NavigatorState>(debugLabel: 'rootNav');

@Riverpod(keepAlive: true)
class GoRouterNotifer extends _$GoRouterNotifer {
  static final rConfig = ValueNotifier<RoutingConfig>(loadingConfig);
  @override
  GoRouter build() {
    ref.listen(routingConfigNotifierProvider, (_, next) => rConfig.value = next);
    return GoRouter.routingConfig(
      // OneRay: 任何时候打开都直接进首页，包括装好后的第一次 —— 游客号在首页后台静默开
      // （guestBootstrapProvider）。开不出来首页也照常显示节点和套餐，点的时候才提示。
      // 1.1.27 及以前首启先跳 /login 在那儿开号，用户要干看一次「正在开通免费试用…」。
      initialLocation: '/home',
      navigatorKey: rootNavKey,
      routingConfig: rConfig,
      refreshListenable: RefreshListenable(ref),
      errorBuilder: (context, state) {
        WidgetsBinding.instance.addPostFrameCallback((_) => context.goNamed('home'));
        return const Material();
      },
    );
  }
}

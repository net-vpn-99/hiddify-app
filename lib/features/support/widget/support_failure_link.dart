import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 首页：连接失败时才出现的「联系客服」按钮。连接正常 / 断开（非失败）时不显示。
class SupportFailureLink extends ConsumerWidget {
  const SupportFailureLink({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final exhausted = ref.watch(panelAuthProvider.select((s) => s.account?.exhausted ?? false));
    if (exhausted) return const SizedBox.shrink();

    final status = ref.watch(connectionNotifierProvider);
    final failed = switch (status) {
      AsyncError() => true,
      AsyncData(value: Disconnected(connectionFailure: final f)) => f != null,
      _ => false,
    };
    if (!failed) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: TextButton.icon(
        onPressed: () => context.pushNamed('supportChat'),
        icon: const Icon(Icons.support_agent_outlined, size: 18),
        label: const Text('连接不上？联系客服'),
      ),
    );
  }
}

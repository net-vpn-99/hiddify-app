import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/features/support/notifier/support_chat_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 「我的 → 帮助与客服」里的「在线客服」入口。有没看的客服回复时右边显示红点。
class SupportEntryTile extends ConsumerWidget {
  const SupportEntryTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unseen = ref.watch(supportChatNotifierProvider.select((s) => s.unseenAgentCount));
    return Material(
      child: ListTile(
        leading: const Icon(Icons.support_agent_outlined),
        title: const Text('在线客服'),
        subtitle: const Text('有问题随时问，客服会尽快回复'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (unseen > 0)
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(color: Theme.of(context).colorScheme.error, shape: BoxShape.circle),
              ),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right),
          ],
        ),
        onTap: () => context.pushNamed('supportChat'),
      ),
    );
  }
}

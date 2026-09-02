import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/features/proxy/model/node_display.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// OneRay: 精简版 —— 只显示线路名、说明、延迟、出口地区。
/// 不再暴露服务器 IP / ASN / 组织 / 经纬度 / 完整标签 等。
class ProxyInfoDialog extends HookConsumerWidget {
  const ProxyInfoDialog({super.key, required this.outboundInfo});

  final OutboundInfo outboundInfo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);
    final n = splitNodeName(outboundInfo.tagDisplay);
    final delay = outboundInfo.urlTestDelay;
    final loc = [outboundInfo.ipinfo.city, outboundInfo.ipinfo.region]
        .where((e) => e.isNotEmpty)
        .join(' · ');

    Widget row(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(k, style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(width: 12),
              Flexible(child: Text(v, textAlign: TextAlign.right)),
            ],
          ),
        );

    return AlertDialog(
      title: Text(n.name),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (n.desc.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(n.desc, style: theme.textTheme.bodySmall),
            ),
          if (delay > 0 && delay < 65000) row('延迟', '$delay ms'),
          if (delay >= 65000) row('延迟', '超时'),
          if (loc.isNotEmpty) row('出口', loc),
        ],
      ),
      actions: [TextButton(onPressed: context.pop, child: Text(t.common.close))],
    );
  }
}

import 'package:flutter/material.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/features/proxy/active/ip_widget.dart';
import 'package:hiddify/features/proxy/model/node_display.dart';
import 'package:hiddify/gen/fonts.gen.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:hiddify/utils/platform_utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class ProxyTile extends HookConsumerWidget with PresLogger {
  const ProxyTile(this.proxy, {super.key, required this.selected, required this.onTap});

  final OutboundInfo proxy;
  final bool selected;
  final GestureTapCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final n = splitNodeName(proxy.tagDisplay);

    return ListTile(
      // shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      title: Text(
        n.name,
        overflow: TextOverflow.ellipsis,
        style: (PlatformUtils.isWindows ? const TextStyle(fontFamily: FontFamily.emoji) : const TextStyle())
            .copyWith(fontWeight: FontWeight.w600),
      ),
      leading: IPCountryFlag(
        countryCode: proxy.ipinfo.countryCode,
        organization: proxy.ipinfo.org,
        size: 40,
        padding: const EdgeInsetsDirectional.only(end: 8),
      ),
      subtitle: Text(
        n.desc.isNotEmpty
            ? n.desc
            : (proxy.isGroup ? '${proxy.type} (${proxy.groupSelectedTagDisplay.trim()})' : proxy.type),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
      trailing: proxy.urlTestDelay != 0 ? _NodeSignal(delay: proxy.urlTestDelay) : null,

      selected: selected,
      selectedTileColor: theme.colorScheme.primaryContainer,
      onTap: onTap,
      onLongPress: () async => await ref.read(dialogNotifierProvider.notifier).showProxyInfo(outboundInfo: proxy),
      horizontalTitleGap: 4,
    );
  }
}

/// 节点信号：从 urlTest 延迟换算成"很稳 / 稳定 / 一般 / 慢 / 超时" + 信号格。
class _NodeSignal extends StatelessWidget {
  const _NodeSignal({required this.delay});
  final int delay;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (label, bars, color) = switch (delay) {
      >= 65000 => ('超时', 0, theme.colorScheme.error),
      < 200 => ('很稳', 4, const Color(0xFF3FA372)),
      < 400 => ('稳定', 3, const Color(0xFF3FA372)),
      < 800 => ('一般', 2, theme.colorScheme.onSurfaceVariant),
      _ => ('慢', 1, const Color(0xFFCF8A3B)),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        ...List.generate(4, (i) {
          return Container(
            width: 3,
            height: 5.0 + i * 3,
            margin: const EdgeInsets.symmetric(horizontal: 1),
            decoration: BoxDecoration(
              color: i < bars ? color : color.withValues(alpha: 0.25),
              borderRadius: BorderRadius.circular(1),
            ),
          );
        }),
        const SizedBox(width: 6),
        Text(label, style: theme.textTheme.bodySmall?.copyWith(color: color, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

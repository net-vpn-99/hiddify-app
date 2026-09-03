import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/proxy/data/proxy_data_providers.dart';
import 'package:hiddify/features/proxy/model/node_display.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 连接成功后跑一次：如果当前选中的出站是 hiddify-core 自动生成的均衡组
/// （select / balance / lowest —— 默认就是 balance 的 round-robin，一半流量走美国），
/// 自动切回第一个真实线路。UI 里这些组是藏掉的，用户没法自己改回来。
///
/// 在首页 `ref.watch` 一下即可，连一次修一次。
final autoLineFixerProvider = StreamProvider<void>((ref) async* {
  final running = await ref.watch(serviceRunningProvider.future);
  if (!running) return;

  final repo = ref.watch(proxyRepositoryProvider);
  await for (final either in repo.watchProxies()) {
    final OutboundGroup? group = either.getOrElse((_) => null);
    if (group == null) continue;

    final real = group.items.where((o) => !o.isGroup && !isAutoGroupTag(o.tag)).toList();
    if (real.isEmpty) continue;

    if (!real.any((o) => o.tag == group.selected)) {
      await repo.selectProxy(group.tag, real.first.tag).run();
    }
    return; // 每次连接只修一次
  }
});

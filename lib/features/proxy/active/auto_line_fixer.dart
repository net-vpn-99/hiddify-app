import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/proxy/data/proxy_data_providers.dart';
import 'package:hiddify/features/proxy/model/node_display.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 连接后跑一次：
///  - 如果用户在首页选过线路（preferredLineName），按名字匹配到真实出站并切过去；
///  - 否则，如果当前选中的是 hiddify-core 自动生成的均衡组（select / balance / lowest，
///    默认就是 balance 的 round-robin，一半流量走美国），切回第一个真实线路。
/// UI 里这些均衡组是藏掉的，用户没法自己改回来。
///
/// 在首页 `ref.watch` 一下即可。preferredLineName 变了会重新跑（已连接则立即切）。
final autoLineFixerProvider = StreamProvider<void>((ref) async* {
  final preferred = ref.watch(Preferences.preferredLineName);
  final running = await ref.watch(serviceRunningProvider.future);
  if (!running) return;

  final repo = ref.watch(proxyRepositoryProvider);
  await for (final either in repo.watchProxies()) {
    final OutboundGroup? group = either.getOrElse((_) => null);
    if (group == null) continue;

    final real = group.items.where((o) => !o.isGroup && !isAutoGroupTag(o.tag)).toList();
    if (real.isEmpty) continue;

    OutboundInfo? target;
    if (preferred.isNotEmpty) {
      for (final o in real) {
        if (splitNodeName(o.tag).name == preferred) {
          target = o;
          break;
        }
      }
    }
    // 没有偏好、或偏好那条线路不在了：只有当前选中的是被藏掉的均衡组时才纠正
    if (target == null && !real.any((o) => o.tag == group.selected)) {
      target = real.first;
    }

    if (target != null && target.tag != group.selected) {
      await repo.selectProxy(group.tag, target.tag).run();
    }
    return; // 每次连接（或每次改偏好）只跑一次
  }
});

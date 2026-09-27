import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/proxy/data/proxy_data_providers.dart';
import 'package:hiddify/features/proxy/data/proxy_repository.dart';
import 'package:hiddify/features/proxy/model/node_display.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 连接后跑一次：
///  - 如果用户在首页选过线路（preferredLineName），按名字匹配到真实出站并切过去；
///  - 否则，如果当前选中的是 hiddify-core 自动生成的均衡组（select / balance / lowest），
///    切到**服务端推荐的那条**（订阅第一条 —— 服务端插件 1.25.0 起会按各节点实时
///    负载给订阅排序，第一条就是它算出来最合适的）。推荐节点连不上**不自动换**，
///    由 connection_notifier 断开并告诉用户（两端统一，不自动换线）。
///
/// 为什么优先服务端：服务端有全局负载视野（每个节点多少人、CPU/内存多少），
/// 客户端只看得到自己到各节点的延迟。以前（1.1.8 早期）直接挑最快，结果大家
/// 都挑到同一条「最快」的、又挤到一起。服务端的选择该赢。
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

    // 1) 用户选过线路：按名字切过去
    if (preferred.isNotEmpty) {
      OutboundInfo? target;
      for (final o in real) {
        if (splitNodeName(o.tag).name == preferred) {
          target = o;
          break;
        }
      }
      if (target != null && target.tag != group.selected) {
        await repo.selectProxy(group.tag, target.tag).run();
      }
      return; // 每次连接（或每次改偏好）只跑一次
    }

    // 2) 没有偏好：只有当前选中的是被藏掉的均衡组时才纠正
    if (real.any((o) => o.tag == group.selected)) return;

    await _applyServerRecommended(repo, group.tag, real);
    return;
  }
});

/// 服务端推荐 = 订阅第一条（real.first，负载均衡钩子按用户排在最前）。
/// **先立刻切过去**，不等 urltest —— 否则连上后十几秒内核还在走它自己默认挑的
/// 「最快」节点（国内经常是美国 CN2 GIA），负载均衡白排。
///
/// 以前这里切完还会后台测一轮：推荐节点连不上就**自动回退到最快那条**。两端统一
/// 去掉了（docs/连上但不通-两端统一-手册.md）：连不上 10 秒内由 connection_notifier
/// 断开并在首页说原因和下一步，换哪条由用户自己选。
Future<void> _applyServerRecommended(
  ProxyRepository repo,
  String groupTag,
  List<OutboundInfo> real,
) async {
  await repo.selectProxy(groupTag, real.first.tag).run();
}

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
///    负载给订阅排序，第一条就是它算出来最合适的）。只有推荐节点实测连不上
///    （urltest 超时 / 无路由）才回退到延迟最低的真实节点。
///
/// 为什么优先服务端：服务端有全局负载视野（每个节点多少人、CPU/内存多少），
/// 客户端只看得到自己到各节点的延迟。以前（1.1.8 早期）直接挑最快，结果大家
/// 都挑到同一条「最快」的、又挤到一起。服务端的选择该赢，除非它真连不上。
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

    final picked = await _pickServerRecommended(repo, group.tag, real);
    if (picked != null && picked != group.selected) {
      await repo.selectProxy(group.tag, picked).run();
    }
    return;
  }
});

/// 有效延迟：内核里 0 = 没测，> ~60s = 超时/失败。
int? _validDelay(OutboundInfo o) =>
    (o.urlTestDelay > 0 && o.urlTestDelay < 60000) ? o.urlTestDelay : null;

String? _fastestTag(Iterable<OutboundInfo> items) {
  String? bestTag;
  var bestMs = 1 << 30;
  for (final o in items) {
    final d = _validDelay(o);
    if (d != null && d < bestMs) {
      bestMs = d;
      bestTag = o.tag;
    }
  }
  return bestTag;
}

OutboundInfo? _byTag(Iterable<OutboundInfo> items, String tag) {
  for (final o in items) {
    if (o.tag == tag) return o;
  }
  return null;
}

/// 服务端推荐 = 订阅第一条（real.first）。策略：
///  - 推荐节点现成 urltest 就有效 → 直接用；
///  - 否则催一轮 urltest，最多等 ~6s：
///      · 推荐节点测出有效延迟 → 用推荐（服务端有全局负载视野，它说了算）；
///      · 推荐节点超时、但其它节点都测完了 → 说明推荐这条大概率连不上，回退最快；
///  - 到点了：推荐节点有效就用，否则用已知最快，再不行兜底还是推荐。
Future<String?> _pickServerRecommended(
  ProxyRepository repo,
  String groupTag,
  List<OutboundInfo> real,
) async {
  final recommended = real.first.tag;
  final realTags = real.map((o) => o.tag).toSet();

  final r0 = _byTag(real, recommended);
  if (r0 != null && _validDelay(r0) != null) {
    return recommended;
  }

  await repo.urlTest(groupTag).run();

  List<OutboundInfo> latest = real;
  for (var i = 0; i < 9; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 700));
    try {
      final either = await repo.watchProxies().first;
      final g = either.getOrElse((_) => null);
      if (g == null) continue;
      final items = g.items.where((o) => realTags.contains(o.tag)).toList();
      if (items.isEmpty) continue;
      latest = items;

      final rec = _byTag(items, recommended);
      if (rec != null && _validDelay(rec) != null) {
        return recommended;
      }
      final othersDone = items
          .where((o) => o.tag != recommended)
          .every((o) => _validDelay(o) != null);
      if (othersDone && items.length > 1) {
        return _fastestTag(items) ?? recommended;
      }
    } catch (_) {
      // 内核状态流暂时读不到，下一轮再试
    }
  }

  final recFinal = _byTag(latest, recommended);
  if (recFinal != null && _validDelay(recFinal) != null) {
    return recommended;
  }
  return _fastestTag(latest) ?? recommended;
}

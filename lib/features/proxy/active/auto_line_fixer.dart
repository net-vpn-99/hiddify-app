import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/proxy/data/proxy_data_providers.dart';
import 'package:hiddify/features/proxy/data/proxy_repository.dart';
import 'package:hiddify/features/proxy/model/node_display.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 连接后跑一次：
///  - 如果用户在首页选过线路（preferredLineName），按名字匹配到真实出站并切过去；
///  - 否则，如果当前选中的是 hiddify-core 自动生成的均衡组（select / balance / lowest，
///    默认就是 balance 的 round-robin，一半流量走美国），切到**延迟最低**的真实线路
///    —— 以前是切「订阅里第一条」，结果所有没选过线的用户全挤在排在最前的洛杉矶节点上。
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

    // 挑延迟最低的真实节点。延迟还没测出来就催一次 urltest、等测速回来。
    final picked = await _pickFastestReal(repo, group.tag, real);
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

/// 返回真实节点里延迟最低的那条的 tag。测速结果没出来就先催一次 urltest，
/// 每 ~700ms 轮一次内核的分组状态，最多等 ~8 秒：
///  - 全部节点都测出延迟 → 立刻返回最快的；
///  - 到点了 → 返回已测出的里最快的；一条都没测出来 → 返回订阅第一条兜底。
Future<String?> _pickFastestReal(
  ProxyRepository repo,
  String groupTag,
  List<OutboundInfo> real,
) async {
  final realTags = real.map((o) => o.tag).toSet();

  // 内核启动时一般已经自己跑过一轮 urltest，先看现成结果。
  if (real.every((o) => _validDelay(o) != null)) {
    return _fastestTag(real) ?? real.first.tag;
  }

  await repo.urlTest(groupTag).run();

  List<OutboundInfo> latest = real;
  for (var i = 0; i < 11; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 700));
    try {
      final either = await repo.watchProxies().first;
      final g = either.getOrElse((_) => null);
      if (g == null) continue;
      final items = g.items.where((o) => realTags.contains(o.tag)).toList();
      if (items.isEmpty) continue;
      latest = items;
      if (items.every((o) => _validDelay(o) != null)) {
        return _fastestTag(items) ?? real.first.tag;
      }
    } catch (_) {
      // 内核状态流暂时读不到，下一轮再试
    }
  }

  return _fastestTag(latest) ?? real.first.tag;
}

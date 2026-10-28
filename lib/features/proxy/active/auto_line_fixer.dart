import 'dart:async';
import 'package:hiddify/features/proxy/model/transport_group.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service_provider.dart';

import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/app/notifier/app_foreground.dart';
import 'package:hiddify/features/connection/data/connect_reporter.dart';
import 'package:hiddify/features/connection/data/drop_notice.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/home/widget/connect_progress.dart';
import 'package:hiddify/features/proxy/data/proxy_data_providers.dart';
import 'package:hiddify/features/proxy/data/proxy_repository.dart';
import 'package:hiddify/features/proxy/model/node_display.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 连接后跑一次：
///  - 如果用户在首页选过线路（preferredLineName），按名字匹配到真实出站并切过去；
///  - 否则（没选过 = 跟服务器排的走，Windows 不是自己选的线路同一套）切到**服务端推荐的那条**
///    （订阅第一条 —— 服务端插件 1.25.0 起会按各节点实时负载给订阅排序，第一条就是它算出来最合适的）。
///    以前只在当前选中的是均衡组时才纠正：内核会恢复上一次选的那条（clash.db），「换到 X」清掉偏好后
///    又落回那条不通的线路（10-22 自检）。推荐节点连不上**不自动换**，
///    由 connection_notifier 断开并告诉用户（两端统一，不自动换线）。
///
/// 为什么优先服务端：服务端有全局负载视野（每个节点多少人、CPU/内存多少），
/// 客户端只看得到自己到各节点的延迟。以前（1.1.8 早期）直接挑最快，结果大家
/// 都挑到同一条「最快」的、又挤到一起。服务端的选择该赢。
///
/// 在首页 `ref.watch` 一下即可。preferredLineName 变了会重新跑（已连接则立即切）。
final autoLineFixerProvider = StreamProvider<void>((ref) async* {
  final preferred = ref.watch(Preferences.preferredLineName);
  final logicalId = ref.watch(Preferences.preferredLogicalLineId);
  final running = await ref.watch(serviceRunningProvider.future);
  if (!running) return;

  final repo = ref.watch(proxyRepositoryProvider);
  await for (final either in repo.watchProxies()) {
    final OutboundGroup? group = either.getOrElse((_) => null);
    if (group == null) continue;

    final real = group.items.where((o) => (!o.isGroup || isLogicalTransportTag(o.tag)) && !isAutoGroupTag(o.tag)).toList();
    if (real.isEmpty) continue;

    // 1) 用户选过线路：按名字切过去
    if (preferred.isNotEmpty || logicalId.isNotEmpty) {
      OutboundInfo? target;
      for (final o in real) {
        if (logicalId.isNotEmpty
            ? GslTransportGroup.tryParse(o.tag)?.id == logicalId
            : splitNodeName(o.tag).name == preferred) {
          target = o;
          break;
        }
      }
      if (target != null && target.tag != group.selected) {
        await repo.selectProxy(group.tag, target.tag).run();
      }
      if (target != null && target.tag == group.selected) {
        final core = ref.read(hiddifyCoreServiceProvider);
        if (isLogicalTransportTag(target.tag)) {
          unawaited(core.verifyTransportGroup(target.tag));
        } else {
          core.retainLegacySelection();
        }
      }
      // 选的线路不在订阅里了：不让内核接着用它自己挑的那条。首页按钮第 3 步已经拦过，走到这里的是
      // 通知栏快捷开关、开机自动连这些原生直接起内核的入口——同样停下，首页停在第 3 步那张卡（换到 X / 自己选线路）。
      if (target == null) {
        final gone = await lineGoneProgress(ref.read);
        if (gone != null) _stopForGoneLine(ref, gone);
      }
      return; // 每次连接（或每次改偏好）只跑一次
    }

    // 2) 没有偏好：跟服务器排的第一条（已经是它就不动）
    if (group.selected == real.first.tag) {
      final core = ref.read(hiddifyCoreServiceProvider);
      if (isLogicalTransportTag(real.first.tag)) {
        unawaited(core.verifyTransportGroup(real.first.tag));
      } else {
        core.retainLegacySelection();
      }
      return;
    }

    await _applyServerRecommended(repo, group.tag, real);
    return;
  }
});

/// 断开前先把卡、上报、通知都做完：断开会让这个 provider 重跑，之后 ref 就不能用了。
void _stopForGoneLine(Ref ref, ConnectProgress gone) {
  ref.read(connectProgressProvider.notifier).state = gone;
  unawaited(ref.read(connectReporterProvider).reportStepFailure(3, 'route_gone', '${gone.title}：${gone.message}'));
  // App 在后台（快捷开关、开机时多半是）：发一条系统通知，不然他不知道为什么没连上
  if (!ref.read(appForegroundProvider)) {
    unawaited(DropNotice.show('打开光速雷达换一条线路', title: gone.title));
  }
  unawaited(ref.read(connectionNotifierProvider.notifier).abortConnection());
}

/// 服务端推荐 = 订阅第一条（real.first，负载均衡钩子按用户排在最前）。
/// **先立刻切过去**，不等 urltest —— 否则连上后十几秒内核还在走它自己默认挑的
/// 「最快」节点（国内经常是美国 CN2 GIA），负载均衡白排。
///
/// 以前这里切完还会后台测一轮：推荐节点连不上就**自动回退到最快那条**。两端统一
/// 去掉了（docs/连上但不通-两端统一-手册.md）：连不上由 connection_notifier 按正面证据
/// 断开并在首页说原因和下一步，换哪条由用户自己选。
Future<void> _applyServerRecommended(
  ProxyRepository repo,
  String groupTag,
  List<OutboundInfo> real) async {
  await repo.selectProxy(groupTag, real.first.tag).run();
}

import 'dart:async';
import 'package:hiddify/features/connection/notifier/stability_notifier.dart';
import 'package:hiddify/features/proxy/line/line_source.dart';
import 'package:hiddify/features/proxy/model/subscription_recommendation.dart';
import 'package:hiddify/features/proxy/model/transport_group.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service_provider.dart';

import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/app/notifier/app_foreground.dart';
import 'package:hiddify/features/connection/data/connect_reporter.dart';
import 'package:hiddify/features/connection/data/drop_notice.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/home/widget/connect_progress.dart';
import 'package:hiddify/features/proxy/data/proxy_data_providers.dart';
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
    // A refreshed recommendation is not a new connection intent.
    if (preferred.isEmpty && logicalId.isEmpty && ref.read(stabilityProvider).confirmed) return;
    final unavailable = await lineGoneProgress(ref.read);
    if (unavailable != null) {
      if (unavailable.recommendationMissing && _retainRunningSelection(ref, real, group.selected)) return;
      _stopForGoneLine(ref, unavailable);
      return;
    }

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

    // 2) No preference: use the explicit decision, or the legacy first only if absent.
    final policy = SubscriptionRecommendation.read(await ref.read(activeProfileRawProvider.future));
    final target = policy.defaultTag(real.map((o) => o.tag).toList());
    if (target == null) {
      if (_retainRunningSelection(ref, real, group.selected)) return;
      _stopForGoneLine(ref, const ConnectProgress(failedStep:3, recommendationMissing:true,
          title:'暂时没有推荐线路',message:'请手动选择一条线路，或稍后刷新线路列表'));
      return;
    }
    if (group.selected == target) {
      final core = ref.read(hiddifyCoreServiceProvider);
      if (isLogicalTransportTag(target)) {
        unawaited(core.verifyTransportGroup(target));
      } else {
        core.retainLegacySelection();
      }
      return;
    }

    await repo.selectProxy(group.tag, target).run();
    return;
  }
});

/// 断开前先把卡、上报、通知都做完：断开会让这个 provider 重跑，之后 ref 就不能用了。
void _stopForGoneLine(Ref ref, ConnectProgress gone) {
  ref.read(connectProgressProvider.notifier).state = gone;
  unawaited(ref.read(connectReporterProvider).reportStepFailure(3, gone.recommendationMissing ? 'recommendation_unavailable' : (gone.lineGone ? 'route_gone' : 'route_down'), '${gone.title}：${gone.message}'));
  // App 在后台（快捷开关、开机时多半是）：发一条系统通知，不然他不知道为什么没连上
  if (!ref.read(appForegroundProvider)) {
    unawaited(DropNotice.show('打开光速雷达换一条线路', title: gone.title));
  }
  unawaited(ref.read(connectionNotifierProvider.notifier).abortConnection());
}



// New starts are guarded before core startup. If a pending/live core already has a
// real selection, a later catalog change must not turn it into a fresh default pick.
bool _retainRunningSelection(Ref ref, List<OutboundInfo> real, String selected) {
  final current=real.where((node)=>node.tag==selected).firstOrNull;
  if(current==null)return false;
  final core=ref.read(hiddifyCoreServiceProvider);
  if(isLogicalTransportTag(current.tag)){
    unawaited(core.verifyTransportGroup(current.tag));
  }else{core.retainLegacySelection();}
  return true;
}

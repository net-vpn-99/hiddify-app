import 'package:hiddify/features/proxy/model/subscription_recommendation.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/connection/notifier/stability_notifier.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/model/node_display.dart';
import 'package:hiddify/features/proxy/model/transport_group.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

typedef LineOption = NodeName;

/// 首页线路条和线路页要显示的线路。
///
/// 两个来源，优先订阅：
///  - **订阅里的线路**（本地 profile 文件离线解析，不用连接）= 真能连的；
///  - 订阅是空的时候（还没开成游客号、试用 / 会员到期——到期时服务端下发的订阅是
///    0 字节）退回**公开清单**（GslGuest catalog，只有名字），只能看不能连。
///
/// 这样首页在任何状态下都有东西可显示。空白首页是推广反馈里最刺眼的一条。
class LineSet {
  const LineSet({required this.lines, required this.locked});

  final List<LineOption> lines;

  /// true = 这些线路现在连不上（没账号 / 到期 / 流量用完），点了要弹引导。
  final bool locked;

  bool get isEmpty => lines.isEmpty;
}

final lineSetProvider = FutureProvider<LineSet>((ref) async {
  // 账号本身不可用时，订阅里就算还留着上次的内容也连不上 —— 直接按锁定处理。
  // account 还没拉回来（启动头一两秒）不算不可用，否则正常用户会先闪一下「锁住」。
  final account = ref.watch(panelAuthProvider).account;
  final accountUsable = account == null
      ? ref.watch(Preferences.panelLoggedIn)
      : !account.exhausted && account.stateSlug != 'no_plan';

  if (accountUsable) {
    final subLines = await ref.watch(activeProfileLinesProvider.future);
    if (subLines.isNotEmpty) return LineSet(lines: subLines, locked: false);
  }

  final names = await ref.watch(publicNodesProvider.future);
  return LineSet(lines: [for (final n in names) splitNodeName(n)], locked: true);
});

/// 首页写哪条线路（标题、提示行、雷达高亮、连接检查查哪条共用）= 点连接会连的那条：
///  - 自己选过线路：选的那条（auto_line_fixer 按偏好切过去）；
///  - 没自己选过 = 跟服务器走：订阅里排第一的（fixer 没偏好时切到它），[recommended] 为 true，
///    跟线路列表里标「推荐」的是同一条。跟 Windows 一样（没自己选过时首页是服务器排第一的，followServer）；
///  - 连上并确认通了：正在用的那条；
///  - 线路清单还没读出来 / 锁着：上次用的那条（不算推荐）。都没有给 null。
typedef HomeLine = ({LineOption line, bool recommended});

final homeLineProvider = Provider<HomeLine?>((ref) {
  final set = ref.watch(lineSetProvider).valueOrNull;
  final lines = set == null || set.locked ? const <LineOption>[] : set.lines;
  final last = ref.watch(Preferences.lastNodeName);
  final lastDesc = ref.watch(Preferences.lastNodeDesc);
  final preferred = ref.watch(Preferences.preferredLineName);
  final logicalId = ref.watch(Preferences.preferredLogicalLineId);
  final lastLogicalId = ref.watch(Preferences.lastLogicalLineId);
  LineOption named(String name, String id) =>
      lines.where((o) => id.isNotEmpty ? o.routeId == id : o.name == name).firstOrNull ??
      (name: name, desc: name == last ? lastDesc : '', isps: null, pro: false, routeId: id);
  final policy = ref.watch(subscriptionRecommendationProvider);
  final first = serverRecommendedLine(lines, policy);
  final connected = ref.watch(connectionNotifierProvider.select((s) => s.valueOrNull?.isConnected ?? false));
  // 还没确认通时内核可能先恢复上一次的选择、lastNodeName 闪成旧的那条，fixer 马上切走：这时照「会连哪条」写
  if (connected && last.isNotEmpty && ref.watch(stabilityProvider.select((s) => s.confirmed))) {
    return (line: named(last, lastLogicalId), recommended: preferred.isEmpty && first != null && sameNodeIdentity(first, named(last, lastLogicalId)),
    );
  }
  if (preferred.isNotEmpty || logicalId.isNotEmpty) return (line: named(preferred, logicalId), recommended: false);
  if (first != null) return (line: first, recommended: true);
  if (policy?.known == true) return null;
  // 清单还在读（冷启动那一下）：跟服务器走的人先写上次那条，提示行照样是「推荐线路」，读出来不跳字
  return last.isEmpty ? null : (line: named(last, lastLogicalId), recommended: set == null);
});

/// 当前订阅里的线路列表，从本地 profile 文件离线读出来（不用连接）。
final activeProfileRawProvider = FutureProvider<String>((ref) async {
  final profile = await ref.watch(activeProfileProvider.future);
  if (profile == null) return '';
  final repo = await ref.watch(profileRepositoryProvider.future);
  return repo.getRawConfig(profile.id).getOrElse((_) => '').run();
});

final activeProfileLinesProvider = FutureProvider<List<LineOption>>((ref) async {
  return parseSubscriptionLines(await ref.watch(activeProfileRawProvider.future));
});

final subscriptionRecommendationProvider = Provider<SubscriptionRecommendation?>((ref) {
  final raw = ref.watch(activeProfileRawProvider);
  if (raw.isLoading || !raw.hasValue) return null;
  return SubscriptionRecommendation.read(raw.value!);
});

LineOption? serverRecommendedLine(List<LineOption> lines, SubscriptionRecommendation? policy) {
  if (policy == null) return null;
  if (!policy.known) return lines.firstOrNull;
  if (!policy.selected) return null;
  final matches = lines.where((line) => policy.logicalId.isNotEmpty
      ? line.routeId == policy.logicalId : line.name == splitNodeName(policy.selectedTag).name).toList();
  return matches.length == 1 ? matches.single : null;
}

final unavailableLogicalLinesProvider = FutureProvider<Set<String>>((ref) async {
  return unavailableTransportGroups(await ref.watch(activeProfileRawProvider.future));
});

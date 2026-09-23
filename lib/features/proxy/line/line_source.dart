import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/model/node_display.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

typedef LineOption = ({String name, String desc});

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

/// 当前订阅里的线路列表，从本地 profile 文件离线读出来（不用连接）。
final activeProfileLinesProvider = FutureProvider<List<LineOption>>((ref) async {
  final profile = await ref.watch(activeProfileProvider.future);
  if (profile == null) return const [];
  final repo = await ref.watch(profileRepositoryProvider.future);
  final raw = await repo.getRawConfig(profile.id).getOrElse((_) => '').run();
  if (raw.isEmpty) return const [];
  return parseSubscriptionLines(raw);
});

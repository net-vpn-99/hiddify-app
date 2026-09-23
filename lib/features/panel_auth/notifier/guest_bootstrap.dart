import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hiddify/features/profile/notifier/profile_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 首页进不去的那几种原因，用来决定首页给什么入口。
enum GuestBlockReason {
  /// 这台手机登录过正式账号 —— 不给游客（防卸载重装反复领试用），让他登录。
  hasAccount,

  /// 自己点过「退出登录」—— 尊重他的选择，不再自动开号，但首页照常能逛。
  optedOut,

  /// 服务端关了游客 / 名额满了 / 网络不通。可以重试，也可以去注册。
  unavailable,
}

class GuestBootstrapState {
  const GuestBootstrapState({this.working = false, this.reason, this.message, this.emailMask});

  /// 正在开号：首页显示「正在准备…」，连接按钮先别让点。
  final bool working;

  /// null = 没有障碍（已登录，或者游客号已经开好了）。
  final GuestBlockReason? reason;

  /// 给用户看的一句话（红字 / 提示条），可能为空。
  final String? message;

  /// hasAccount 时的打码邮箱，可能是空串。
  final String? emailMask;

  bool get blocked => reason != null;
}

/// 装好第一次打开时在**后台**开游客号。
///
/// 1.1.28 之前是先跳登录页、在登录页上开号（用户会看见「正在开通免费试用…」转圈）。
/// 推广反馈这一步多余 —— 现在直接进首页，开号在后台跑，首页该显示的节点和套餐一直都在。
///
/// 开不出来也**不跳走**：首页照常显示公开节点清单和套餐，用户点连接时才提示。
final guestBootstrapProvider =
    NotifierProvider<GuestBootstrapNotifier, GuestBootstrapState>(GuestBootstrapNotifier.new);

class GuestBootstrapNotifier extends Notifier<GuestBootstrapState> {
  /// 开号只能有一个在飞：两次并发会各自导入一次订阅，用户会多出一条重复线路。
  Future<void>? _inflight;
  bool _done = false;

  @override
  GuestBootstrapState build() => const GuestBootstrapState();

  /// 首页每次出现都会叫一次，成功过就不再重复跑。
  Future<void> ensure() {
    if (_done) return Future.value();
    return _inflight ??= _run().whenComplete(() => _inflight = null);
  }

  /// 用户在首页点「重试」/ 从登录页回来时清掉记忆，让它能再开一次。
  void reset() {
    _done = false;
    state = const GuestBootstrapState();
  }

  Future<void> _run() async {
    // 已经有账号（正式的或上次开的游客）：不用开号，但要把账号拉一次 —— 首页的状态条和
    // 线路条都靠它判断（到期 / 流量用完 / 剩多久）。冷启动没有别的地方会拉。
    if (ref.read(Preferences.panelLoggedIn)) {
      _done = true;
      state = const GuestBootstrapState();
      try {
        // 用 fetchAccount 而不是 syncAccountQuietly：后者要 state.email 已经从
        // secure storage 读回来才肯干活，冷启动这会儿可能还没读到；fetchAccount
        // 直接拿 token，不受这个竞争影响。
        await ref.read(panelAuthProvider.notifier).fetchAccount();
      } catch (_) {}
      return;
    }
    // 自己退出过：别再塞一个游客号给他，但首页不拦着他逛。
    if (ref.read(Preferences.guestOptOut)) {
      _done = true;
      state = const GuestBootstrapState(reason: GuestBlockReason.optedOut, message: '登录后就能连接');
      return;
    }

    state = const GuestBootstrapState(working: true);
    try {
      final opts = await ref.read(panelAuthProvider.notifier).guestOptions();
      if (!opts.enabled) {
        _done = true;
        state = const GuestBootstrapState(
          reason: GuestBlockReason.unavailable,
          message: '免费试用暂时关闭，注册一个账号同样有试用',
        );
        return;
      }

      final r = await ref.read(panelAuthProvider.notifier).guestLogin();
      if (r.hasAccountMask != null) {
        _done = true;
        final mask = r.hasAccountMask!;
        state = GuestBootstrapState(
          reason: GuestBlockReason.hasAccount,
          emailMask: mask,
          message: mask.isEmpty ? '这台手机登录过账号，登录后继续用' : '这台手机登录过 $mask，登录后继续用',
        );
        return;
      }

      final url = r.subscribeUrl;
      if (r.error != null || url == null || url.isEmpty) {
        // 没标 _done：网络不好时下次回到首页还能再试一次。
        state = GuestBootstrapState(
          reason: GuestBlockReason.unavailable,
          message: r.error ?? '免费试用暂时开不了，稍后再试或注册账号',
        );
        return;
      }

      await ref.read(addProfileNotifierProvider.notifier).addAccountSubscription(url);
      _done = true;
      state = const GuestBootstrapState();
    } catch (e) {
      state = GuestBootstrapState(
        reason: GuestBlockReason.unavailable,
        message: '免费试用暂时开不了：$e',
      );
    }
  }
}

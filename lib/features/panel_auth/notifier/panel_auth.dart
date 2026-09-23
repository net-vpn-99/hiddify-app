import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/utils/device_id.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/panel_auth/data/panel_api.dart';
import 'package:hiddify/features/panel_auth/model/invite_referral.dart';
import 'package:hiddify/features/profile/overview/profiles_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

const _kTokenKey = 'oneray_panel_token';
const _kEmailKey = 'oneray_panel_email';

const _secureStorage = FlutterSecureStorage(
  aOptions: AndroidOptions(encryptedSharedPreferences: true),
);

class PanelAuthState {
  const PanelAuthState({this.loading = false, this.email, this.account});

  final bool loading;

  /// 已登录账号的邮箱；null = 未登录。
  final String? email;

  /// 最近一次拉到的账号信息（登录 / 启动刷订阅 / 会员页 / 连接前都会更新）。
  /// 连接流程用它判断流量是否用完，避免发起注定失败的连接。
  final PanelAccount? account;

  bool get loggedIn => email != null;

  /// 游客（GslGuest 插件免注册开的号）：邮箱是占位的 g-xxx@guest.invalid。
  bool get isGuest => email != null && email!.toLowerCase().endsWith(PanelApi.guestEmailSuffix);

  /// 账号编号 —— **免注册的号也有**，给人看、给人念、报给客服用。
  ///
  /// 格式 `A4K7-P92`：面板 uuid 的前 8 位十六进制换算成 7 位 Crockford Base32
  /// （字母表去掉了 I L O U，不会跟 1 和 0 看混），中间加一横分段。
  ///
  /// ⚠️ **不要改成面板的用户 ID**：那是全站递增的，等于把「我们一共多少用户」印在
  /// 每个客户的界面上。uuid 派生的编号同样唯一，还不暴露规模。
  ///
  /// ⚠️ 这个编号**不能用来登录**（免注册的号靠设备号认人，换台手机就没了）。
  /// 客服按编号找人：把编号反算回 hex 前 8 位，`SELECT * FROM v2_user WHERE uuid LIKE '<hex>%'`，
  /// 步骤写在 VPN 仓库 docs/客户端.md §2a-2。
  String? get accountNo {
    final u = account?.uuid?.replaceAll('-', '');
    if (u == null || u.length < 8) return null;
    var n = int.tryParse(u.substring(0, 8), radix: 16);
    if (n == null) return null;
    const abc = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
    var s = '';
    for (var i = 0; i < 7; i++) {
      s = abc[n! % 32] + s;
      n = n ~/ 32;
    }
    return '${s.substring(0, 4)}-${s.substring(4)}';
  }

  /// 给人看的账号名：注册过就是邮箱，没注册就是「账号 A4K7-P92」。
  String get accountLabel {
    if (!isGuest && email != null && email!.isNotEmpty) return email!;
    final no = accountNo;
    return no == null ? '我的账号' : '账号 $no';
  }

  PanelAuthState copyWith({
    bool? loading,
    String? email,
    PanelAccount? account,
    bool clearEmail = false,
    bool clearAccount = false,
  }) {
    return PanelAuthState(
      loading: loading ?? this.loading,
      email: clearEmail ? null : (email ?? this.email),
      account: clearAccount ? null : (account ?? this.account),
    );
  }
}

typedef PanelLoginResult = ({String? subscribeUrl, String? error});

final panelAuthProvider =
    NotifierProvider<PanelAuthNotifier, PanelAuthState>(PanelAuthNotifier.new);

/// 邀请文案（服务器下发，改文案不用发版）：`bonus` = 奖励额度，`share` = 分享文案模板。
/// 拿不到对应项为 null，UI 兜底（入口显示「查看邀请奖励」，分享用客户端内置文案）。
/// 游客试用开关 / 绑定赠送文案 / 能不能直接买（GslGuest，走 guest/comm/config，改了不用发版）。
final guestOptionsProvider = FutureProvider<GuestOptions>((ref) => PanelApi().getGuestOptions());

/// 免登录的公开节点清单（GslGuest catalog）。没开成游客号、试用到期时首页和线路页
/// 靠它撑住，不至于一片空白。拉不到就是空列表，UI 自己降级。
/// （套餐不走这儿：Xboard 自带免登录的 `guest/plan/fetch`，见 PurchaseService。）
final publicNodesProvider = FutureProvider<List<String>>((ref) => PanelApi().getPublicNodes());

final inviteTextsProvider =
    FutureProvider.autoDispose<({String? bonus, String? share, String? linkTemplate})>((ref) => PanelApi().getInviteTexts());

class PanelAuthNotifier extends Notifier<PanelAuthState> {
  final PanelApi _api = PanelApi();
  Future<PanelAccount?>? _accountInflight;

  @override
  PanelAuthState build() {
    // 异步补上已保存的邮箱（不阻塞首帧）。
    _secureStorage.read(key: _kEmailKey).then((email) {
      if (email != null && email.isNotEmpty && !state.loggedIn) {
        state = state.copyWith(email: email);
      }
    });
    return const PanelAuthState();
  }

  Future<String?> currentToken() => _secureStorage.read(key: _kTokenKey);

  /// 登录并返回订阅地址。失败时 subscribeUrl 为 null、error 为中文提示。
  Future<PanelLoginResult> login(String email, String password) async {
    if (state.loading) return (subscribeUrl: null, error: null);
    state = state.copyWith(loading: true);
    try {
      final token = await _api.login(email.trim(), password);
      final sub = await _api.getSubscribe(token);
      await _secureStorage.write(key: _kTokenKey, value: token);
      await _secureStorage.write(key: _kEmailKey, value: sub.email ?? email.trim());
      await ref.read(Preferences.panelLoggedIn.notifier).update(true);
      state = state.copyWith(loading: false, email: sub.email ?? email.trim(), account: sub.account);
      return (subscribeUrl: sub.subscribeUrl, error: null);
    } on PanelApiException catch (e) {
      state = state.copyWith(loading: false);
      return (subscribeUrl: null, error: e.message);
    } catch (e) {
      state = state.copyWith(loading: false);
      return (subscribeUrl: null, error: '登录出错：$e');
    }
  }

  /// 注册并直接登入，返回订阅地址。失败时 subscribeUrl 为 null、error 为中文提示。
  Future<PanelLoginResult> register(
    String email,
    String password, {
    String? code,
    String? inviteCode,
  }) async {
    if (state.loading) return (subscribeUrl: null, error: null);
    state = state.copyWith(loading: true);

    Future<PanelLoginResult> finish(String token) async {
      final sub = await _api.getSubscribe(token);
      await _secureStorage.write(key: _kTokenKey, value: token);
      await _secureStorage.write(key: _kEmailKey, value: sub.email ?? email.trim());
      await ref.read(Preferences.panelLoggedIn.notifier).update(true);
      state = state.copyWith(loading: false, email: sub.email ?? email.trim(), account: sub.account);
      return (subscribeUrl: sub.subscribeUrl, error: null);
    }

    try {
      var token = await _api.register(email.trim(), password, code: code, inviteCode: inviteCode);
      // 部分站点注册后不直接返回令牌 —— 账号已建好，用密码登录一次。
      token ??= await _api.login(email.trim(), password);
      return await finish(token);
    } on PanelApiException catch (e) {
      // 注册答复可能丢了但账号已建好（之后重试会报「邮箱已存在」把人卡死）—— 先用
      // 这套凭据登录一次，成功就当注册成功。
      try {
        return await finish(await _api.login(email.trim(), password));
      } catch (_) {}
      state = state.copyWith(loading: false);
      return (subscribeUrl: null, error: e.message);
    } catch (e) {
      state = state.copyWith(loading: false);
      return (subscribeUrl: null, error: '注册出错：$e');
    }
  }

  Future<({bool emailVerify, bool inviteForce, bool recaptcha})> registerOptions() =>
      _api.getRegisterOptions();

  Future<GuestOptions> guestOptions() => _api.getGuestOptions();

  /// 免注册试用：按本机 ANDROID_ID 开 / 取回游客号，成功返回订阅地址。
  /// 这台设备登过正式账号时返回 hasAccountMask（让用户直接登录），不开游客。
  Future<({String? subscribeUrl, String? error, String? hasAccountMask})> guestLogin() async {
    if (state.loading) return (subscribeUrl: null, error: null, hasAccountMask: null);
    final deviceId = await DeviceId.read();
    if (deviceId == null) {
      return (subscribeUrl: null, error: '读不到本机设备信息，请注册账号使用', hasAccountMask: null);
    }
    state = state.copyWith(loading: true);
    try {
      final r = await _api.guestLogin(deviceId);
      final token = r.token;
      if (token == null) {
        state = state.copyWith(loading: false);
        return (subscribeUrl: null, error: null, hasAccountMask: r.hasAccountMask ?? '');
      }
      final sub = await _api.getSubscribe(token);
      final email = sub.email ?? '';
      await _secureStorage.write(key: _kTokenKey, value: token);
      await _secureStorage.write(key: _kEmailKey, value: email);
      await ref.read(Preferences.panelLoggedIn.notifier).update(true);
      await ref.read(Preferences.guestOptOut.notifier).update(false);
      state = state.copyWith(loading: false, email: email, account: sub.account);
      return (subscribeUrl: sub.subscribeUrl, error: null, hasAccountMask: null);
    } on PanelApiException catch (e) {
      state = state.copyWith(loading: false);
      return (subscribeUrl: null, error: e.message, hasAccountMask: null);
    } catch (e) {
      state = state.copyWith(loading: false);
      return (subscribeUrl: null, error: '免注册试用出错：$e', hasAccountMask: null);
    }
  }

  /// 游客绑定邮箱（买套餐前必须）。成功返回 null，失败返回中文提示。
  /// 账号 / token / 订阅都不变，只是邮箱换成真的。
  Future<String?> bindGuest(String email, String password, {String? code, String? inviteCode}) async {
    final token = await currentToken();
    if (token == null || token.isEmpty) return '登录已过期，请重新打开 App';
    if (state.loading) return null;
    state = state.copyWith(loading: true);
    try {
      final bound = await _api.bindGuest(token, email, password, code: code, inviteCode: inviteCode);
      await _secureStorage.write(key: _kEmailKey, value: bound);
      state = state.copyWith(loading: false, email: bound);
      // 到期时间变了（绑定赠送），刷一下缓存
      await fetchAccount();
      return null;
    } on PanelApiException catch (e) {
      state = state.copyWith(loading: false);
      if (e.unauthorized) await logout(wipe: false);
      return e.message;
    } catch (e) {
      state = state.copyWith(loading: false);
      return '注册出错：$e';
    }
  }

  /// 用已保存的令牌重新拉一次订阅地址（启动时刷新用）。失败返回 null。
  Future<String?> refreshSubscribeUrl() async {
    final token = await currentToken();
    if (token == null || token.isEmpty) return null;
    try {
      final sub = await _api.getSubscribe(token);
      if (sub.account != null) state = state.copyWith(account: sub.account);
      return sub.subscribeUrl;
    } on PanelApiException catch (e) {
      if (e.unauthorized) await logout(wipe: false);
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 会员页拉最新账号信息。未登录 / 失败返回 null。顺带更新缓存（连接流程会读）。
  Future<PanelAccount?> fetchAccount() async {
    if (_accountInflight != null) return _accountInflight;
    final token = await currentToken();
    if (token == null || token.isEmpty) return null;
    final pending = () async {
      try {
        final acc = await _api.getAccount(token);
        state = state.copyWith(account: acc);
        return acc;
      } on PanelApiException catch (e) {
        if (e.unauthorized) await logout(wipe: false);
        return null;
      } catch (_) {
        return null;
      }
    }();
    _accountInflight = pending;
    try {
      return await pending;
    } finally {
      if (identical(_accountInflight, pending)) {
        _accountInflight = null;
      }
    }
  }

  /// 后台静默刷一次账号缓存（app 回前台、连接前、连接失败后调用）。不抛异常。
  Future<void> syncAccountQuietly() async {
    if (!state.loggedIn) return;
    try {
      await fetchAccount();
    } catch (_) {}
  }

  Future<String?> sendEmailCode(String email) async {
    try {
      await _api.sendEmailCode(email);
      return null;
    } on PanelApiException catch (e) {
      return e.message;
    } catch (e) {
      return '出错了：$e';
    }
  }

  Future<String?> resetPassword(String email, String newPassword, String code) async {
    try {
      await _api.resetPassword(email, newPassword, code);
      return null;
    } on PanelApiException catch (e) {
      return e.message;
    } catch (e) {
      return '出错了：$e';
    }
  }

  Future<({String code, String link})?> getInvite() async {
    final token = await currentToken();
    if (token == null || token.isEmpty) return null;
    try {
      return await _api.getInvite(token);
    } on PanelApiException catch (e) {
      if (e.unauthorized) await logout(wipe: false);
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 「我邀请的人」列表。未登录 / 失败返回 null。
  Future<({List<InviteReferral> items, int total})?> getReferrals({int page = 1}) async {
    final token = await currentToken();
    if (token == null || token.isEmpty) return null;
    try {
      return await _api.getReferrals(token, page: page);
    } on PanelApiException catch (e) {
      if (e.unauthorized) await logout(wipe: false);
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 设备闸：连接前 / 连着的时候周期性 claim 一次。未登录（没存令牌，比如手动
  /// 导入订阅的用户）不占用设备位，直接放行。
  ///
  /// `allowed=false` 时调用方不应该发起 / 应该中止本次连接，`blockMessage`
  /// 是给用户看的中文提示（登录已过期 / 设备数已满）。网络问题、闸暂时联系
  /// 不上、404（这套 www 还没配闸）都算 `allowed=true`——闸是 fail-open，
  /// 不能因为登记服务的问题把正常连接也拦住。
  Future<({bool allowed, String? blockMessage})> claimDevice({required bool connected}) async {
    final token = await currentToken();
    if (token == null || token.isEmpty) return (allowed: true, blockMessage: null);
    final deviceId = await DeviceId.read();
    if (deviceId == null) {
      // 拿不到可用的设备 ID：宁可不让连，也不能拿坏 ID 占座位。
      return (allowed: false, blockMessage: '无法识别这台设备，请重启 App 后重试');
    }
    try {
      await _api.claimDevice(token, deviceId, connected: connected);
      return (allowed: true, blockMessage: null);
    } on PanelApiException catch (e) {
      if (e.unauthorized) await logout(wipe: false);
      return (allowed: false, blockMessage: e.message);
    } catch (_) {
      return (allowed: true, blockMessage: null);
    }
  }

  /// 退出登录。
  /// [wipe] = true（用户手动点「退出登录」）：断开连接 + 删掉导入的订阅 + 清掉记住的线路。
  /// [wipe] = false（令牌失效等内部调用）：只清令牌，保留已导入的订阅，避免误删。
  Future<void> logout({bool wipe = true}) async {
    // 手动退出过就不再自动开游客（令牌失效那种内部退出不算）。
    if (wipe) await ref.read(Preferences.guestOptOut.notifier).update(true);
    await _secureStorage.delete(key: _kTokenKey);
    await _secureStorage.delete(key: _kEmailKey);
    await ref.read(Preferences.panelLoggedIn.notifier).update(false);
    state = state.copyWith(loading: false, clearEmail: true, clearAccount: true);
    if (!wipe) return;

    // 退出 = 不能再连。断开 + 删订阅。
    try {
      await ref.read(connectionNotifierProvider.notifier).abortConnection();
    } catch (_) {}
    try {
      final profiles = await ref.read(profilesNotifierProvider.future);
      for (final p in profiles) {
        await ref.read(profilesNotifierProvider.notifier).deleteProfile(p);
      }
    } catch (_) {}
    try {
      await ref.read(Preferences.lastNodeName.notifier).update('');
      await ref.read(Preferences.lastNodeDesc.notifier).update('');
    } catch (_) {}
  }
}

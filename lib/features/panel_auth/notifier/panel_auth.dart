import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
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
final inviteTextsProvider =
    FutureProvider.autoDispose<({String? bonus, String? share})>((ref) => PanelApi().getInviteTexts());

class PanelAuthNotifier extends Notifier<PanelAuthState> {
  final PanelApi _api = PanelApi();

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
    final token = await currentToken();
    if (token == null || token.isEmpty) return null;
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

  /// 退出登录。
  /// [wipe] = true（用户手动点「退出登录」）：断开连接 + 删掉导入的订阅 + 清掉记住的线路。
  /// [wipe] = false（令牌失效等内部调用）：只清令牌，保留已导入的订阅，避免误删。
  Future<void> logout({bool wipe = true}) async {
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
